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
    var audioNote: String?
    var notes: [String] = []
    var outputs: [EncodeOutput] = []
    var error: String?
    var html: String?

    init(url: URL) { self.url = url }
}

@Observable @MainActor
final class CompressModel {
    var jobs: [CompressJob] = []
    var settings = EncodeSettings()
    var isRunning = false
    private var task: Task<Void, Never>?

    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "webm", "mkv", "avi", "ogv", "mpg", "mpeg", "mts", "m2ts", "wmv", "flv", "3gp", "gif"]

    func add(_ urls: [URL]) {
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let items = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
                add(items.filter { Self.videoExtensions.contains($0.pathExtension.lowercased()) })
            } else if !jobs.contains(where: { $0.url == url }) {
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

    func start() {
        guard !isRunning, !pending.isEmpty else { return }
        isRunning = true
        let settings = settings
        task = Task {
            for job in pending {
                if Task.isCancelled { break }
                await process(job, settings)
            }
            isRunning = false
        }
    }

    func cancel() { task?.cancel() }

    private func process(_ job: CompressJob, _ s: EncodeSettings) async {
        job.state = .running
        job.outputs = []
        job.notes = []
        job.error = nil
        job.html = nil
        job.progress = 0
        do {
            let codecs = s.enabledCodecs
            guard !codecs.isEmpty else { throw ToolError.message("Choose at least one output format.") }
            job.status = "Inspecting…"
            let probe = try await Probe.run(job.url.path)
            job.probe = probe
            job.status = "Analyzing audio…"
            let audio = try await Encoder.decideAudio(input: job.url.path, probe: probe, mode: s.audio)
            job.audioNote = audio.reason
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
                let command = try await Encoder.encode(input: job.url.path, probe: probe, codec: codec, crf: s.crf(for: codec), settings: s, keepAudio: audio.keep, maxWidth: s.maxWidth, output: output) { p in
                    Task { @MainActor in job.progress = (Double(i) + p * 0.95) / count }
                }
                job.status = "Verifying \(codec.shortLabel)…"
                let verification = try await Encoder.verify(output: output, codec: codec, expectedSize: expected, expectedFPS: Filters.targetFPS(probe, mode: s.frameRate), pixFmt: s.pixFmt, audio: audio.keep)
                job.outputs.append(EncodeOutput(codec: codec, crf: s.crf(for: codec), url: output, bytes: verification.probe.bytes, sourceBytes: probe.bytes, command: command, verification: verification))
            }
            job.html = Encoder.htmlSnippet(job.outputs)
            job.progress = 1
            job.state = .done
            job.status = "Done"
        } catch is CancellationError {
            job.state = .cancelled
            job.status = "Cancelled"
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
        task = Task {
            do {
                result = try await CompareEngine.run(input: input, options: options) { text, p in
                    Task { @MainActor in self.status = text; self.progress = p }
                }
            } catch is CancellationError {
                status = "Cancelled"
            } catch {
                self.error = error.localizedDescription
            }
            isRunning = false
        }
    }

    func cancel() { task?.cancel() }
}
