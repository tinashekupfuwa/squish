import Foundation

struct ElementInfo: Hashable, Sendable {
    var autoplay = false
    var muted = false
    var loop = false
    var controls = false
    var playsinline = false
    var poster = false
    var preload: String?
    var widthAttribute: Int?
}

enum UsageKind: String, Sendable {
    case videoSrc = "<video src>"
    case sourceTag = "<source src>"
    case other = "reference"
}

struct SourceUsage: Identifiable, Hashable, Sendable {
    let id = UUID()
    let file: URL
    let relPath: String
    let line: Int
    let reference: String
    let range: NSRange
    let kind: UsageKind
    let videoTag: NSRange?
    let sourceTag: NSRange?
    let element: ElementInfo?
    var resolved: String?

    var isRemote: Bool { reference.hasPrefix("http://") || reference.hasPrefix("https://") || reference.hasPrefix("//") }
    var rewritable: Bool { kind != .other && SourceScanner.markupExtensions.contains(file.pathExtension.lowercased()) }
    var elementKey: String? { videoTag.map { "\(relPath)#\($0.location)" } }
    var location: String { "\(relPath):\(line)" }
}

struct ProjectScan: Sendable {
    let root: URL
    let videoFiles: [URL]
    let usages: [SourceUsage]
    let scannedFiles: Int
}

enum SourceScanner {
    static let videoExtensions: Set<String> = ["mp4", "webm", "mov", "m4v", "ogv", "mkv"]
    static let sourceExtensions: Set<String> = ["html", "htm", "jsx", "tsx", "js", "ts", "mjs", "cjs", "vue", "svelte", "astro", "md", "mdx", "css", "scss", "sass", "less", "json", "yml", "yaml", "toml", "liquid", "njk", "hbs", "handlebars", "erb", "php", "twig", "pug", "ejs"]
    static let markupExtensions: Set<String> = ["html", "htm", "jsx", "tsx", "js", "ts", "vue", "svelte", "astro", "mdx", "liquid", "njk", "hbs", "handlebars", "erb", "php", "twig", "ejs"]
    static let skippedDirectories: Set<String> = ["node_modules", ".git", ".next", ".nuxt", ".svelte-kit", ".astro", ".vercel", ".netlify", ".turbo", ".cache", "dist", "build", "out", "coverage", "vendor", "Pods", "DerivedData", ".output", ".parcel-cache", ".idea", ".vscode", ".squish-backup"]
    static let ignoredFiles: Set<String> = ["package-lock.json", "yarn.lock", "pnpm-lock.yaml", "bun.lockb", "composer.lock"]
    static let publicRoots = ["", "public", "static", "src", "assets", "app", "www", "web", "src/assets", "public/assets"]

    static func videos(in folder: URL) -> [URL] { walk(folder).videos }

