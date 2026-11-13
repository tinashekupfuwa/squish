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

    func audioFlags(keep: Bool) -> [String] {
        keep ? ["-map", "0:a:0", "-c:a", self == .h265 ? "aac" : "libopus"] : ["-an"]
    }
}

enum AudioMode: String, CaseIterable, Identifiable, Sendable {
    case auto, keep, remove
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "Auto (drop if silent)"
        case .keep: return "Keep first track"
        case .remove: return "Remove"
        }
    }
}

enum FrameRateMode: String, CaseIterable, Identifiable, Sendable {
    case preserve, cap
    var id: String { rawValue }
    var label: String { self == .preserve ? "Same as source" : "Cap at ~30 fps (smaller files)" }
}

enum SpeedMode: String, CaseIterable, Identifiable, Sendable {
    case skill, faster
    var id: String { rawValue }
    var label: String { self == .skill ? "Best (skill defaults, slowest)" : "Faster (slightly larger files)" }
}

struct EncodeSettings: Sendable {
    var vp9 = true
    var h265 = true
    var av1 = false
    var crf: [Codec: Int] = [.vp9: 42, .h265: 30, .av1: 42]
    var audio: AudioMode = .auto
    var frameRate: FrameRateMode = .preserve
    var tenBit = false
    var maxWidth: Int? = nil
    var speed: SpeedMode = .skill

    var enabledCodecs: [Codec] {
        Codec.allCases.filter { codec in
            switch codec {
            case .vp9: return vp9
            case .h265: return h265
            case .av1: return av1
            }
        }
    }
    var pixFmt: String { tenBit ? "yuv420p10le" : "yuv420p" }
    func crf(for codec: Codec) -> Int { crf[codec] ?? codec.defaultCRF }
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
            return AudioDecision(keep: true, reason: "First audio track kept (requested)", peak: nil)
        case .auto:
            guard let peak = try await Probe.maxAudioPeak(input, streamCount: probe.audio.count) else {
                return AudioDecision(keep: false, reason: "No audio stream", peak: nil)
            }
            if peak <= -50 { return AudioDecision(keep: false, reason: "Audio is silent (peak \(Fmt.dB(peak)) ≤ -50), removed", peak: peak) }
            return AudioDecision(keep: true, reason: "Audible audio (peak \(Fmt.dB(peak))), first track kept", peak: peak)
        }
    }

    static func arguments(input: String, probe: ProbeInfo, codec: Codec, crf: Int, settings: EncodeSettings, keepAudio: Bool, maxWidth: Int?, output: URL) -> [String] {
        var args = ["-hide_banner", "-nostdin", "-n", "-i", input, "-map", "0:v:0"]
        args += codec.videoFlags(crf: crf, pixFmt: settings.pixFmt, speed: settings.speed)
        let chain = Filters.chain(probe, maxWidth: maxWidth, frameRate: settings.frameRate)
        if !chain.isEmpty { args += ["-vf", chain] }
        args += codec.audioFlags(keep: keepAudio)
        args.append(output.path)
        return args
    }

    /// Runs one encode and returns the command line that produced it.
    static func encode(input: String, probe: ProbeInfo, codec: Codec, crf: Int, settings: EncodeSettings, keepAudio: Bool, maxWidth: Int?, output: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        let args = arguments(input: input, probe: probe, codec: codec, crf: crf, settings: settings, keepAudio: keepAudio, maxWidth: maxWidth, output: output)
        try await runWithProgress(args, duration: probe.duration, progress: progress, cleanup: output)
        return Runner.commandLine("ffmpeg", args)
    }

    static func runWithProgress(_ args: [String], duration: Double, progress: @escaping @Sendable (Double) -> Void, cleanup: URL?) async throws {
        do {
            _ = try await Runner.checked(try Tools.ffmpeg(), ["-progress", "pipe:1", "-nostats"] + args, keepStdout: false, onStdoutLine: { line in
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
