import Foundation

enum Codec: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    case vp9, h265, av1

    var id: String { rawValue }
    var label: String {
        switch self {
        case .vp9: return "VP9 / WebM"
        case .h265: return "H.265 / MP4"
        case .av1: return "AV1 / WebM"
        }
    }
    /// Who plays this format, in plain words.
    var audience: String {
        switch self {
        case .vp9: return "Chrome, Firefox, Edge"
        case .h265: return "Safari, iPhone, Mac"
        case .av1: return "Smallest; slow to make"
        }
    }
    var shortLabel: String {
        switch self {
        case .vp9: return "VP9"
        case .h265: return "H.265"
        case .av1: return "AV1"
        }
    }
    var fileExtension: String { self == .h265 ? "mp4" : "webm" }
    var mimeType: String { self == .h265 ? "video/mp4" : "video/webm" }
    var probeName: String {
        switch self {
        case .vp9: return "vp9"
        case .h265: return "hevc"
        case .av1: return "av1"
        }
    }
    var defaultCRF: Int { self == .h265 ? 30 : 42 }
    var crfRange: ClosedRange<Int> { self == .h265 ? 0...51 : 0...63 }

    func videoFlags(crf: Int, pixFmt: String, speed: SpeedMode) -> [String] {
        switch (self, speed) {
        case (.vp9, .skill):
            return ["-c:v", "libvpx-vp9", "-b:v", "0", "-crf", "\(crf)", "-deadline", "best", "-pix_fmt", pixFmt]
        case (.vp9, .faster):
            return ["-c:v", "libvpx-vp9", "-b:v", "0", "-crf", "\(crf)", "-deadline", "good", "-cpu-used", "2", "-row-mt", "1", "-pix_fmt", pixFmt]
        case (.h265, .skill):
            return ["-c:v", "libx265", "-crf", "\(crf)", "-preset", "veryslow", "-tag:v", "hvc1", "-movflags", "faststart", "-pix_fmt", pixFmt]
        case (.h265, .faster):
            return ["-c:v", "libx265", "-crf", "\(crf)", "-preset", "slow", "-tag:v", "hvc1", "-movflags", "faststart", "-pix_fmt", pixFmt]
        case (.av1, .skill):
            return ["-c:v", "libsvtav1", "-b:v", "0", "-crf", "\(crf)", "-preset", "6", "-pix_fmt", pixFmt]
        case (.av1, .faster):
            return ["-c:v", "libsvtav1", "-b:v", "0", "-crf", "\(crf)", "-preset", "8", "-pix_fmt", pixFmt]
        }
    }

    /// Every audio stream is kept, never mixed down. H.265 can store them losslessly as ALAC, which is bit-exact.
    /// AAC is 128 kb/s per channel of the first stream. Opus (WebM) cannot be lossless: 96 kb/s per channel, and it
    /// only accepts the Vorbis surround layouts, so any other layout up to 8 channels is relabelled by position
    /// without touching the samples. Layouts that would invent a band-limited LFE, and anything over 8 channels,
    /// are encoded as independent discrete channels.
    func audioFlags(keep: Bool, streams: [AudioStream], lossless: Bool) -> [String] {
        guard keep, !streams.isEmpty else { return ["-an"] }
        let channels = max(streams[0].channels, 1)
        let audio = streams[0]
        guard self != .h265 else {
            return lossless ? ["-map", "0:a", "-c:a", "alac"] : ["-map", "0:a", "-c:a", "aac", "-b:a", "\(128 * channels)k"]
        }
        var flags = ["-map", "0:a:0", "-c:a", "libopus", "-b:a", "\(96 * channels)k"]
        guard channels > 2 else { return flags }
        let opusLayouts = ["3.0", "quad", "5.0", "5.1", "6.1", "7.1"]
        let target = channels <= opusLayouts.count + 2 ? opusLayouts[channels - 3] : ""
        let hasLFE = audio.layout.contains(".1")
        if target.isEmpty || (target.contains(".1") && !hasLFE) { return flags + ["-mapping_family", "255"] }
        flags += ["-mapping_family", "1"]
        if audio.layout != target { flags += ["-af", "channelmap=channel_layout=\(target)"] }
        return flags
    }
}

enum AudioMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case auto, keep, remove
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "Auto (remove if silent)"
        case .keep: return "Keep"
        case .remove: return "Remove"
        }
    }
}

enum FrameRateMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case preserve, cap
    var id: String { rawValue }
    var label: String { self == .preserve ? "Same as source" : "Limit to 30 fps (smaller files)" }
}

enum SpeedMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case skill, faster
    var id: String { rawValue }
    var label: String { self == .skill ? "Extra compression (much slower)" : "Standard" }
}