    static func walk(_ root: URL) -> (videos: [URL], sources: [URL]) {
        var videos: [URL] = []
        var sources: [URL] = []
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey]) else { return ([], []) }
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            let name = url.lastPathComponent
            if values?.isDirectory == true {
                if skippedDirectories.contains(name) { enumerator.skipDescendants() }
                continue
            }
            let ext = url.pathExtension.lowercased()
            if videoExtensions.contains(ext) {
                videos.append(url)
            } else if sourceExtensions.contains(ext), !ignoredFiles.contains(name), !name.contains(".min."), (values?.fileSize ?? 0) < 2_000_000 {
                sources.append(url)
            }
        }
        return (videos, sources)
    }

    static func scan(root: URL) throws -> ProjectScan {
        let (videos, sources) = walk(root)
        let index = VideoIndex(root: root, videos: videos)
        let regex = try NSRegularExpression(pattern: "[A-Za-z0-9_./@%~+:\\-]*[A-Za-z0-9_%\\-]\\.(?:mp4|webm|mov|m4v|ogv|mkv)(?![A-Za-z0-9])", options: [.caseInsensitive])
        var usages: [SourceUsage] = []
        for file in sources {
            guard let content = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let text = content as NSString
            let matches = regex.matches(in: content, range: NSRange(location: 0, length: text.length))
            guard !matches.isEmpty else { continue }
            let lineStarts = lineStartOffsets(text)
            let relPath = file.relativePath(from: root)
            for match in matches {
                let reference = text.substring(with: match.range)
                guard reference.contains(".") else { continue }
                let (kind, videoTag, sourceTag) = classify(text, literal: match.range)
                let element = videoTag.map { attributes(text.substring(with: $0)) }
                var usage = SourceUsage(file: file, relPath: relPath, line: line(of: match.range.location, in: lineStarts), reference: reference, range: match.range, kind: kind, videoTag: videoTag, sourceTag: sourceTag, element: element)
                usage.resolved = index.resolve(reference, from: file)
                usages.append(usage)
            }
        }
        return ProjectScan(root: root, videoFiles: videos, usages: usages, scannedFiles: sources.count)
    }

    static func lineStartOffsets(_ text: NSString) -> [Int] {
        var starts = [0]
        for i in 0..<text.length where text.character(at: i) == 10 { starts.append(i + 1) }
        return starts
    }

    static func line(of offset: Int, in starts: [Int]) -> Int {
        var lo = 0, hi = starts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo + 1
    }

    /// Index of the closing '>' of the tag opening at `start`, skipping quoted strings and JSX braces.
    static func tagEnd(_ text: NSString, from start: Int) -> Int? {
        var quote: unichar = 0
        var depth = 0
        var i = start + 1
        let limit = min(text.length, start + 6000)
        while i < limit {
            let c = text.character(at: i)
            if quote != 0 {
                if c == quote { quote = 0 }
            } else if c == 34 || c == 39 || c == 96 {
                quote = c
            } else if c == 123 {
                depth += 1
            } else if c == 125 {
                depth = max(0, depth - 1)
            } else if c == 62 && depth == 0 {
                return i
            }
            i += 1
        }
        return nil
    }

    private static func openTag(_ text: NSString, name: String, before location: Int, window: Int = 6000) -> NSRange? {
        var searchEnd = location
        let floor = max(0, location - window)
        while searchEnd > floor {
            let found = text.range(of: "<" + name, options: [.backwards, .caseInsensitive], range: NSRange(location: floor, length: searchEnd - floor))
            guard found.location != NSNotFound else { return nil }
            let next = found.location + found.length
            if next < text.length {
                let c = text.character(at: next)
                if c == 32 || c == 9 || c == 10 || c == 13 || c == 62 || c == 47 {
                    if let end = tagEnd(text, from: found.location) { return NSRange(location: found.location, length: end - found.location + 1) }
                    return nil
                }
            }
            searchEnd = found.location
        }
        return nil
    }

    private static func isSrcAttribute(_ text: NSString, literal: NSRange) -> Bool {
        let start = max(0, literal.location - 16)
        let before = text.substring(with: NSRange(location: start, length: literal.location - start))
        guard before.range(of: "\\bsrc\\s*=\\s*\\{?\\s*[\"']$", options: [.regularExpression, .caseInsensitive]) != nil else { return false }
        let after = literal.location + literal.length
        guard after < text.length else { return false }
        let quote = before.last.map { String($0) } ?? ""
        return text.substring(with: NSRange(location: after, length: 1)) == quote
    }

    static func classify(_ text: NSString, literal: NSRange) -> (UsageKind, NSRange?, NSRange?) {
        if let source = openTag(text, name: "source", before: literal.location), NSMaxRange(source) > NSMaxRange(literal) {
            let video = enclosingVideo(text, before: source.location)
            return (isSrcAttribute(text, literal: literal) && video != nil ? .sourceTag : .other, video, source)
        }
        if let video = openTag(text, name: "video", before: literal.location), NSMaxRange(video) > NSMaxRange(literal) {
            return (isSrcAttribute(text, literal: literal) ? .videoSrc : .other, video, nil)
        }
        return (.other, nil, nil)
    }

    private static func enclosingVideo(_ text: NSString, before location: Int) -> NSRange? {
        guard let video = openTag(text, name: "video", before: location), NSMaxRange(video) <= location else { return nil }
        let between = NSRange(location: NSMaxRange(video), length: location - NSMaxRange(video))
        if text.range(of: "</video", options: .caseInsensitive, range: between).location != NSNotFound { return nil }
        if text.substring(with: video).hasSuffix("/>") { return nil }
        return video
    }

    static func attributes(_ tag: String) -> ElementInfo {
        func flag(_ name: String) -> Bool {
            tag.range(of: "(?i)\\b\(name)\\b(?!\\s*=\\s*\\{\\s*false\\s*\\})", options: .regularExpression) != nil
        }
        func value(_ pattern: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = regex.firstMatch(in: tag, range: NSRange(location: 0, length: (tag as NSString).length)) else { return nil }
            return (tag as NSString).substring(with: match.range(at: 1))
        }
        var info = ElementInfo()
        info.autoplay = flag("autoplay")
        info.muted = flag("muted")
        info.loop = flag("loop")
        info.controls = flag("controls")
        info.playsinline = flag("playsinline")
        info.poster = tag.range(of: "(?i)\\bposter\\s*=", options: .regularExpression) != nil
        info.preload = value("\\bpreload\\s*=\\s*\\{?\\s*[\"']?([a-z]+)")?.lowercased()
        info.widthAttribute = value("\\bwidth\\s*=\\s*\\{?\\s*[\"']?(\\d+)").flatMap { Int($0) }
        return info
    }
}

