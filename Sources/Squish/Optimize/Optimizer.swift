import Foundation

struct OptimizeOptions: Sendable {
    var audit: AuditOptions = { var o = AuditOptions(); o.maxPages = 10; return o }()
    var encode: EncodeSettings = { var s = EncodeSettings(); s.vp9 = true; s.speed = .skill; s.losslessAudio = false; return s }()
    var threshold: Double = 0.05
    var removeAudioWhenMutedWithoutControls = false
}

enum ChangeAction: String, Sendable {
    case replace = "Replace"
    case add = "Add"
    case backup = "Move to backup"
}

struct FileChange: Identifiable, Sendable {
    let id = UUID()
    let action: ChangeAction
    let target: URL
    let relPath: String
    let staged: URL?
    let before: Int64
    let after: Int64
}

struct FileEdit: Identifiable, Sendable {
    let id = UUID()
    let file: URL
    let relPath: String
    let original: String
    let updated: String
    var notes: [String]

    var changedLines: [(removed: Bool, text: String)] {
        let a = original.components(separatedBy: "\n"), b = updated.components(separatedBy: "\n")
        return b.difference(from: a).map { change in
            switch change {
            case .remove(_, let line, _): return (true, line)
            case .insert(_, let line, _): return (false, line)
            }
        }.sorted { $0.removed && !$1.removed }
    }
}

struct VideoPlan: Identifiable, Sendable {
    let id: String
    let name: String
    var source: VideoAsset?
    var targetWidth: Int?
    var audio: AudioDecision?
    var outputs: [EncodeOutput] = []
    var changes: [FileChange] = []
    var notes: [String] = []
    var skipped: String?
    var playbackBefore: Int64 = 0
    var playbackAfter: Int64 = 0
}

struct OptimizePlan: Sendable {
    let project: URL
    let report: AuditReport
    var videos: [VideoPlan]
    var edits: [FileEdit]
    let staging: URL

    var changes: [FileChange] { videos.flatMap(\.changes) }
    var storageBefore: Int64 { changes.filter { $0.action != .add }.reduce(0) { $0 + $1.before } }
    var storageAfter: Int64 { changes.filter { $0.action != .backup }.reduce(0) { $0 + $1.after } }
    var hasWork: Bool { !changes.isEmpty || !edits.isEmpty }
}

struct ApplyResult: Sendable {
    let backup: URL
    let changed: [String]
    let checks: [String]
    let problems: [String]
    let markdown: String
}

enum Optimizer {
    typealias Log = @Sendable (String) -> Void

