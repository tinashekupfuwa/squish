import Foundation

struct AuditOptions: Sendable {
    var project: URL?
    var startURL: String = ""
    var originals: URL?
    var density: Double = 2
    var maxPages = 1
    var viewports: [Viewport] = Viewport.defaults
    var analyzeAudio = true
    var manualDisplayWidth: Int?
}

struct VideoAsset: Identifiable, Hashable, Sendable {
    let key: String
    let localURL: URL?
    var probe: ProbeInfo?
    var probeError: String?
    var peak: Double?
    var audioError: String?
    var id: String { key }
    var name: String { localURL?.lastPathComponent ?? URL(string: key)?.lastPathComponent ?? key }
    var input: String { localURL?.path ?? key }
    var bytes: Int64 { probe?.bytes ?? localURL?.fileSize ?? 0 }
    var ext: String { (localURL?.pathExtension ?? URL(string: key)?.pathExtension ?? "").lowercased() }
}

struct RenderedUsage: Hashable, Sendable {
    let page: String
    let viewport: Viewport
    let video: RenderedVideo
    let pictureWidth: Double
    let aboveFold: Bool
}

struct Finding: Hashable, Sendable {
    enum Kind: String, Sendable {
        case resolution = "Excess resolution"
        case compression = "Potential compression savings"
        case audio = "Audio"
        case delivery = "Delivery"
        case fullscreen = "Enlargement"
        case source = "Source"
        case coverage = "Coverage"
    }
    let kind: Kind
    let text: String
    let measured: Bool
}

struct LogicalVideo: Identifiable, Sendable {
    let id: String
    var variants: [VideoAsset]
    var usages: [SourceUsage]
    var rendered: [RenderedUsage]
    var originals: [VideoAsset] = []
    var bestSource: VideoAsset?
    var bestSourceNote = ""
    var maxPictureWidth: Double?
    var requiredWidth: Int?
    var recommendedWidth: Int?
    var basis = "unmeasured"
    var findings: [Finding] = []
    var action = ""

    var name: String { variants.first?.name ?? id }
    var totalBytes: Int64 { variants.reduce(0) { $0 + $1.bytes } }
    var largestVariant: VideoAsset? { variants.max { ($0.probe?.pixels ?? 0) < ($1.probe?.pixels ?? 0) } }
    var pages: [String] { Array(Set(rendered.map(\.page))).sorted() }
    var hasControls: Bool { usages.contains { $0.element?.controls == true } || rendered.contains { $0.video.controls } }
    var allMutedWithoutControls: Bool {
        let fromSource = usages.compactMap(\.element)
        let all = fromSource.map { ($0.muted, $0.controls) } + rendered.map { ($0.video.muted, $0.video.controls) }
        return !all.isEmpty && all.allSatisfy { $0.0 && !$0.1 }
    }
    var currentDimensions: String { variants.compactMap { $0.probe?.dimensions }.first ?? "?" }
}

struct AuditReport: Sendable {
    let options: AuditOptions
    let scan: ProjectScan?
    var videos: [LogicalVideo]
    var unused: [VideoAsset]
    var unresolved: [String]
    var embeds: [String]
    var pages: [String]
    var pageErrors: [String]
    var gaps: [String]
    let date = Date()

    var totalBytes: Int64 { videos.reduce(0) { $0 + $1.totalBytes } }

