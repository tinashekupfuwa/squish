import Foundation
import Observation

enum JobState: Sendable { case queued, running, done, failed, cancelled }

@Observable @MainActor
final class CompressJob: Identifiable {
    let id = UUID()
    let url: URL
    var probe: ProbeInfo?
    var state: JobState = .queued
    var status = "Queued"
    var progress: Double = 0
    /// Live encode speed as a multiple of real time, from ffmpeg's progress stream.
    var speed: Double?
    var audioNote: String?
    var notes: [String] = []
    var outputs: [EncodeOutput] = []
    var error: String?
    var html: String?

    /// Size on disk, read when the video is added so it is known before probing finishes.
    let fileBytes: Int64

    init(url: URL) {
        self.url = url
        fileBytes = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    var bytes: Int64 { probe?.bytes ?? fileBytes }
}

@Observable @MainActor
final class CompressModel {
    var jobs: [CompressJob] = []
    var settings = EncodeSettings() {
        didSet { Persistence.save(settings, key: "lastSettings") }
    }
    var userPresets: [EncodePreset] = [] {
        didSet { Persistence.save(userPresets, key: "userPresets") }
    }
    var isRunning = false
    var isPaused = false
    var isStopping = false
    /// 0 (smallest files) to 100 (best quality); 50 is the skill's defaults.
    var quality = 50 {
        didSet { UserDefaults.standard.set(quality, forKey: "lastQuality") }
    }

    init() {
        if let saved = Persistence.load(EncodeSettings.self, key: "lastSettings") { settings = saved }
        if !UserDefaults.standard.bool(forKey: "tenBitDefaultApplied") {
            settings.tenBit = true
            Persistence.save(settings, key: "lastSettings")
            UserDefaults.standard.set(true, forKey: "tenBitDefaultApplied")
        }
        if UserDefaults.standard.object(forKey: "lastQuality") != nil { quality = UserDefaults.standard.integer(forKey: "lastQuality") }
        if !UserDefaults.standard.bool(forKey: "h265DefaultsApplied") {
            settings.vp9 = false
            settings.h265 = true
            settings.av1 = false
            settings.speed = .faster
            settings.tenBit = true
            quality = 50
            Persistence.save(settings, key: "lastSettings")
            UserDefaults.standard.set(true, forKey: "h265DefaultsApplied")
        }
        userPresets = Persistence.load([EncodePreset].self, key: "userPresets") ?? []
    }

    var allPresets: [EncodePreset] { EncodePreset.builtIns + userPresets }

    /// The preset whose settings match the current ones exactly, or nil when they've been customised.
    var activePreset: EncodePreset? { allPresets.first { $0.settings == settings && $0.quality == quality } }

    func apply(_ preset: EncodePreset) {
        quality = preset.quality
        settings = preset.settings
    }

    func savePreset(named rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let preset = EncodePreset(id: UUID(), name: name, detail: presetSummary, settings: settings, quality: quality)
        if let index = userPresets.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            userPresets[index] = EncodePreset(id: userPresets[index].id, name: name, detail: presetSummary, settings: settings, quality: quality)
        } else {
            userPresets.append(preset)
        }
    }

    func deletePreset(_ preset: EncodePreset) { userPresets.removeAll { $0.id == preset.id } }

    var presetSummary: String {
        var parts = ["Compression \(100 - quality)"]
        parts.append(settings.enabledCodecs.map(\.shortLabel).joined(separator: " + "))
        if let width = settings.maxWidth { parts.append("\(width) px max") }
        if settings.audio == .remove { parts.append("no audio") }
        else if settings.losslessAudio { parts.append("lossless audio") }
        if settings.frameRate == .cap { parts.append("30 fps") }
        return parts.joined(separator: ", ")
    }

    nonisolated static func crf(for codec: Codec, quality: Int) -> Int {
        let q = Double(min(max(quality, 0), 100))
        switch codec {
        case .h265: return Int((38 - q * 0.16).rounded())
        case .vp9, .av1: return Int((52 - q * 0.2).rounded())
        }
    }

    static func qualityName(_ quality: Int) -> String {
        quality < 35 ? "Smaller files" : quality <= 65 ? "Balanced" : "Better quality"
    }

    /// The ruler is the only thing that should rewrite a hand-set CRF. Restoring quality on launch must not.
    func setQuality(_ value: Int) {
        quality = value
        applyQuality()
    }

    private func applyQuality() {
        for codec in Codec.allCases { settings.crf[codec] = Self.crf(for: codec, quality: quality) }
    }

