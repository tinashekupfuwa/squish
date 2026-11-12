import Foundation

struct Candidate: Identifiable, Hashable, Sendable {
    var id = UUID()
    var codec: Codec
    var crf: Int

    static let defaults: [Candidate] = [
        Candidate(codec: .vp9, crf: 36), Candidate(codec: .vp9, crf: 42), Candidate(codec: .vp9, crf: 48),
        Candidate(codec: .h265, crf: 24), Candidate(codec: .h265, crf: 30), Candidate(codec: .h265, crf: 36),
    ]
}

struct CompareOptions: Sendable {
    var candidates: [Candidate] = Candidate.defaults
    var samplePositions: [Double] = [0.25, 0.5, 0.75]
    var sampleDuration: Double = 1
    var maxWidth: Int? = nil
    var tenBit = false
    var frameRate: FrameRateMode = .cap
    var speed: SpeedMode = .skill
    var psnr = false
}

struct CandidateResult: Identifiable, Sendable {
    let id: UUID
    let candidate: Candidate
    let previewURL: URL
    let stillURL: URL?
    let previewBytes: Int64
    let estimatedBytes: Int64
    let ssim: Double
    let psnr: Double?
    var onFrontier = false
    var recommended = false
}

struct CompareResult: Sendable {
    let source: URL
    let probe: ProbeInfo
    let outputDirectory: URL
    let referenceURL: URL
    let referenceStill: URL?
    let referenceDuration: Double
    let sampleStarts: [Double]
    let sampleDuration: Double
    let results: [CandidateResult]

    var ordered: [CandidateResult] {
        results.sorted { a, b in
            let ia = Codec.allCases.firstIndex(of: a.candidate.codec)!, ib = Codec.allCases.firstIndex(of: b.candidate.codec)!
            return ia != ib ? ia < ib : a.candidate.crf < b.candidate.crf
        }
    }
    var recommended: CandidateResult? { results.first { $0.recommended } }

    func size(_ result: CandidateResult) -> String {
        Fmt.bytes(result.estimatedBytes, sharedWith: results.map(\.estimatedBytes))
    }

    var markdown: String {
        var lines = ["| Format | CRF | Estimated size | File |", "| --- | ---: | ---: | --- |"]
        for r in ordered {
            lines.append("| \(r.candidate.codec.label) | \(r.candidate.crf) | \(size(r)) | \(Fmt.markdownLink("Preview", r.previewURL)) |")
        }
        lines.append("")
        if let rec = recommended { lines.append(recommendationText(rec)) }
        lines.append("")
        lines.append(coverageText)
        return lines.joined(separator: "\n")
    }

    func recommendationText(_ rec: CandidateResult) -> String {
        "Recommendation: \(rec.candidate.codec.label) at CRF \(rec.candidate.crf), about \(size(rec)) for the full video. It offers the best balance of quality and size among the tested settings."
    }

    var coverageText: String {
        let positions = sampleStarts.map { Fmt.duration($0) }.joined(separator: ", ")
        var text = "Samples: \(sampleStarts.count) × \(Fmt.duration(sampleDuration)) starting at \(positions) of a \(Fmt.duration(probe.duration)) source (\(Fmt.duration(referenceDuration)) reference reel). Sizes are video-only estimates for the full video; linked files are video-only sample previews."
        if sampleStarts.count < 3 || referenceDuration < probe.duration * 0.05 && probe.duration > 60 {
            text += " Few or clustered samples give weaker whole-video evidence."
        }
        return text
    }
}