    static func plan(_ options: OptimizeOptions, log: @escaping Log, progress: @escaping @Sendable (Double) -> Void) async throws -> OptimizePlan {
        guard let project = options.audit.project else { throw ToolError.message("Choose the website's source folder first.") }
        let codecs = options.encode.enabledCodecs
        guard !codecs.isEmpty else { throw ToolError.message("Choose at least one output format.") }
        let report = try await Auditor.run(options.audit, log: log)
        let staging = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Squish/staging/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        var plans: [VideoPlan] = []
        var textEdits: [String: [(NSRange, String)]] = [:]
        var editNotes: [String: [String]] = [:]
        var editFiles: [String: URL] = [:]
        let total = Double(max(report.videos.count, 1))

        for (n, video) in report.videos.enumerated() {
            try Task.checkCancellation()
            var plan = VideoPlan(id: video.id, name: video.name)
            let local = video.variants.filter { $0.localURL != nil && $0.probe != nil }
            guard !local.isEmpty else {
                plan.skipped = "Hosted outside the project; re-encode the original and upload it where it is hosted."
                plans.append(plan)
                continue
            }
            guard let source = video.bestSource, source.localURL != nil, let probe = source.probe else {
                plan.skipped = "No readable local source."
                plans.append(plan)
                continue
            }
            plan.source = source

            if let width = video.recommendedWidth, width < probe.width {
                if video.hasControls {
                    plan.notes.append("Kept \(probe.width) px: the player has controls, so fullscreen needs the full size.")
                } else {
                    plan.targetWidth = width
                }
            } else if video.recommendedWidth == nil {
                plan.notes.append("Display size unmeasured; kept the source resolution.")
            }

            var audio = try await decideAudio(source: source, probe: probe, settings: options.encode)
            if audio.keep, options.removeAudioWhenMutedWithoutControls, options.encode.audio == .auto, video.allMutedWithoutControls {
                audio = AudioDecision(keep: false, reason: "Removed: every usage is muted without controls (option enabled)", peak: audio.peak)
            }
            plan.audio = audio

            let mp4 = local.first { ["mp4", "m4v"].contains($0.ext) }
            let webm = local.first { $0.ext == "webm" && $0.probe?.videoCodec != "av1" }
            let mov = local.first { $0.ext == "mov" }
            guard let primary = mp4 ?? mov ?? webm, let primaryURL = primary.localURL else {
                plan.skipped = "Unsupported container (\(local.map(\.ext).joined(separator: ", "))); convert it manually."
                plans.append(plan)
                continue
            }
            let dir = primaryURL.deletingLastPathComponent()
            let stem = primaryURL.deletingPathExtension().lastPathComponent
            let work = staging.appendingPathComponent("\(n)-\(stem)", isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

            // Encode full outputs from the best source.
            let expected = Filters.outputSize(probe, maxWidth: plan.targetWidth)
            var outputs: [Codec: EncodeOutput] = [:]
            for (i, codec) in codecs.enumerated() {
                let name = codec == .av1 ? "\(stem)-av1.webm" : "\(stem).\(codec.fileExtension)"
                let out = work.appendingPathComponent(name)
                let crf = options.encode.crf(for: codec)
                log("Encoding \(video.name) → \(codec.shortLabel) CRF \(crf)…")
                let base = (Double(n) + Double(i) / Double(codecs.count)) / total
                let command = try await Encoder.encode(input: source.input, probe: probe, codec: codec, crf: crf, settings: options.encode, keepAudio: audio.keep, maxWidth: plan.targetWidth, output: out) { p in
                    progress(base + p / Double(codecs.count) / total)
                }
                log("Verifying \(name)…")
                let verification = try await Encoder.verify(output: out, codec: codec, expectedSize: expected, expectedFPS: Filters.targetFPS(probe, mode: options.encode.frameRate), pixFmt: options.encode.pixFmt(for: codec, source: probe), audio: audio.keep)
                let output = EncodeOutput(codec: codec, crf: crf, url: out, bytes: verification.probe.bytes, sourceBytes: probe.bytes, command: command, verification: verification)
                plan.outputs.append(output)
                if verification.passed { outputs[codec] = output } else { plan.notes.append("\(codec.shortLabel) failed verification (\(verification.issues.joined(separator: "; "))); not used.") }
            }

            // Decide which files to replace or add.
            let th = 1 - options.threshold
            let usages = video.usages.sorted { ($0.relPath, $0.range.location) < ($1.relPath, $1.range.location) }
            let blockers = usages.filter { !$0.rewritable }
            let rewritable = !usages.isEmpty && blockers.isEmpty
            let blockerText = blockers.prefix(3).map(\.location).joined(separator: ", ")
            let rel = { (url: URL) in url.relativePath(from: project) }
            let fm = FileManager.default
            var insertWebm: URL?
            var insertAV1: (URL, String)?
            var renameMov: URL?

            if let vp9 = outputs[.vp9] {
                if let webm, let url = webm.localURL {
                    if Double(vp9.bytes) < Double(webm.bytes) * th {
                        plan.changes.append(FileChange(action: .replace, target: url, relPath: rel(url), staged: vp9.url, before: webm.bytes, after: vp9.bytes))
                    } else {
                        plan.notes.append("Kept \(webm.name): the new VP9 (\(Fmt.bytes(vp9.bytes))) is not meaningfully smaller.")
                    }
                } else {
                    let target = dir.appendingPathComponent("\(stem).webm")
                    if fm.fileExists(atPath: target.path) {
                        plan.notes.append("Did not add \(target.lastPathComponent): a different file with that name already exists.")
                    } else if !rewritable {
                        plan.notes.append(usages.isEmpty ? "Did not add a WebM: no source reference to update." : "Did not add a WebM: \(blockerText) can't be rewritten automatically.")
                    } else if Double(vp9.bytes) < Double(primary.bytes) * th {
                        plan.changes.append(FileChange(action: .add, target: target, relPath: rel(target), staged: vp9.url, before: 0, after: vp9.bytes))
                        insertWebm = target
                    } else {
                        plan.notes.append("Did not add a WebM: VP9 (\(Fmt.bytes(vp9.bytes))) is not smaller than \(primary.name).")
                    }
                }
            }

            let webmEverywhere: ([SourceUsage]) -> Bool = { refs in
                refs.allSatisfy { usage in
                    guard usage.kind != .other, let element = usage.elementKey else { return false }
                    if insertWebm != nil { return true }
                    return usages.contains { $0.elementKey == element && $0.resolved == webm?.key }
                }
            }

            if let h265 = outputs[.h265] {
                if let mp4, let url = mp4.localURL {
                    let refs = usages.filter { $0.resolved == mp4.key }
                    if Double(h265.bytes) >= Double(mp4.bytes) * th {
                        plan.notes.append("Kept \(mp4.name): the new H.265 (\(Fmt.bytes(h265.bytes))) is not meaningfully smaller.")
                    } else if mp4.probe?.videoCodec == "hevc" || webmEverywhere(refs) {
                        plan.changes.append(FileChange(action: .replace, target: url, relPath: rel(url), staged: h265.url, before: mp4.bytes, after: h265.bytes))
                    } else {
                        plan.notes.append("Kept \(mp4.name) (\(mp4.probe?.videoCodec.uppercased() ?? "?")): an H.265-only MP4 needs a VP9 WebM fallback in every usage for browsers without HEVC.")
                    }
                } else if let mov, let url = mov.localURL {
                    let target = dir.appendingPathComponent("\(stem).mp4")
                    let refs = usages.filter { $0.resolved == mov.key }
                    if fm.fileExists(atPath: target.path) {
                        plan.notes.append("Did not convert \(mov.name): \(target.lastPathComponent) already exists.")
                    } else if !rewritable {
                        plan.notes.append("Did not convert \(mov.name): \(usages.isEmpty ? "no source reference" : blockerText) can't be updated automatically.")
                    } else if Double(h265.bytes) >= Double(mov.bytes) * th {
                        plan.notes.append("Kept \(mov.name): H.265 is not meaningfully smaller.")
                    } else if !webmEverywhere(refs) {
                        plan.notes.append("Did not convert \(mov.name): no VP9 WebM fallback could be added for browsers without HEVC.")
                    } else {
                        plan.changes.append(FileChange(action: .add, target: target, relPath: rel(target), staged: h265.url, before: 0, after: h265.bytes))
                        plan.changes.append(FileChange(action: .backup, target: url, relPath: rel(url), staged: nil, before: mov.bytes, after: 0))
                        renameMov = target
                    }
                } else {
                    plan.notes.append("No MP4 to replace; the WebM is already the only source.")
                }
            }

            if let av1 = outputs[.av1] {
                let target = dir.appendingPathComponent("\(stem)-av1.webm")
                if rewritable, !fm.fileExists(atPath: target.path), Double(av1.bytes) < Double(primary.bytes) * th {
                    plan.changes.append(FileChange(action: .add, target: target, relPath: rel(target), staged: av1.url, before: 0, after: av1.bytes))
                    insertAV1 = (target, Encoder.av1CodecString(av1.verification.probe, audio: audio.keep))
                } else {
                    plan.notes.append("Did not add AV1: \(rewritable ? "not smaller, or the name is taken" : "references can't be rewritten automatically").")
                }
            }

            // Rewrite references in markup.
            if insertWebm != nil || insertAV1 != nil || renameMov != nil {
                var handledElements = Set<String>()
                for usage in usages {
                    guard let resolvedURL = local.first(where: { $0.key == usage.resolved })?.localURL,
                          resolvedURL.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL else {
                        plan.notes.append("Reference at \(usage.location) points to another folder; left unchanged.")
                        continue
                    }
                    let content = (try? String(contentsOf: usage.file, encoding: .utf8)) ?? ""
                    let text = content as NSString
                    var edits: [(NSRange, String)] = []
                    let isMov = renameMov != nil && usage.resolved == mov?.key
                    let movRef = renameMov.map { sibling(usage.reference, $0.lastPathComponent) }
                    let element = usage.elementKey ?? usage.location
                    var newTags: [String] = []
                    if !handledElements.contains(element) {
                        handledElements.insert(element)
                        if let (url, codecs) = insertAV1 { newTags.append("<source src=\"\(sibling(usage.reference, url.lastPathComponent))\" type='video/webm; codecs=\"\(codecs)\"' />") }
                        let hasWebm = usages.contains { $0.elementKey == usage.elementKey && $0.resolved == webm?.key && usage.elementKey != nil }
                        if let url = insertWebm, !hasWebm { newTags.append("<source src=\"\(sibling(usage.reference, url.lastPathComponent))\" type=\"video/webm\" />") }
                    }
                    switch usage.kind {
                    case .sourceTag:
                        guard let tag = usage.sourceTag else { continue }
                        if isMov, let movRef {
                            edits.append((usage.range, movRef))
                            let tagText = text.substring(with: tag) as NSString
                            let type = tagText.range(of: "video/quicktime", options: .caseInsensitive)
                            if type.location != NSNotFound { edits.append((NSRange(location: tag.location + type.location, length: type.length), "video/mp4")) }
                        }
                        if !newTags.isEmpty {
                            let indent = indentation(text, at: tag.location)
                            edits.append((NSRange(location: tag.location, length: 0), newTags.map { $0 + "\n" + indent }.joined()))
                        }
                    case .videoSrc:
                        guard let tag = usage.videoTag, let attribute = srcAttributeRange(text, literal: usage.range) else { continue }
                        let ref = isMov ? (movRef ?? usage.reference) : usage.reference
                        let ext = (ref as NSString).pathExtension.lowercased()
                        newTags.append("<source src=\"\(ref)\" type=\"\(ext == "webm" ? "video/webm" : "video/mp4")\" />")
                        if newTags.count == 1 && !isMov { continue }
                        let indent = indentation(text, at: tag.location)
                        let children = newTags.map { "\n" + indent + "  " + $0 }.joined()
                        edits.append((attribute, ""))
                        let tagText = text.substring(with: tag)
                        if tagText.hasSuffix("/>") {
                            var start = NSMaxRange(tag) - 2
                            while start > tag.location, [32, 9, 10].contains(text.character(at: start - 1)) { start -= 1 }
                            edits.append((NSRange(location: start, length: NSMaxRange(tag) - start), ">" + children + "\n" + indent + "</video>"))
                        } else {
                            edits.append((NSRange(location: NSMaxRange(tag), length: 0), children + "\n" + indent))
                        }
                    case .other:
                        continue
                    }
                    if !edits.isEmpty {
                        textEdits[usage.relPath, default: []] += edits
                        editFiles[usage.relPath] = usage.file
                        editNotes[usage.relPath, default: []].append("\(video.name) at line \(usage.line)")
                    }
                }
            }

            let first = insertAV1.map { _ in outputs[.av1]!.bytes } ?? (insertWebm != nil || webm != nil ? (plan.changes.first { $0.staged == outputs[.vp9]?.url }?.after ?? webm?.bytes ?? 0) : 0)
            plan.playbackBefore = webm?.bytes ?? primary.bytes
            plan.playbackAfter = first > 0 ? first : (plan.changes.first { $0.action == .replace }?.after ?? primary.bytes)
            if plan.changes.isEmpty && plan.skipped == nil { plan.skipped = "No worthwhile improvement; current assets kept." }
            plans.append(plan)
            progress(Double(n + 1) / total)
        }

        var edits: [FileEdit] = []
        for (relPath, list) in textEdits.sorted(by: { $0.key < $1.key }) {
            guard let file = editFiles[relPath], let original = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let sorted = list.sorted { $0.0.location != $1.0.location ? $0.0.location > $1.0.location : $0.0.length > $1.0.length }
            let mutable = NSMutableString(string: original)
            var lastStart = Int.max
            for (range, replacement) in sorted where NSMaxRange(range) <= lastStart {
                mutable.replaceCharacters(in: range, with: replacement)
                lastStart = range.location
            }
            edits.append(FileEdit(file: file, relPath: relPath, original: original, updated: mutable as String, notes: editNotes[relPath] ?? []))
        }
        log("Plan ready: \(plans.flatMap(\.changes).count) file changes and \(edits.count) source edits.")
        return OptimizePlan(project: project, report: report, videos: plans, edits: edits, staging: staging)
    }

    static func decideAudio(source: VideoAsset, probe: ProbeInfo, settings: EncodeSettings) async throws -> AudioDecision {
        if settings.audio == .auto, let peak = source.peak {
            return peak <= -50
                ? AudioDecision(keep: false, reason: "Silent audio (peak \(Fmt.dB(peak))) removed", peak: peak)
                : AudioDecision(keep: true, reason: "Audible audio (peak \(Fmt.dB(peak))) kept", peak: peak)
        }
        return try await Encoder.decideAudio(input: source.input, probe: probe, mode: settings.audio)
    }

    static func sibling(_ reference: String, _ name: String) -> String {
        var ref = reference
        if let cut = ref.firstIndex(where: { $0 == "?" || $0 == "#" }) { ref = String(ref[..<cut]) }
        guard let slash = ref.lastIndex(of: "/") else { return name }
        return String(ref[...slash]) + name
    }

    static func indentation(_ text: NSString, at location: Int) -> String {
        var start = location
        while start > 0, text.character(at: start - 1) != 10 { start -= 1 }
        let prefix = text.substring(with: NSRange(location: start, length: location - start))
        return String(prefix.prefix { $0 == " " || $0 == "\t" })
    }

    /// Range of ` src="…"` (including leading whitespace and JSX braces) around a literal.
    static func srcAttributeRange(_ text: NSString, literal: NSRange) -> NSRange? {
        let windowStart = max(0, literal.location - 24)
        let before = text.substring(with: NSRange(location: windowStart, length: literal.location - windowStart)) as NSString
        let match = before.range(of: "\\s+src\\s*=\\s*\\{?\\s*[\"']$", options: [.regularExpression, .caseInsensitive])
        guard match.location != NSNotFound else { return nil }
        let start = windowStart + match.location
        var end = NSMaxRange(literal) + 1
        if before.substring(with: match).contains("{") {
            while end < text.length, text.character(at: end) == 32 { end += 1 }
            if end < text.length, text.character(at: end) == 125 { end += 1 }
        }
        return NSRange(location: start, length: end - start)
    }

    static func apply(_ plan: OptimizePlan, log: @escaping Log) async throws -> ApplyResult {
        let fm = FileManager.default
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: "")
        let backup = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Squish/Backups/\(plan.project.lastPathComponent)-\(stamp)", isDirectory: true)
        let saved = backup.appendingPathComponent("files", isDirectory: true)
        try fm.createDirectory(at: saved, withIntermediateDirectories: true)
        var created: [String] = []
        var preserved: [String] = []
        var problems: [String] = []
        var changed: [String] = []

        func preserve(_ url: URL, _ rel: String, move: Bool = false) throws {
            let destination = saved.appendingPathComponent(rel)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if move { try fm.moveItem(at: url, to: destination) } else { try fm.copyItem(at: url, to: destination) }
            preserved.append(rel)
        }

        for edit in plan.edits {
            let current = try? String(contentsOf: edit.file, encoding: .utf8)
            if current != edit.original { problems.append("\(edit.relPath) changed since the plan was built; skipped its edits.") }
        }
        let stale = Set(problems.compactMap { $0.components(separatedBy: " changed since").first })

        for change in plan.changes {
            do {
                switch change.action {
                case .replace:
                    try preserve(change.target, change.relPath)
                    try fm.removeItem(at: change.target)
                    try fm.copyItem(at: change.staged!, to: change.target)
                case .add:
                    guard !fm.fileExists(atPath: change.target.path) else { problems.append("\(change.relPath) appeared after planning; not overwritten."); continue }
                    try fm.copyItem(at: change.staged!, to: change.target)
                    created.append(change.relPath)
                case .backup:
                    try preserve(change.target, change.relPath, move: true)
                }
                changed.append("\(change.action.rawValue): \(change.relPath)")
                log("\(change.action.rawValue) \(change.relPath)")
            } catch {
                problems.append("\(change.relPath): \(error.localizedDescription)")
            }
        }
        for edit in plan.edits where !stale.contains(edit.relPath) {
            do {
                try preserve(edit.file, edit.relPath)
                try edit.updated.write(to: edit.file, atomically: true, encoding: .utf8)
                changed.append("Edit: \(edit.relPath)")
                log("Updated \(edit.relPath)")
            } catch {
                problems.append("\(edit.relPath): \(error.localizedDescription)")
            }
        }
        let manifest: [String: Any] = ["project": plan.project.path, "created": created, "preserved": preserved, "date": stamp]
        try JSONSerialization.data(withJSONObject: manifest, options: .prettyPrinted).write(to: backup.appendingPathComponent("manifest.json"))

        // Verify.
        var checks: [String] = []
        for change in plan.changes where change.action != .backup && fm.fileExists(atPath: change.target.path) {
            if let probe = try? await Probe.run(change.target.path) { checks.append("\(change.relPath): \(probe.videoCodec), \(probe.dimensions), \(Fmt.bytes(probe.bytes))") }
            else { problems.append("\(change.relPath) could not be read after writing.") }
        }
        log("Re-scanning references…")
        let rescan = try await Task.detached { try SourceScanner.scan(root: plan.project) }.value
        let beforeUnresolved = Set(plan.report.scan?.usages.filter { $0.resolved == nil && !$0.isRemote }.map(\.reference) ?? [])
        let newlyBroken = rescan.usages.filter { $0.resolved == nil && !$0.isRemote && !beforeUnresolved.contains($0.reference) }
        if newlyBroken.isEmpty { checks.append("Every video reference in the project resolves to a file.") }
        for usage in newlyBroken { problems.append("Broken reference \(usage.reference) at \(usage.location).") }

        let start = plan.report.options.startURL.trimmingCharacters(in: .whitespaces)
        if let url = URL(string: start), url.scheme?.hasPrefix("http") == true {
            log("Re-rendering pages to check playback…")
            let renderer = await PageRenderer()
            for page in plan.report.pages.compactMap(URL.init(string:)) {
                do {
                    let snapshot = try await renderer.render(page, viewport: Viewport.defaults[2])
                    let failing = snapshot.videos.filter { $0.error != 0 }
                    if failing.isEmpty { checks.append("\(page.path.isEmpty ? "/" : page.path): \(snapshot.videos.count) video(s) load without media errors (WebKit).") }
                    for video in failing { problems.append("\(page.path): media error \(video.error) for \(video.currentSrc).") }
                } catch {
                    problems.append("Could not re-render \(page.absoluteString): \(error.localizedDescription)")
                }
            }
            await renderer.close()
            checks.append("If your dev server serves a build output rather than the source folder, rebuild before checking the pages.")
        }
        let result = markdown(plan, changed: changed, checks: checks, problems: problems, backup: backup)
        try? result.write(to: backup.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
        return ApplyResult(backup: backup, changed: changed, checks: checks, problems: problems, markdown: result)
    }

    static func restore(_ backup: URL) throws -> [String] {
        let fm = FileManager.default
        let data = try Data(contentsOf: backup.appendingPathComponent("manifest.json"))
        guard let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any], let projectPath = manifest["project"] as? String else {
            throw ToolError.message("The backup manifest is unreadable.")
        }
        let project = URL(fileURLWithPath: projectPath, isDirectory: true)
        var log: [String] = []
        for rel in manifest["created"] as? [String] ?? [] {
            try? fm.removeItem(at: project.appendingPathComponent(rel))
            log.append("Removed \(rel)")
        }
        for rel in manifest["preserved"] as? [String] ?? [] {
            let target = project.appendingPathComponent(rel)
            try? fm.removeItem(at: target)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: backup.appendingPathComponent("files").appendingPathComponent(rel), to: target)
            log.append("Restored \(rel)")
        }
        return log
    }