    var markdown: String {
        var out = ["# Video audit", ""]
        if let project = options.project { out.append("Project: `\(project.path)`  ") }
        if !options.startURL.isEmpty { out.append("Start URL: \(options.startURL)  ") }
        out.append("Date: \(date.formatted(date: .abbreviated, time: .shortened))  ")
        out.append("Density: \(String(format: "%g", options.density))× source pixels per CSS pixel")
        out.append("")
        out.append("| Video | Pages / usages | Current | Max display | Recommended | Best source | Evidence | Action |")
        out.append("| --- | --- | --- | --- | --- | --- | --- | --- |")
        for v in videos {
            let usages = (v.pages.map { URL(string: $0)?.path ?? $0 } + v.usages.map(\.location)).joined(separator: "<br>")
            let current = v.variants.map { "\($0.name): \($0.probe?.dimensions ?? "?"), \(Fmt.bytes($0.bytes))" }.joined(separator: "<br>")
            let display = v.maxPictureWidth.map { "\(Int($0.rounded())) CSS px" } ?? "unmeasured"
            let rec = v.recommendedWidth.map { "\($0) px wide (\(v.basis))" } ?? "keep (\(v.basis))"
            let evidence = v.findings.map { "\($0.kind.rawValue): \($0.text)\($0.measured ? "" : " _(unmeasured)_")" }.joined(separator: "<br>")
            out.append("| \(v.name) | \(usages) | \(current) | \(display) | \(rec) | \(v.bestSource?.name ?? "–") \(v.bestSourceNote) | \(evidence) | \(v.action) |")
        }
        out.append("")
        out.append("Savings are unmeasured until an encode confirms them.")
        if !unused.isEmpty {
            out.append("")
            out.append("## Video files with no references found")
            for u in unused { out.append("- `\(u.key)` (\(Fmt.bytes(u.bytes)))") }
        }
        if !embeds.isEmpty || !unresolved.isEmpty {
            out.append("")
            out.append("## Not re-encodable here")
            for e in embeds { out.append("- Third-party player: \(e)") }
            for u in unresolved { out.append("- \(u)") }
        }
        out.append("")
        out.append("## Coverage")
        if pages.isEmpty {
            out.append("- No pages rendered; display sizes were not measured.")
        } else {
            out.append("- Pages: " + pages.joined(separator: ", "))
            out.append("- Layouts: " + options.viewports.map { "\($0.name) \($0.width)×\($0.height)" }.joined(separator: ", "))
            out.append("- Interaction: each page scrolled top to bottom to trigger lazy loading.")
        }
        for e in pageErrors { out.append("- Failed: \(e)") }
        for g in gaps { out.append("- Gap: \(g)") }
        return out.joined(separator: "\n")
    }
}

enum Auditor {
    typealias Log = @Sendable (String) -> Void