enum CompareEngine {
    static func run(input: URL, options: CompareOptions, status: @escaping @Sendable (String, Double) -> Void) async throws -> CompareResult {
        guard (2...8).contains(options.candidates.count) else { throw ToolError.message("Choose between 2 and 8 codec/CRF candidates.") }
        let ffmpeg = try Tools.ffmpeg()
        status("Inspecting source…", 0)
        let probe = try await Probe.run(input.path)
        guard probe.duration > 0 else { throw ToolError.message("Could not determine the source duration.") }

        let stem = input.deletingPathExtension().lastPathComponent
        let dir = OutputLocation.unique(try OutputLocation.directory(for: input).appendingPathComponent("\(stem)-compare", isDirectory: true))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let length = min(options.sampleDuration, probe.duration)
        let starts = options.samplePositions.map { position in
            min(max(0, position * probe.duration - length / 2), max(0, probe.duration - length))
        }
        let pixFmt = options.tenBit ? "yuv420p10le" : "yuv420p"

        status("Building lossless reference reel…", 0.02)
        var graph = "[0:v:0]split=\(starts.count)" + starts.indices.map { "[i\($0)]" }.joined() + ";"
        for (i, start) in starts.enumerated() {
            graph += "[i\(i)]trim=start=\(String(format: "%.3f", start)):duration=\(String(format: "%.3f", length)),setpts=PTS-STARTPTS[s\(i)];"
        }
        graph += starts.indices.map { "[s\($0)]" }.joined() + "concat=n=\(starts.count):v=1:a=0"
        let transforms = Filters.chain(probe, maxWidth: options.maxWidth, frameRate: options.frameRate)
        if !transforms.isEmpty { graph += "," + transforms }
        graph += ",format=\(pixFmt)[ref]"
        let reference = dir.appendingPathComponent("reference-ffv1.mkv")
        _ = try await Runner.checked(ffmpeg, ["-hide_banner", "-nostdin", "-y", "-i", input.path, "-filter_complex", graph, "-map", "[ref]", "-c:v", "ffv1", "-an", reference.path])
        let refProbe = try await Probe.run(reference.path)
        let refDuration = refProbe.duration > 0 ? refProbe.duration : length * Double(starts.count)
        let referenceStill = try? await still(of: reference, at: refDuration / 2, to: dir.appendingPathComponent("reference.png"))

        var results: [CandidateResult] = []
        let total = Double(options.candidates.count)
        for (i, candidate) in options.candidates.enumerated() {
            let codec = candidate.codec
            let name = "\(stem)-\(codec.rawValue)-crf\(candidate.crf).\(codec.fileExtension)"
            let preview = OutputLocation.unique(dir.appendingPathComponent(name))
            let base = 0.05 + 0.95 * Double(i) / total
            status("Encoding \(codec.shortLabel) CRF \(candidate.crf) (\(i + 1)/\(Int(total)))…", base)
            let args = ["-hide_banner", "-nostdin", "-n", "-i", reference.path, "-map", "0:v:0"] + codec.videoFlags(crf: candidate.crf, pixFmt: pixFmt, speed: options.speed) + ["-an", preview.path]
            try await Encoder.runWithProgress(args, duration: refDuration, progress: { p in status("Encoding \(codec.shortLabel) CRF \(candidate.crf) (\(i + 1)/\(Int(total)))…", base + 0.8 * p / total * 0.95) }, cleanup: preview)

            status("Measuring \(codec.shortLabel) CRF \(candidate.crf)…", base + 0.85 / total)
            let ssim = try await metric("ssim", candidate: preview, reference: reference, pattern: "All:([0-9.]+)")
            let psnr = options.psnr ? try await metric("psnr", candidate: preview, reference: reference, pattern: "average:([0-9.inf]+)") : nil
            let stillURL = try? await still(of: preview, at: refDuration / 2, to: preview.deletingPathExtension().appendingPathExtension("png"))
            let bytes = preview.fileSize
            let estimate = Int64((Double(bytes) * probe.duration / refDuration).rounded(.up))
            results.append(CandidateResult(id: candidate.id, candidate: candidate, previewURL: preview, stillURL: stillURL, previewBytes: bytes, estimatedBytes: estimate, ssim: ssim, psnr: psnr))
        }

        recommend(&results)
        status("Done", 1)
        return CompareResult(source: input, probe: probe, outputDirectory: dir, referenceURL: reference, referenceStill: referenceStill, referenceDuration: refDuration, sampleStarts: starts, sampleDuration: length, results: results)
    }

    static func recommend(_ results: inout [CandidateResult]) {
        for i in results.indices {
            let r = results[i]
            results[i].onFrontier = !results.contains { o in
                o.ssim >= r.ssim && o.estimatedBytes <= r.estimatedBytes && (o.ssim > r.ssim || o.estimatedBytes < r.estimatedBytes)
            }
        }
        let frontier = results.indices.filter { results[$0].onFrontier }
        guard !frontier.isEmpty else { return }
        let ssims = frontier.map { results[$0].ssim }
        let sizes = frontier.map { Double(results[$0].estimatedBytes) }
        let ssimRange = (ssims.max()! - ssims.min()!) == 0 ? 1 : ssims.max()! - ssims.min()!
        let sizeRange = (sizes.max()! - sizes.min()!) == 0 ? 1 : sizes.max()! - sizes.min()!
        let best = frontier.max { a, b in
            let sa = ((results[a].ssim - ssims.min()!) / ssimRange + 1 - (Double(results[a].estimatedBytes) - sizes.min()!) / sizeRange) / 2
            let sb = ((results[b].ssim - ssims.min()!) / ssimRange + 1 - (Double(results[b].estimatedBytes) - sizes.min()!) / sizeRange) / 2
            if abs(sa - sb) > 1e-12 { return sa < sb }
            if results[a].estimatedBytes != results[b].estimatedBytes { return results[a].estimatedBytes > results[b].estimatedBytes }
            return results[a].ssim < results[b].ssim
        }!
        results[best].recommended = true
    }

    private static func metric(_ filter: String, candidate: URL, reference: URL, pattern: String) async throws -> Double {
        let result = try await Runner.checked(try Tools.ffmpeg(), [
            "-hide_banner", "-nostdin", "-i", candidate.path, "-i", reference.path,
            "-lavfi", "[0:v]setpts=PTS-STARTPTS[d];[1:v]setpts=PTS-STARTPTS[r];[d][r]\(filter)", "-f", "null", "-"
        ])
        let regex = try NSRegularExpression(pattern: pattern)
        let text = result.stderr as NSString
        guard let match = regex.matches(in: result.stderr, range: NSRange(location: 0, length: text.length)).last else {
            throw ToolError.message("Could not read \(filter.uppercased()) for \(candidate.lastPathComponent).")
        }
        let raw = text.substring(with: match.range(at: 1))
        return raw == "inf" ? .infinity : Double(raw) ?? 0
    }

    private static func still(of video: URL, at time: Double, to output: URL) async throws -> URL {
        _ = try await Runner.checked(try Tools.ffmpeg(), ["-hide_banner", "-nostdin", "-y", "-ss", String(format: "%.3f", time), "-i", video.path, "-frames:v", "1", output.path])
        return output
    }
}