struct EncodeSettings: Codable, Equatable, Sendable {
    var vp9 = false
    var h265 = true
    var av1 = false
    var crf: [Codec: Int] = [.vp9: 42, .h265: 30, .av1: 42]
    var audio: AudioMode = .auto
    var frameRate: FrameRateMode = .preserve
    var tenBit = true
    var maxWidth: Int? = nil
    var speed: SpeedMode = .faster
    /// ALAC in the MP4, bit-exact. WebM has no lossless audio, so Opus stays at the high bitrate above.
    var losslessAudio = true

    init() {}

    var enabledCodecs: [Codec] {
        Codec.allCases.filter { codec in
            switch codec {
            case .vp9: return vp9
            case .h265: return h265
            case .av1: return av1
            }
        }
    }
    func crf(for codec: Codec) -> Int { crf[codec] ?? codec.defaultCRF }

    /// H.265 keeps the source chroma (a Ninja 4:2:2 master stays 4:2:2). VP9 and AV1 are 4:2:0, which is what browsers play.
    func pixFmt(for codec: Codec, source: ProbeInfo) -> String {
        let sub: String
        if codec == .h265 && source.pixFmt.contains("444") { sub = "444" }
        else if codec == .h265 && source.pixFmt.contains("422") { sub = "422" }
        else { sub = "420" }
        return tenBit ? "yuv\(sub)p10le" : "yuv\(sub)p"
    }

    enum CodingKeys: String, CodingKey {
        case vp9, h265, av1, crf, audio, frameRate, tenBit, maxWidth, speed, losslessAudio
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        vp9 = try c.decodeIfPresent(Bool.self, forKey: .vp9) ?? false
        h265 = try c.decodeIfPresent(Bool.self, forKey: .h265) ?? true
        av1 = try c.decodeIfPresent(Bool.self, forKey: .av1) ?? false
        crf = try c.decodeIfPresent([Codec: Int].self, forKey: .crf) ?? [.vp9: 42, .h265: 30, .av1: 42]
        audio = try c.decodeIfPresent(AudioMode.self, forKey: .audio) ?? .auto
        frameRate = try c.decodeIfPresent(FrameRateMode.self, forKey: .frameRate) ?? .preserve
        tenBit = try c.decodeIfPresent(Bool.self, forKey: .tenBit) ?? true
        maxWidth = try c.decodeIfPresent(Int.self, forKey: .maxWidth) ?? nil
        speed = try c.decodeIfPresent(SpeedMode.self, forKey: .speed) ?? .faster
        losslessAudio = try c.decodeIfPresent(Bool.self, forKey: .losslessAudio) ?? true
    }

    func encode(to encoder: Swift.Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(vp9, forKey: .vp9)
        try c.encode(h265, forKey: .h265)
        try c.encode(av1, forKey: .av1)
        try c.encode(crf, forKey: .crf)
        try c.encode(audio, forKey: .audio)
        try c.encode(frameRate, forKey: .frameRate)
        try c.encode(tenBit, forKey: .tenBit)
        try c.encodeIfPresent(maxWidth, forKey: .maxWidth)
        try c.encode(speed, forKey: .speed)
        try c.encode(losslessAudio, forKey: .losslessAudio)
    }
}

enum Filters {
    static func even(_ value: Int) -> Int { max(2, value - value % 2) }

    static func outputSize(_ probe: ProbeInfo, maxWidth: Int?) -> (Int, Int) {
        let w = probe.width, h = probe.height
        if let maxWidth, maxWidth < w, w > 0 {
            let tw = even(maxWidth)
            let th = Int((Double(h) * Double(tw) / Double(w) / 2).rounded()) * 2
            return (tw, max(2, th))
        }
        if w % 2 == 1 { return (w - 1, Int((Double(h) * Double(w - 1) / Double(w) / 2).rounded()) * 2) }
        if h % 2 == 1 { return (Int((Double(w) * Double(h - 1) / Double(h) / 2).rounded()) * 2, h - 1) }
        return (w, h)
    }

    static func scaleFilter(_ probe: ProbeInfo, maxWidth: Int?) -> String? {
        let w = probe.width, h = probe.height
        if let maxWidth, maxWidth < w { return "scale=\(even(maxWidth)):-2" }
        if w % 2 == 1 { return "scale=\(w - 1):-2" }
        if h % 2 == 1 { return "scale=-2:\(h - 1)" }
        return nil
    }