    static func run(_ options: AuditOptions, log: @escaping Log) async throws -> AuditReport {
        var scan: ProjectScan?
        if let project = options.project {
            log("Scanning source files in \(project.lastPathComponent)…")
            scan = try await Task.detached { try SourceScanner.scan(root: project) }.value
            log("Scanned \(scan!.scannedFiles) source files, found \(scan!.videoFiles.count) video files and \(scan!.usages.count) references.")
        }
        let index = scan.map { VideoIndex(root: $0.root, videos: $0.videoFiles) }

        var pages: [String] = []
        var pageErrors: [String] = []
        var embeds: Set<String> = []
        var rendered: [(key: String, usage: RenderedUsage, siblings: [String])] = []
        if let start = URL(string: options.startURL.trimmingCharacters(in: .whitespaces)), start.scheme?.hasPrefix("http") == true || start.isFileURL {
            let renderer = await PageRenderer()
            let queue = try await crawl(start, maxPages: options.maxPages, renderer: renderer, log: log)
            for page in queue {
                for viewport in options.viewports {
                    try Task.checkCancellation()
                    log("Rendering \(page.path.isEmpty ? page.absoluteString : page.path) at \(viewport.name) (\(viewport.width) px)…")
                    do {
                        let snapshot = try await renderer.render(page, viewport: viewport)
                        if !pages.contains(page.absoluteString) { pages.append(page.absoluteString) }
                        embeds.formUnion(snapshot.embeds)
                        for video in snapshot.videos where !video.currentSrc.isEmpty {
                            let key = mapKey(video.currentSrc, index: index)
                            let siblings = video.sources.map { mapKey($0, index: index) }
                            let usage = RenderedUsage(page: page.absoluteString, viewport: viewport, video: video, pictureWidth: video.visible ? pictureWidth(video) : 0, aboveFold: video.visible && video.top < Double(viewport.height))
                            rendered.append((key, usage, siblings))
                        }
                    } catch {
                        pageErrors.append("\(page.absoluteString) at \(viewport.name): \(error.localizedDescription)")
                    }
                }
            }
            await renderer.close()
        }

        // Group alternate encodes: same folder and stem, the same element, or the same rendered player.
        var groups = UnionFind()
        var assets: [String: VideoAsset] = [:]
        for file in scan?.videoFiles ?? [] {
            let key = file.relativePath(from: scan!.root)
            assets[key] = VideoAsset(key: key, localURL: file)
            groups.add(key)
            groups.union(key, "stem:" + (key as NSString).deletingPathExtension.lowercased())
        }
        let usages = scan?.usages ?? []
        var unresolved: [String] = []
        for usage in usages {
            if let key = usage.resolved {
                if let element = usage.elementKey { groups.union(key, "el:" + element) }
            } else if usage.isRemote {
                let key = usage.reference.hasPrefix("//") ? "https:" + usage.reference : usage.reference
                if assets[key] == nil { assets[key] = VideoAsset(key: key, localURL: nil) }
                groups.add(key)
                if let element = usage.elementKey { groups.union(key, "el:" + element) }
            } else {
                unresolved.append("Unresolved reference `\(usage.reference)` at \(usage.location)")
            }
        }
        for item in rendered {
            if assets[item.key] == nil { assets[item.key] = VideoAsset(key: item.key, localURL: nil) }
            groups.add(item.key)
            for sibling in item.siblings {
                if assets[sibling] == nil { assets[sibling] = VideoAsset(key: sibling, localURL: nil) }
                groups.union(item.key, sibling)
            }
        }

        var videos: [String: LogicalVideo] = [:]
        for key in assets.keys.sorted() {
            let root = groups.find(key)
            videos[root, default: LogicalVideo(id: root, variants: [], usages: [], rendered: [])].variants.append(assets[key]!)
        }
        let keyToGroup = Dictionary(uniqueKeysWithValues: assets.keys.map { ($0, groups.find($0)) })
        for usage in usages {
            let key = usage.resolved ?? (usage.isRemote ? (usage.reference.hasPrefix("//") ? "https:" + usage.reference : usage.reference) : nil)
            if let key, let group = keyToGroup[key] { videos[group]?.usages.append(usage) }
        }
        for item in rendered { if let group = keyToGroup[item.key] { videos[group]?.rendered.append(item.usage) } }

        let used = videos.values.filter { !$0.usages.isEmpty || !$0.rendered.isEmpty }
        let unusedAssets = videos.values.filter { $0.usages.isEmpty && $0.rendered.isEmpty }.flatMap(\.variants).sorted { $0.key < $1.key }

        // Probe and analyse.
        var results: [LogicalVideo] = []
        let originalPool = (scan?.videoFiles ?? []) + (options.originals.map { SourceScanner.videos(in: $0) } ?? [])
        for var video in used.sorted(by: { $0.name.lowercased() < $1.name.lowercased() }) {
            try Task.checkCancellation()
            for i in video.variants.indices {
                log("Inspecting \(video.variants[i].name)…")
                do {
                    video.variants[i].probe = try await Probe.run(video.variants[i].input)
                } catch {
                    video.variants[i].probeError = error.localizedDescription
                }
                if options.analyzeAudio, let probe = video.variants[i].probe, !probe.audio.isEmpty {
                    log("Analyzing audio in \(video.variants[i].name)…")
                    do { video.variants[i].peak = try await Probe.maxAudioPeak(video.variants[i].input, streamCount: probe.audio.count) } catch { video.variants[i].audioError = error.localizedDescription }
                }
            }
            video.originals = try await findOriginals(for: video, pool: originalPool, scanRoot: scan?.root, log: log)
            assess(&video, options: options)
            results.append(video)
        }
        var unused = unusedAssets
        for i in unused.indices { unused[i].probe = try? await Probe.run(unused[i].input) }

        var gaps: [String] = []
        if pages.isEmpty { gaps.append("No page URL was rendered, so rendered display sizes, currentSrc, and loading position are unmeasured.") }
        else { gaps.append("Modals, galleries, tabs, and other click-driven players were not opened; videos only reachable that way are covered by the source scan, not by measurement.") }
        if scan == nil { gaps.append("No source folder was supplied, so originals and source references could not be checked.") }
        if options.originals == nil { gaps.append("No originals folder was supplied; only files inside the project were considered as higher-quality sources.") }
        log("Audit complete: \(results.count) videos in use, \(unused.count) unreferenced files.")
        return AuditReport(options: options, scan: scan, videos: results, unused: unused, unresolved: unresolved, embeds: embeds.sorted(), pages: pages, pageErrors: pageErrors, gaps: gaps)
    }

