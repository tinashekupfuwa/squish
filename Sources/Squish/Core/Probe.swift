import Foundation

struct Rational: Hashable, Codable, CustomStringConvertible, Sendable {
    var num: Int
    var den: Int

    init(_ num: Int, _ den: Int) {
        let divisor = max(Rational.gcd(abs(num), abs(den)), 1)
        self.num = num / divisor
        self.den = den / divisor
    }

    init?(string: String) {
        let parts = string.split(separator: "/")
        if parts.count == 2, let n = Int(parts[0]), let d = Int(parts[1]), n > 0, d > 0 {
            self.init(n, d)
        } else if parts.count == 1, let n = Int(parts[0]), n > 0 {
            self.init(n, 1)
        } else {
            return nil
        }
    }

    var value: Double { Double(num) / Double(den) }
    var description: String { den == 1 ? "\(num)" : "\(num)/\(den)" }
    var pretty: String { den == 1 ? "\(num)" : String(format: "%.3g", value) }

    static func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
}

struct AudioStream: Hashable, Sendable {
    let codec: String
    let channels: Int
}

struct ProbeInfo: Hashable, Sendable {
    let source: String
    let bytes: Int64
    let duration: Double
    let codedWidth: Int
    let codedHeight: Int
    let rotation: Int
    let fps: Rational?
    let pixFmt: String
    let videoCodec: String
    let profile: String
    let level: Int
    let bitRate: Int64
    let audio: [AudioStream]

    var rotated: Bool { abs(rotation) % 180 == 90 }
    var width: Int { rotated ? codedHeight : codedWidth }
    var height: Int { rotated ? codedWidth : codedHeight }
    var dimensions: String { "\(width)×\(height)" }
    var pixels: Int { width * height }
    var aspect: Double { height > 0 ? Double(width) / Double(height) : 0 }
    var bitDepth: Int {
        guard let match = pixFmt.firstMatch(of: #/(\d+)(le|be)$/#), let depth = Int(match.1) else { return 8 }
        return depth
    }

    var summary: String {
        var parts = [dimensions]
        if let fps { parts.append("\(fps.pretty) fps") }
        parts.append(Fmt.duration(duration))
        parts.append(videoCodec.uppercased())
        parts.append("\(bitDepth)-bit")
        parts.append(audio.isEmpty ? "no audio" : "audio")
        parts.append(Fmt.bytes(bytes))
        return parts.joined(separator: " · ")
    }
}

enum Probe {
    static func run(_ input: String) async throws -> ProbeInfo {
        let result = try await Runner.checked(try Tools.ffprobe(), ["-v", "error", "-show_format", "-show_streams", "-of", "json", input])
        return try parse(result.stdout, source: input)
    }

    static func parse(_ json: String, source: String) throws -> ProbeInfo {
        guard let data = json.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ToolError.message("Could not read ffprobe output for \(source).")
        }
        let streams = root["streams"] as? [[String: Any]] ?? []
        let format = root["format"] as? [String: Any] ?? [:]
        let video = streams.first { stream in
            let attached = (stream["disposition"] as? [String: Any])?["attached_pic"] as? Int ?? 0
            return stream["codec_type"] as? String == "video" && attached == 0
        }
        guard let video else { throw ToolError.message("No video stream found in \(URL(fileURLWithPath: source).lastPathComponent).") }

        var rotation = 0
        if let sideData = video["side_data_list"] as? [[String: Any]] {
            for entry in sideData { if let r = number(entry["rotation"]) { rotation = Int(r.rounded()) } }
        }
        if rotation == 0, let tags = video["tags"] as? [String: Any], let r = number(tags["rotate"]) {
            rotation = Int(r)
        }

        let fps = Rational(string: video["avg_frame_rate"] as? String ?? "") ?? Rational(string: video["r_frame_rate"] as? String ?? "")
        let duration = number(format["duration"]) ?? number(video["duration"]) ?? 0
        var bytes = Int64(number(format["size"]) ?? 0)
        if bytes == 0, let attrs = try? FileManager.default.attributesOfItem(atPath: source), let size = attrs[.size] as? NSNumber {
            bytes = size.int64Value
        }
        let audio = streams.filter { $0["codec_type"] as? String == "audio" }.map {
            AudioStream(codec: $0["codec_name"] as? String ?? "?", channels: Int(number($0["channels"]) ?? 0))
        }
        return ProbeInfo(
            source: source,
            bytes: bytes,
            duration: duration,
            codedWidth: Int(number(video["width"]) ?? 0),
            codedHeight: Int(number(video["height"]) ?? 0),
            rotation: rotation,
            fps: fps,
            pixFmt: video["pix_fmt"] as? String ?? "?",
            videoCodec: video["codec_name"] as? String ?? "?",
            profile: video["profile"] as? String ?? "",
            level: Int(number(video["level"]) ?? -99),
            bitRate: Int64(number(format["bit_rate"]) ?? number(video["bit_rate"]) ?? 0),
            audio: audio
        )
    }

    private static func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    final class PeakBox: @unchecked Sendable {
        private let lock = NSLock()
        private var peak = -Double.infinity
        private(set) var samples = 0
        func record(_ value: Double) {
            lock.lock(); defer { lock.unlock() }
            samples += 1
            if value > peak { peak = value }
        }
        var value: Double { lock.lock(); defer { lock.unlock() }; return peak }
    }

    /// Maximum peak level in dBFS across every audio stream, analysed over its full duration. Nil when there is no audio.
    static func maxAudioPeak(_ input: String, streamCount: Int) async throws -> Double? {
        guard streamCount > 0 else { return nil }
        let ffmpeg = try Tools.ffmpeg()
        var overall = -Double.infinity
        for index in 0..<streamCount {
            let box = PeakBox()
            let key = "lavfi.astats.Overall.Peak_level="
            _ = try await Runner.checked(ffmpeg, [
                "-hide_banner", "-nostdin", "-v", "error", "-i", input, "-map", "0:a:\(index)",
                "-af", "astats=metadata=1:reset=0,ametadata=mode=print:key=lavfi.astats.Overall.Peak_level:file=-:direct=1",
                "-f", "null", "-"
            ], keepStdout: false, onStdoutLine: { line in
                guard let range = line.range(of: key) else { return }
                let raw = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
                if let value = Double(raw) { box.record(value) }
            })
            guard box.samples > 0 else {
                throw ToolError.message("Audio analysis for stream \(index) returned no peak measurements; refusing to treat it as silence.")
            }
            overall = max(overall, box.value)
        }
        return overall
    }
}