    var currentJob: CompressJob? { jobs.first { $0.state == .running } }
    var doneJobs: [CompressJob] { jobs.filter { $0.state == .done } }
    var savedBytes: Int64 {
        doneJobs.reduce(0) { total, job in
            guard let smallest = job.outputs.map(\.bytes).min(), let source = job.outputs.first?.sourceBytes else { return total }
            return total + max(0, source - smallest)
        }
    }
    var savedRatio: Double {
        let source = doneJobs.compactMap { $0.outputs.first?.sourceBytes }.reduce(0, +)
        return source > 0 ? Double(savedBytes) / Double(source) : 0
    }
    private let control = ProcessGroup()
    private var task: Task<Void, Never>?

    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "webm", "mkv", "avi", "ogv", "mpg", "mpeg", "mts", "m2ts", "wmv", "flv", "3gp", "gif"]

    func add(_ urls: [URL]) {
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let items = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
                add(items.filter { Self.videoExtensions.contains($0.pathExtension.lowercased()) })
            } else if Self.videoExtensions.contains(url.pathExtension.lowercased()), !jobs.contains(where: { $0.url == url }) {
                let job = CompressJob(url: url)
                jobs.append(job)
                Task { job.probe = try? await Probe.run(url.path) }
            }
        }
    }

    func remove(_ job: CompressJob) {
        guard job.state != .running else { return }
        jobs.removeAll { $0.id == job.id }
    }

    func clearFinished() { jobs.removeAll { $0.state == .done } }

    var pending: [CompressJob] { jobs.filter { $0.state != .done && $0.state != .running } }

    /// Videos above this size switch the overall meter to fine ticks weighted by size, so a long encode visibly moves.
    static let largeVideoBytes: Int64 = 20_000_000_000

    var hasLargeVideo: Bool { jobs.contains { $0.bytes > Self.largeVideoBytes } }

    /// Overall progress for the big meter: by size when a large video is queued, otherwise per video.
    var displayProgress: Double {
        guard hasLargeVideo else { return overallProgress }
        let active = jobs.filter { $0.state != .failed && $0.state != .cancelled }
        let total = active.reduce(0.0) { $0 + Double($1.bytes) }
        guard total > 0 else { return overallProgress }
        return active.reduce(0.0) { $0 + Double($1.bytes) * ($1.state == .done ? 1 : $1.progress) } / total
    }

    /// Progress across the jobs that are queued, running, or finished.
    var overallProgress: Double {
        let active = jobs.filter { $0.state != .failed && $0.state != .cancelled }
        guard !active.isEmpty else { return 0 }
        return active.reduce(0) { $0 + ($1.state == .done ? 1 : $1.progress) } / Double(active.count)
    }

    func start() {
        guard !isRunning, !pending.isEmpty else { return }
        for job in pending { job.state = .queued; job.status = "Queued"; job.progress = 0 }
        isRunning = true
        isPaused = false
        let settings = settings
        let control = control
        task = Task {
            await ProcessGroup.$current.withValue(control) {
                while !Task.isCancelled, let job = jobs.first(where: { $0.state == .queued }) {
                    try? await control.waitWhilePaused()
                    if Task.isCancelled { break }
                    await process(job, settings)
                }
            }
            isRunning = false
            isPaused = false
            isStopping = false
        }
    }

    func pause() {
        guard isRunning, !isPaused else { return }
        control.pause()
        isPaused = true
    }

    func resume() {
        guard isPaused else { return }
        control.resume()
        isPaused = false
    }

    func stop() {
        guard isRunning, !isStopping else { return }
        isStopping = true
        currentJob?.status = "Stopping…"
        task?.cancel()
        control.resume()
        isPaused = false
    }

    private func process(_ job: CompressJob, _ s: EncodeSettings) async {
        job.state = .running
        job.outputs = []
        job.notes = []
        job.error = nil
        job.html = nil
        job.progress = 0
        job.speed = nil
        defer { job.speed = nil }
        do {
            let codecs = s.enabledCodecs
            guard !codecs.isEmpty else { throw ToolError.message("Choose at least one output format.") }
            job.status = "Inspecting…"
            let probe = try await Probe.run(job.url.path)
            job.probe = probe
            job.status = "Analyzing audio…"
            let audio = try await Encoder.decideAudio(input: job.url.path, probe: probe, mode: s.audio)
            job.audioNote = audio.reason
            if probe.bitDepth > 10 { job.notes.append("Color saved at 10-bit, the most web players support (source is \(probe.bitDepth)-bit)") }
            else if probe.bitDepth > 8 && !s.tenBit { job.notes.append("Color reduced from \(probe.bitDepth)-bit to 8-bit. Turn on Smooth gradients to keep it") }
            if probe.pixFmt.contains("422") || probe.pixFmt.contains("444") {
                let kept = s.pixFmt(for: .h265, source: probe)
                let sampling = probe.pixFmt.contains("444") ? "4:4:4" : "4:2:2"
                job.notes.append(kept.contains("422") || kept.contains("444") ? "Color sampling kept at \(sampling). Some phones only play 4:2:0" : "Color reduced to 4:2:0 so browsers can play it")
            }
            if audio.keep {
                job.notes.append(s.losslessAudio ? "Audio saved lossless (ALAC), every channel kept" : "Audio saved as AAC, 128 kb/s per channel")
            }
            if let fps = probe.fps, fps.value > 30 {
                job.notes.append(s.frameRate == .cap ? "Frame rate capped from \(fps.pretty) to \(Filters.cappedFPS(fps)!.pretty) fps" : "Frame rate preserved at \(fps.pretty) fps")
            }
            if let max = s.maxWidth, max < probe.width { job.notes.append("Resized to \(Filters.even(max)) px wide") }
            let dir = try OutputLocation.directory(for: job.url)
            let stem = job.url.deletingPathExtension().lastPathComponent
            let expected = Filters.outputSize(probe, maxWidth: s.maxWidth)
            let count = Double(codecs.count)
            for (i, codec) in codecs.enumerated() {
                let output = OutputLocation.unique(dir.appendingPathComponent("\(stem)-\(codec.rawValue).\(codec.fileExtension)"))
                job.status = "Encoding \(codec.shortLabel) (\(i + 1)/\(codecs.count))…"
                let command = try await Encoder.encode(input: job.url.path, probe: probe, codec: codec, crf: s.crf(for: codec), settings: s, keepAudio: audio.keep, maxWidth: s.maxWidth, output: output, speed: { x in
                    Task { @MainActor in job.speed = x }
                }) { p in
                    Task { @MainActor in job.progress = (Double(i) + p * 0.95) / count }
                }
                job.status = "Verifying \(codec.shortLabel)…"
                let verification = try await Encoder.verify(output: output, codec: codec, expectedSize: expected, expectedFPS: Filters.targetFPS(probe, mode: s.frameRate), pixFmt: s.pixFmt(for: codec, source: probe), audio: audio.keep)
                job.outputs.append(EncodeOutput(codec: codec, crf: s.crf(for: codec), url: output, bytes: verification.probe.bytes, sourceBytes: probe.bytes, command: command, verification: verification))
            }
            job.html = Encoder.htmlSnippet(job.outputs)
            job.progress = 1
            job.state = .done
            job.status = "Done"
        } catch where error is CancellationError || Task.isCancelled {
            job.state = .cancelled
            job.status = "Stopped"
            job.progress = 0
        } catch {
            job.state = .failed
            job.status = "Failed"
            job.error = error.localizedDescription
        }
    }
}