    static func pictureWidth(_ v: RenderedVideo) -> Double {
        guard v.vw > 0, v.vh > 0 else { return v.w }
        let iw = Double(v.vw), ih = Double(v.vh)
        let sx = v.w / iw, sy = v.h / ih
        switch v.fit {
        case "cover": return iw * max(sx, sy)
        case "none": return iw
        case "scale-down": return iw * min(1, min(sx, sy))
        case "fill": return max(v.w, v.h * iw / ih)
        default: return iw * min(sx, sy)
        }
    }

    static func mapKey(_ src: String, index: VideoIndex?) -> String {
        if let index, let url = URL(string: src), let rel = index.suffixMatch(url.path.removingPercentEncoding ?? url.path) { return rel }
        return src
    }

    static func crawl(_ start: URL, maxPages: Int, renderer: PageRenderer, log: Log) async throws -> [URL] {
        guard maxPages > 1 else { return [start] }
        var queue = [start]
        var seen: Set<String> = [normalize(start)]
        if let sitemap = URL(string: "/sitemap.xml", relativeTo: start), let (data, _) = try? await URLSession.shared.data(from: sitemap), let xml = String(data: data, encoding: .utf8) {
            let regex = try NSRegularExpression(pattern: "<loc>\\s*([^<\\s]+)\\s*</loc>")
            for match in regex.matches(in: xml, range: NSRange(location: 0, length: (xml as NSString).length)) {
                if let url = URL(string: (xml as NSString).substring(with: match.range(at: 1))), url.host == start.host, seen.insert(normalize(url)).inserted { queue.append(url) }
            }
        }
        var i = 0
        while i < queue.count, queue.count < maxPages * 3, i < maxPages {
            log("Discovering links on \(queue[i].path.isEmpty ? "/" : queue[i].path)…")
            if let snapshot = try? await renderer.render(queue[i], viewport: Viewport.defaults[2], scroll: false) {
                for link in snapshot.links {
                    guard let url = URL(string: link), url.host == start.host, url.scheme == start.scheme else { continue }
                    let ext = url.pathExtension.lowercased()
                    if !ext.isEmpty, !["html", "htm", "php"].contains(ext) { continue }
                    if seen.insert(normalize(url)).inserted { queue.append(url) }
                }
            }
            i += 1
        }
        return Array(queue.prefix(maxPages))
    }

    private static func normalize(_ url: URL) -> String {
        var c = URLComponents(url: url, resolvingAgainstBaseURL: true)
        c?.fragment = nil
        var s = c?.url?.absoluteString ?? url.absoluteString
        if s.hasSuffix("/") { s.removeLast() }
        return s
    }

    static func normalizedStem(_ name: String) -> String {
        var stem = (name as NSString).deletingPathExtension.lowercased()
        let suffix = try! NSRegularExpression(pattern: "([-_. ](compressed|min|web|opt|optimized|small|medium|large|final|export|h264|h265|hevc|vp9|av1|\\d{3,4}p|\\d+x|@\\dx|v\\d+|crf\\d+|preview|lowres|hires|hq|lq))+$")
        stem = suffix.stringByReplacingMatches(in: stem, range: NSRange(location: 0, length: (stem as NSString).length), withTemplate: "")
        return stem
    }

    static func findOriginals(for video: LogicalVideo, pool: [URL], scanRoot: URL?, log: Log) async throws -> [VideoAsset] {
        let stems = Set(video.variants.map { normalizedStem($0.name) })
        let own = Set(video.variants.compactMap { $0.localURL?.standardizedFileURL.path })
        guard let reference = video.variants.compactMap(\.probe).first else { return [] }
        var found: [VideoAsset] = []
        var checked = Set<String>()
        for url in pool where stems.contains(normalizedStem(url.lastPathComponent)) {
            let path = url.standardizedFileURL.path
            guard !own.contains(path), checked.insert(path).inserted else { continue }
            log("Checking possible original \(url.lastPathComponent)…")
            guard let probe = try? await Probe.run(url.path) else { continue }
            let durationOK = abs(probe.duration - reference.duration) <= max(0.25, reference.duration * 0.01)
            let aspectOK = reference.aspect > 0 && abs(probe.aspect - reference.aspect) / reference.aspect < 0.02
            guard durationOK, aspectOK else { continue }
            let key = scanRoot.map { url.relativePath(from: $0) } ?? url.path
            found.append(VideoAsset(key: key, localURL: url, probe: probe))
        }
        return found
    }