    /// The capped rate for a source above 30 fps, or nil when no cap applies.
    static func cappedFPS(_ f: Rational) -> Rational? {
        let value = f.value
        guard value > 30 else { return nil }
        if value < 50 { return Rational(30, 1) }
        let d = max(2, Int((value / 30 + 0.5).rounded(.down)))
        let candidate = Rational(f.num, f.den * d)
        return candidate.value <= 30 ? candidate : Rational(30, 1)
    }

    static func targetFPS(_ probe: ProbeInfo, mode: FrameRateMode) -> Rational? {
        guard let fps = probe.fps else { return nil }
        if mode == .cap, let capped = cappedFPS(fps) { return capped }
        return fps
    }

    static func chain(_ probe: ProbeInfo, maxWidth: Int?, frameRate: FrameRateMode) -> String {
        var parts: [String] = []
        if let scale = scaleFilter(probe, maxWidth: maxWidth) { parts.append(scale) }
        if frameRate == .cap, let fps = probe.fps, let capped = cappedFPS(fps) { parts.append("fps=\(capped)") }
        return parts.joined(separator: ",")
    }
}

struct AudioDecision: Sendable {
    let keep: Bool
    let reason: String
    let peak: Double?
}

struct Verification: Sendable {
    let probe: ProbeInfo
    let checks: [String]
    let issues: [String]
    var passed: Bool { issues.isEmpty }
}

struct EncodeOutput: Identifiable, Sendable {
    let id = UUID()
    let codec: Codec
    let crf: Int
    let url: URL
    let bytes: Int64
    let sourceBytes: Int64
    let command: String
    let verification: Verification
}

enum Encoder {
    static func decideAudio(input: String, probe: ProbeInfo, mode: AudioMode) async throws -> AudioDecision {
        switch mode {
        case .remove:
            return AudioDecision(keep: false, reason: "Audio removed (requested)", peak: nil)
        case .keep:
            guard !probe.audio.isEmpty else { throw ToolError.message("Keep audio was requested, but the source has no audio stream.") }
            return AudioDecision(keep: true, reason: "Audio kept (requested)", peak: nil)
        case .auto:
            guard let peak = try await Probe.maxAudioPeak(input, streamCount: probe.audio.count) else {
                return AudioDecision(keep: false, reason: "No audio stream", peak: nil)
            }
            if peak <= -50 { return AudioDecision(keep: false, reason: "Audio is silent (peak \(Fmt.dB(peak)) ≤ -50), removed", peak: peak) }
            return AudioDecision(keep: true, reason: "Audible audio (peak \(Fmt.dB(peak))), kept", peak: peak)
        }
    }

    static func arguments(input: String, probe: ProbeInfo, codec: Codec, crf: Int, settings: EncodeSettings, keepAudio: Bool, maxWidth: Int?, output: URL) -> [String] {
        var args = ["-hide_banner", "-nostdin", "-n", "-i", input, "-map", "0:v:0"]
        args += codec.videoFlags(crf: crf, pixFmt: settings.pixFmt(for: codec, source: probe), speed: settings.speed)
        args += colorFlags(probe, codec: codec)
        let chain = Filters.chain(probe, maxWidth: maxWidth, frameRate: settings.frameRate)
        if !chain.isEmpty { args += ["-vf", chain] }
        args += codec.audioFlags(keep: keepAudio, streams: probe.audio, lossless: settings.losslessAudio)
        args.append(output.path)
        return args
    }

    /// libx265 drops container color tags unless they are also passed as encoder params, so both are set.
    private static func colorFlags(_ probe: ProbeInfo, codec: Codec) -> [String] {
        func known(_ value: String) -> String? {
            let v = value.lowercased()
            return v.isEmpty || v == "unknown" || v == "unspecified" ? nil : v
        }
        var flags: [String] = []
        if let v = known(probe.colorPrimaries) { flags += ["-color_primaries", v] }
        if let v = known(probe.colorTransfer) { flags += ["-color_trc", v] }
        if let v = known(probe.colorSpace) { flags += ["-colorspace", v] }
        if let v = known(probe.colorRange) { flags += ["-color_range", v == "pc" || v == "jpeg" ? "pc" : "tv"] }
        guard codec == .h265 else { return flags }
        var params: [String] = []
        if let v = known(probe.colorPrimaries) { params.append("colorprim=\(v)") }
        if let v = known(probe.colorTransfer) { params.append("transfer=\(v)") }
        if let v = known(probe.colorSpace) { params.append("colormatrix=\(v)") }
        if known(probe.colorRange) != nil { params.append("range=\(probe.colorRange == "pc" || probe.colorRange == "jpeg" ? "full" : "limited")") }
        if !params.isEmpty { flags += ["-x265-params", params.joined(separator: ":")] }
        return flags
    }

