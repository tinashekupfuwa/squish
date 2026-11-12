import Foundation

enum ToolError: LocalizedError {
    case notFound(String)
    case failed(String, Int32, String)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let tool):
            return "\(tool) was not found. Install it with `brew install ffmpeg`, or set its location in Settings."
        case .failed(let command, let code, let tail):
            return "Command failed (exit \(code)): \(command)\n\(tail)"
        case .message(let text):
            return text
        }
    }
}

enum Tools {
    static let searchDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin"]

    static func locate(_ name: String) -> String? {
        let custom = UserDefaults.standard.string(forKey: "\(name)Path") ?? ""
        if !custom.isEmpty, FileManager.default.isExecutableFile(atPath: custom) { return custom }
        for dir in searchDirectories {
            let path = dir + "/" + name
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    static func ffmpeg() throws -> String {
        guard let path = locate("ffmpeg") else { throw ToolError.notFound("ffmpeg") }
        return path
    }

    static func ffprobe() throws -> String {
        guard let path = locate("ffprobe") else { throw ToolError.notFound("ffprobe") }
        return path
    }
}

final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var pending = Data()
    private let keep: Bool
    private let onLine: (@Sendable (String) -> Void)?

    init(keep: Bool, onLine: (@Sendable (String) -> Void)?) {
        self.keep = keep
        self.onLine = onLine
    }

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        if keep { data.append(chunk) }
        guard let onLine else { return }
        pending.append(chunk)
        while let index = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let line = Data(pending[pending.startIndex..<index])
            pending.removeSubrange(pending.startIndex...index)
            if !line.isEmpty { onLine(String(decoding: line, as: UTF8.self)) }
        }
    }

    func finish() -> String {
        lock.lock()
        defer { lock.unlock() }
        if let onLine, !pending.isEmpty { onLine(String(decoding: pending, as: UTF8.self)) }
        pending.removeAll()
        return String(decoding: data, as: UTF8.self)
    }
}

struct RunResult: Sendable {
    let status: Int32
    let stdout: String
    let stderr: String
}

enum Runner {
    static func run(
        _ executable: String,
        _ arguments: [String],
        keepStdout: Bool = true,
        onStdoutLine: (@Sendable (String) -> Void)? = nil,
        onStderrLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> RunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let outBuffer = LineBuffer(keep: keepStdout, onLine: onStdoutLine)
        let errBuffer = LineBuffer(keep: true, onLine: onStderrLine)
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty { outBuffer.append(chunk) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty { errBuffer.append(chunk) }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RunResult, Error>) in
                process.terminationHandler = { finished in
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    let restOut = outPipe.fileHandleForReading.readDataToEndOfFile()
                    if !restOut.isEmpty { outBuffer.append(restOut) }
                    let restErr = errPipe.fileHandleForReading.readDataToEndOfFile()
                    if !restErr.isEmpty { errBuffer.append(restErr) }
                    continuation.resume(returning: RunResult(status: finished.terminationStatus, stdout: outBuffer.finish(), stderr: errBuffer.finish()))
                }
                do {
                    try process.run()
                    if Task.isCancelled { process.terminate() }
                } catch {
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    static func checked(
        _ executable: String,
        _ arguments: [String],
        keepStdout: Bool = true,
        onStdoutLine: (@Sendable (String) -> Void)? = nil,
        onStderrLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> RunResult {
        let result = try await run(executable, arguments, keepStdout: keepStdout, onStdoutLine: onStdoutLine, onStderrLine: onStderrLine)
        try Task.checkCancellation()
        guard result.status == 0 else {
            let name = URL(fileURLWithPath: executable).lastPathComponent
            throw ToolError.failed(commandLine(name, arguments), result.status, String(result.stderr.suffix(1500)))
        }
        return result
    }

    static func commandLine(_ name: String, _ arguments: [String]) -> String {
        ([name] + arguments).map(shellQuote).joined(separator: " ")
    }

    static func shellQuote(_ value: String) -> String {
        if !value.isEmpty, value.range(of: "^[A-Za-z0-9_./:=,+@%-]+$", options: .regularExpression) != nil { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