struct VideoIndex {
    let root: URL
    let byPath: [String: String]
    let byName: [String: [String]]

    init(root: URL, videos: [URL]) {
        self.root = root
        var byPath: [String: String] = [:]
        var byName: [String: [String]] = [:]
        for video in videos {
            let rel = video.relativePath(from: root)
            byPath[video.standardizedFileURL.path.lowercased()] = rel
            byName[video.lastPathComponent.lowercased(), default: []].append(rel)
        }
        self.byPath = byPath
        self.byName = byName
    }

    func resolve(_ reference: String, from file: URL) -> String? {
        var ref = reference
        if let cut = ref.firstIndex(where: { $0 == "?" || $0 == "#" }) { ref = String(ref[..<cut]) }
        if ref.hasPrefix("http://") || ref.hasPrefix("https://") || ref.hasPrefix("//") {
            let path = URL(string: ref.hasPrefix("//") ? "https:" + ref : ref)?.path ?? ""
            return suffixMatch(path)
        }
        ref = ref.removingPercentEncoding ?? ref
        var candidates: [URL] = []
        if ref.hasPrefix("@/") || ref.hasPrefix("~/") {
            candidates.append(root.appendingPathComponent("src").appendingPathComponent(String(ref.dropFirst(2))))
        } else if ref.hasPrefix("/") {
            candidates += SourceScanner.publicRoots.map { root.appendingPathComponent($0).appendingPathComponent(String(ref.dropFirst())) }
        } else {
            candidates.append(file.deletingLastPathComponent().appendingPathComponent(ref))
            candidates += SourceScanner.publicRoots.map { root.appendingPathComponent($0).appendingPathComponent(ref) }
        }
        for candidate in candidates {
            if let rel = byPath[candidate.standardizedFileURL.path.lowercased()] { return rel }
        }
        return suffixMatch(ref)
    }

    func suffixMatch(_ path: String) -> String? {
        let parts = path.lowercased().split(separator: "/").map(String.init)
        guard let name = parts.last, let options = byName[name] else { return nil }
        if options.count == 1 { return options[0] }
        return options.max { score($0, parts) < score($1, parts) }
    }

    private func score(_ rel: String, _ parts: [String]) -> Int {
        let relParts = rel.lowercased().split(separator: "/").map(String.init)
        var n = 0
        while n < min(relParts.count, parts.count), relParts[relParts.count - 1 - n] == parts[parts.count - 1 - n] { n += 1 }
        return n
    }
}