    /// Runs one encode and returns the command line that produced it.
    static func encode(input: String, probe: ProbeInfo, codec: Codec, crf: Int, settings: EncodeSettings, keepAudio: Bool, maxWidth: Int?, output: URL, speed: (@Sendable (Double) -> Void)? = nil, progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        let args = arguments(input: input, probe: probe, codec: codec, crf: crf, settings: settings, keepAudio: keepAudio, maxWidth: maxWidth, output: output)
        try await runWithProgress(args, duration: probe.duration, progress: progress, speed: speed, cleanup: output)
        return Runner.commandLine("ffmpeg", args)
    }

    static func runWithProgress(_ args: [String], duration: Double, progress: @escaping @Sendable (Double) -> Void, speed: (@Sendable (Double) -> Void)? = nil, cleanup: URL?) async throws {
        do {
            _ = try await Runner.checked(try Tools.ffmpeg(), ["-progress", "pipe:1", "-nostats"] + args, keepStdout: false, onStdoutLine: { line in
                if line.hasPrefix("speed="), let speed {
                    let raw = line.dropFirst("speed=".count).trimmingCharacters(in: .whitespaces)
                    if raw.hasSuffix("x"), let x = Double(raw.dropLast()), x > 0 { speed(x) }
                    return
                }
                guard line.hasPrefix("out_time_us="), duration > 0, let us = Double(line.dropFirst("out_time_us=".count)) else { return }
                progress(min(1, max(0, us / 1_000_000 / duration)))
            })
        } catch {
            if let cleanup { try? FileManager.default.removeItem(at: cleanup) }
            throw error
        }
    }

    static func verify(output: URL, codec: Codec, expectedSize: (Int, Int), expectedFPS: Rational?, pixFmt: String, audio: Bool, decode: Bool = true) async throws -> Verification {
        let probe = try await Probe.run(output.path)
        var checks: [String] = []
        var issues: [String] = []
        if probe.videoCodec == codec.probeName { checks.append("codec \(probe.videoCodec)") } else { issues.append("expected \(codec.probeName), got \(probe.videoCodec)") }
        if probe.width == expectedSize.0 && abs(probe.height - expectedSize.1) <= 2 { checks.append(probe.dimensions) } else { issues.append("dimensions \(probe.dimensions), expected \(expectedSize.0)×\(expectedSize.1)") }
        if let expectedFPS {
            if let fps = probe.fps, abs(fps.value - expectedFPS.value) / expectedFPS.value < 0.02 { checks.append("\(fps.pretty) fps") } else { issues.append("frame rate \(probe.fps?.pretty ?? "?"), expected \(expectedFPS.pretty)") }
        }
        if probe.pixFmt == pixFmt { checks.append(pixFmt) } else { issues.append("pixel format \(probe.pixFmt), expected \(pixFmt)") }
        if audio == !probe.audio.isEmpty { checks.append(audio ? "audio present" : "no audio") } else { issues.append(audio ? "audio missing" : "unexpected audio stream") }
        if decode {
            let result = try await Runner.run(try Tools.ffmpeg(), ["-hide_banner", "-nostdin", "-v", "error", "-i", output.path, "-f", "null", "-"])
            try Task.checkCancellation()
            let errors = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if result.status == 0 && errors.isEmpty { checks.append("decodes cleanly") } else { issues.append("decode errors: \(errors.prefix(300))") }
        }
        return Verification(probe: probe, checks: checks, issues: issues)
    }

    static func av1CodecString(_ probe: ProbeInfo, audio: Bool) -> String {
        let profile: Int
        switch probe.profile.lowercased() {
        case "high": profile = 1
        case "professional": profile = 2
        default: profile = 0
        }
        let level = probe.level >= 0 ? probe.level : 8
        let value = String(format: "av01.%d.%02dM.%02d", profile, level, probe.bitDepth)
        return audio ? value + ",opus" : value
    }

    static func htmlSnippet(_ outputs: [EncodeOutput]) -> String {
        var lines = ["<video controls preload=\"metadata\">"]
        for codec in [Codec.av1, .vp9, .h265] {
            guard let output = outputs.first(where: { $0.codec == codec }) else { continue }
            let src = "./" + output.url.lastPathComponent
            if codec == .av1 {
                let codecs = av1CodecString(output.verification.probe, audio: !output.verification.probe.audio.isEmpty)
                lines.append("  <source src=\"\(src)\" type='video/webm; codecs=\"\(codecs)\"'>")
            } else {
                lines.append("  <source src=\"\(src)\" type=\"\(codec.mimeType)\">")
            }
        }
        lines.append("</video>")
        return lines.joined(separator: "\n")
    }
}