    static func assess(_ video: inout LogicalVideo, options: AuditOptions) {
        var findings: [Finding] = []
        let probed = video.variants.filter { $0.probe != nil }
        if let original = video.originals.max(by: { ($0.probe!.pixels, $0.probe!.bitRate) < ($1.probe!.pixels, $1.probe!.bitRate) }) {
            video.bestSource = original
            video.bestSourceNote = "(original: matched by name, duration, and aspect)"
        } else {
            video.bestSource = probed.max { ($0.probe!.pixels, $0.probe!.bitRate) < ($1.probe!.pixels, $1.probe!.bitRate) }
            video.bestSourceNote = video.bestSource == nil ? "" : "(current asset; no original found)"
            if video.bestSource != nil { findings.append(Finding(kind: .source, text: "No higher-quality original found; re-encoding would start from an already compressed file.", measured: true)) }
        }
        for variant in video.variants where variant.probe == nil {
            findings.append(Finding(kind: .coverage, text: "Could not inspect \(variant.name): \(variant.probeError ?? "unknown error")", measured: true))
        }
        guard let source = video.bestSource?.probe ?? video.largestVariant?.probe else {
            video.findings = findings
            video.action = "Resolve the asset location before optimizing."
            return
        }
        let current = video.largestVariant?.probe ?? source

        // Required resolution.
        let measured = video.rendered.filter { $0.pictureWidth > 0 }
        if let widest = measured.max(by: { $0.pictureWidth < $1.pictureWidth }) {
            video.maxPictureWidth = widest.pictureWidth
            let required = Int((widest.pictureWidth * options.density).rounded(.up))
            video.requiredWidth = required
            video.recommendedWidth = Filters.even(min(source.width, required))
            video.basis = "measured, \(widest.viewport.name) on \(URL(string: widest.page)?.path ?? widest.page)"
            if required < current.width {
                findings.append(Finding(kind: .resolution, text: "Encoded \(current.width) px wide; largest display is \(Int(widest.pictureWidth.rounded())) CSS px (\(widest.video.fit)), so \(String(format: "%g", options.density))× needs \(Filters.even(required)) px.", measured: true))
            }
        } else if let manual = options.manualDisplayWidth {
            let required = Int((Double(manual) * options.density).rounded(.up))
            video.requiredWidth = required
            video.recommendedWidth = Filters.even(min(source.width, required))
            video.basis = "user-specified \(manual) CSS px"
            if required < current.width { findings.append(Finding(kind: .resolution, text: "Encoded \(current.width) px wide; user-specified display width needs \(Filters.even(required)) px.", measured: false)) }
        } else {
            let hint = video.usages.compactMap { $0.element?.widthAttribute }.max()
            findings.append(Finding(kind: .resolution, text: "Display size not measured\(hint.map { "; width attribute suggests \($0) CSS px" } ?? ""). Supply a page URL to measure it.", measured: false))
        }
        if video.hasControls {
            findings.append(Finding(kind: .fullscreen, text: "Player has controls, so fullscreen is possible. Keep a full-resolution version or create a separate inline derivative.", measured: true))
        }

        // Compression.
        let modern: Set<String> = ["vp9", "hevc", "av1"]
        for variant in probed {
            let probe = variant.probe!
            let rate = probe.bitRate > 0 ? " at \(Fmt.bitrate(probe.bitRate))" : ""
            if !modern.contains(probe.videoCodec) {
                findings.append(Finding(kind: .compression, text: "\(variant.name) is \(probe.videoCodec.uppercased())\(rate); VP9/H.265 usually encode smaller.", measured: false))
            }
            if let fps = probe.fps, fps.value > 30.5 { findings.append(Finding(kind: .compression, text: "\(variant.name) runs at \(fps.pretty) fps; capping to ~30 fps saves bytes for ordinary web playback.", measured: true)) }
            if probe.bitDepth > 8 { findings.append(Finding(kind: .compression, text: "\(variant.name) is \(probe.bitDepth)-bit (\(probe.pixFmt)).", measured: true)) }
        }
        let containers = Set(video.variants.map(\.ext))
        if !(containers.contains("webm") && (containers.contains("mp4") || containers.contains("m4v"))) {
            findings.append(Finding(kind: .delivery, text: "Single format (\(containers.sorted().joined(separator: ", "))). Serving VP9 WebM with an H.265 MP4 fallback lets each browser pick the smaller file.", measured: true))
        }
        for variant in video.variants where variant.localURL != nil && !video.usages.contains(where: { $0.resolved == variant.key }) && !video.rendered.contains(where: { Auditor.mapKey($0.video.currentSrc, index: nil) == variant.key }) && video.usages.count > 0 {
            if !video.usages.contains(where: { $0.resolved == variant.key }) { findings.append(Finding(kind: .delivery, text: "\(variant.name) shares this video's name but is not referenced.", measured: true)) }
        }

        // Audio.
        for variant in probed where !(variant.probe!.audio.isEmpty) {
            if let peak = variant.peak {
                if peak <= -50 {
                    findings.append(Finding(kind: .audio, text: "\(variant.name) has a silent audio track (peak \(Fmt.dB(peak))); remove it.", measured: true))
                } else if video.allMutedWithoutControls {
                    findings.append(Finding(kind: .audio, text: "\(variant.name) has audible audio (peak \(Fmt.dB(peak))) but every usage is muted without controls. Confirm it is video-only before removing.", measured: true))
                }
            } else if let error = variant.audioError {
                findings.append(Finding(kind: .audio, text: "Audio analysis failed for \(variant.name): \(error)", measured: false))
            }
        }

        // Delivery from source and rendered attributes.
        var delivery: Set<String> = []
        let elements = video.usages.compactMap(\.element)
        let attrs = elements.map { ($0.autoplay, $0.muted, $0.playsinline, $0.preload, $0.poster) } + video.rendered.map { ($0.video.autoplay, $0.video.muted, $0.video.playsinline, $0.video.preload, $0.video.poster) }
        for (autoplay, muted, playsinline, preload, poster) in attrs {
            if autoplay && !muted { delivery.insert("Autoplays without muted, which browsers block.") }
            if autoplay && !playsinline { delivery.insert("Autoplays without playsinline; iOS may force fullscreen.") }
            if !autoplay && (preload == nil || preload == "auto") { delivery.insert("No preload=\"metadata\" or \"none\" on a click-to-play video, so browsers may download it eagerly.") }
            if !autoplay && !poster { delivery.insert("No poster image for a click-to-play video.") }
        }
        if let first = video.rendered.first(where: { $0.aboveFold && ($0.video.autoplay || $0.video.preload == "auto") }), video.totalBytes > 0 {
            delivery.insert("Fetched during initial load on \(URL(string: first.page)?.path ?? first.page) (\(first.viewport.name)); its size directly affects page load.")
        }
        if video.rendered.contains(where: { $0.video.error != 0 }) { delivery.insert("The player reported a media error while rendering.") }
        findings += delivery.sorted().map { Finding(kind: .delivery, text: $0, measured: true) }
        video.findings = findings

        // Action.
        var steps: [String] = []
        if video.variants.allSatisfy({ $0.localURL == nil }) {
            steps.append("Asset is hosted outside the project; re-encode from the original and replace it where it is hosted.")
        } else {
            let width = video.hasControls ? nil : video.recommendedWidth.flatMap { $0 < current.width ? $0 : nil }
            steps.append("Re-encode to VP9 WebM + H.265 MP4" + (width.map { " at \($0) px wide" } ?? " at current resolution"))
            if video.hasControls, let w = video.recommendedWidth, w < current.width { steps.append("keep full size for fullscreen, or add a \(w) px inline derivative") }
            if video.findings.contains(where: { $0.kind == .audio && $0.text.contains("silent") }) { steps.append("drop the silent audio") }
            if video.bestSource?.localURL != nil, !video.originals.isEmpty { steps.append("encode from \(video.bestSource!.name)") }
        }
        if !delivery.isEmpty { steps.append("fix the delivery notes") }
        video.action = steps.joined(separator: "; ") + "."
    }
}

struct UnionFind {
    private var parent: [String: String] = [:]

    mutating func add(_ key: String) { if parent[key] == nil { parent[key] = key } }

    mutating func find(_ key: String) -> String {
        add(key)
        var root = key
        while let p = parent[root], p != root { root = p }
        var node = key
        while let p = parent[node], p != root { parent[node] = root; node = p }
        return root
    }

    mutating func union(_ a: String, _ b: String) {
        let ra = find(a), rb = find(b)
        if ra == rb { return }
        if ra.hasPrefix("stem:") || ra.hasPrefix("el:") { parent[ra] = rb } else { parent[rb] = ra }
    }
}
