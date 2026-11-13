import Foundation
import Observation

@Observable @MainActor
final class AuditModel {
    var options = AuditOptions()
    var isRunning = false
    var log: [String] = []
    var report: AuditReport?
    var error: String?
    private var task: Task<Void, Never>?

    func start() {
        guard !isRunning, options.project != nil || !options.startURL.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isRunning = true
        log = []
        error = nil
        report = nil
        let options = options
        task = Task {
            do {
                report = try await Auditor.run(options) { line in Task { @MainActor in self.log.append(line) } }
            } catch is CancellationError {
                log.append("Cancelled.")
            } catch {
                self.error = error.localizedDescription
            }
            isRunning = false
        }
    }

    func cancel() { task?.cancel() }
}

@Observable @MainActor
final class OptimizeModel {
    var options = OptimizeOptions()
    var isRunning = false
    var phase = ""
    var progress: Double = 0
    var log: [String] = []
    var plan: OptimizePlan?
    var result: ApplyResult?
    var restoreLog: [String] = []
    var error: String?
    var isPaused = false
    private let control = ProcessGroup()
    private var task: Task<Void, Never>?

    func togglePause() {
        if isPaused { control.resume() } else { control.pause() }
        isPaused.toggle()
    }

    func buildPlan() {
        guard !isRunning, options.audit.project != nil else { return }
        isRunning = true
        StayAwake.begin()
        phase = "Scanning and encoding"
        log = []
        plan = nil
        result = nil
        restoreLog = []
        error = nil
        progress = 0
        let options = options
        let control = control
        task = Task {
            defer { StayAwake.end() }
            do {
                plan = try await ProcessGroup.$current.withValue(control) {
                    try await Optimizer.plan(options, log: { line in Task { @MainActor in self.log.append(line) } }, progress: { p in Task { @MainActor in self.progress = p } })
                }
            } catch is CancellationError {
                log.append("Stopped.")
            } catch {
                self.error = error.localizedDescription
            }
            isRunning = false
            isPaused = false
            phase = ""
        }
    }

    func apply() {
        guard let plan, !isRunning else { return }
        isRunning = true
        phase = "Applying changes"
        task = Task {
            do {
                result = try await Optimizer.apply(plan) { line in Task { @MainActor in self.log.append(line) } }
            } catch {
                self.error = error.localizedDescription
            }
            isRunning = false
            phase = ""
        }
    }

    func restore() {
        guard let backup = result?.backup else { return }
        do {
            restoreLog = try Optimizer.restore(backup)
            result = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func cancel() {
        task?.cancel()
        control.resume()
        isPaused = false
    }
}