    static func markdown(_ plan: OptimizePlan, changed: [String], checks: [String], problems: [String], backup: URL) -> String {
        var out = ["# Scan and optimize report", "", "Project: `\(plan.project.path)`  ", "Backup: `\(backup.path)`", ""]
        out.append("## Videos")
        out.append("| Video | Source | Before | After | Dimensions | Result |")
        out.append("| --- | --- | ---: | ---: | --- | --- |")
        for v in plan.videos {
            let before = v.changes.filter { $0.action != .add }.reduce(0) { $0 + $1.before }
            let after = v.changes.filter { $0.action != .backup }.reduce(0) { $0 + $1.after }
            let dims = v.outputs.first.map { "\(v.source?.probe?.dimensions ?? "?") → \($0.verification.probe.dimensions)" } ?? (v.source?.probe?.dimensions ?? "–")
            let result = v.skipped ?? v.changes.map { "\($0.action.rawValue) \($0.relPath)" }.joined(separator: "<br>")
            out.append("| \(v.name) | \(v.source?.name ?? "–") | \(before > 0 ? Fmt.bytes(before) : "–") | \(after > 0 ? Fmt.bytes(after) : "–") | \(dims) | \(result) |")
        }
        out.append("")
        out.append("Storage: \(Fmt.bytes(plan.storageBefore)) of replaced files became \(Fmt.bytes(plan.storageAfter)) (shared assets counted once). Browsers fetch only one <source> per playback, so added fallback formats raise storage but not per-visit transfer.")
        out.append("")
        out.append("## Changed files")
        out += changed.map { "- \($0)" }
        let notes = plan.videos.flatMap { v in v.notes.map { "- \(v.name): \($0)" } }
        if !notes.isEmpty { out += ["", "## Notes and skipped assets"] + notes }
        out += ["", "## Settings and commands"]
        for v in plan.videos {
            if let audio = v.audio { out.append("- \(v.name): \(audio.reason)") }
            for o in v.outputs { out.append("  - `\(o.command)`") }
        }
        out += ["", "## Verification"] + checks.map { "- \($0)" }
        if !problems.isEmpty { out += ["", "## Problems"] + problems.map { "- \($0)" } }
        out += ["", "## Coverage"] + (plan.report.pages.isEmpty ? ["- No pages rendered."] : plan.report.pages.map { "- \($0)" }) + plan.report.gaps.map { "- Gap: \($0)" }
        out += ["", "CMS uploads, CDN storage, and deployment are not covered; publish the changed files through your usual pipeline."]
        return out.joined(separator: "\n")
    }
}