@Observable @MainActor
final class CompareModel {
    var input: URL?
    var probe: ProbeInfo?
    var options = CompareOptions()
    var isRunning = false
    var status = ""
    var progress: Double = 0
    var result: CompareResult?
    var error: String?
    var showMetrics = false
    var isPaused = false
    private let control = ProcessGroup()
    private var task: Task<Void, Never>?

    func setInput(_ url: URL) {
        input = url
        probe = nil
        result = nil
        error = nil
        Task { probe = try? await Probe.run(url.path) }
    }

    func start() {
        guard let input, !isRunning else { return }
        isRunning = true
        error = nil
        result = nil
        let options = options
        let control = control
        task = Task {
            do {
                result = try await ProcessGroup.$current.withValue(control) {
                    try await CompareEngine.run(input: input, options: options) { text, p in
                        Task { @MainActor in self.status = text; self.progress = p }
                    }
                }
            } catch is CancellationError {
                status = "Stopped"
            } catch {
                self.error = Task.isCancelled ? nil : error.localizedDescription
            }
            isRunning = false
            isPaused = false
        }
    }

    func togglePause() {
        if isPaused { control.resume() } else { control.pause() }
        isPaused.toggle()
    }

    func cancel() {
        task?.cancel()
        control.resume()
        isPaused = false
    }
}
