import AppKit
import Foundation

@main
enum Main {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first, CLI.commands.contains(command) else {
            SquishApp.main()
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do {
                try await CLI.run(command, Array(args.dropFirst()))
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        app.run()
    }
}

/// Headless access to the same engines the app uses, for scripts and terminals.
@MainActor
enum CLI {
    static let commands: Set<String> = ["compress", "compare", "audit", "optimize", "restore", "help", "--help"]

    static func run(_ command: String, _ args: [String]) async throws {
        let flags = Set(args.filter { $0.hasPrefix("--") })
        let positional = args.filter { !$0.hasPrefix("--") }
        let log: @Sendable (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
        switch command {
        case "compress":
            guard !positional.isEmpty else { throw ToolError.message("usage: Squish compress <file>… [--av1] [--preserve-fps] [--faster]") }
            var settings = EncodeSettings()
            settings.av1 = flags.contains("--av1")
            if flags.contains("--preserve-fps") { settings.frameRate = .preserve }
            if flags.contains("--faster") { settings.speed = .faster }
            for path in positional {
                let input = URL(fileURLWithPath: path)
                let probe = try await Probe.run(input.path)
                let audio = try await Encoder.decideAudio(input: input.path, probe: probe, mode: settings.audio)
                print("\(input.lastPathComponent): \(probe.summary)\n  \(audio.reason)")
                var outputs: [EncodeOutput] = []
                for codec in settings.enabledCodecs {
                    let out = OutputLocation.unique(try OutputLocation.directory(for: input).appendingPathComponent("\(input.deletingPathExtension().lastPathComponent)-\(codec.rawValue).\(codec.fileExtension)"))
                    let cmd = try await Encoder.encode(input: input.path, probe: probe, codec: codec, crf: settings.crf(for: codec), settings: settings, keepAudio: audio.keep, maxWidth: nil, output: out) { _ in }
                    let v = try await Encoder.verify(output: out, codec: codec, expectedSize: Filters.outputSize(probe, maxWidth: nil), expectedFPS: Filters.targetFPS(probe, mode: settings.frameRate), pixFmt: settings.pixFmt, audio: audio.keep)
                    outputs.append(EncodeOutput(codec: codec, crf: settings.crf(for: codec), url: out, bytes: v.probe.bytes, sourceBytes: probe.bytes, command: cmd, verification: v))
                    print("  \(out.path): \(Fmt.bytes(probe.bytes)) → \(Fmt.bytes(v.probe.bytes)) (\(Fmt.savings(from: probe.bytes, to: v.probe.bytes))) [\(v.passed ? "verified: " + v.checks.joined(separator: ", ") : "ISSUES: " + v.issues.joined(separator: "; "))]\n    \(cmd)")
                }
                print(Encoder.htmlSnippet(outputs))
            }
        case "compare":
            guard let path = positional.first else { throw ToolError.message("usage: Squish compare <file> [--av1] [--faster] [--psnr]") }
            var options = CompareOptions()
            if flags.contains("--av1") { options.candidates += [42].map { Candidate(codec: .av1, crf: $0) } }
            if flags.contains("--faster") { options.speed = .faster }
            options.psnr = flags.contains("--psnr")
            let result = try await CompareEngine.run(input: URL(fileURLWithPath: path), options: options) { text, _ in log(text) }
            print(result.markdown)
            if flags.contains("--metrics") { for r in result.ordered { print("\(r.candidate.codec.shortLabel) \(r.candidate.crf): SSIM \(r.ssim) frontier=\(r.onFrontier)") } }
        case "audit", "optimize":
            var options = AuditOptions()
            for arg in positional {
                if arg.hasPrefix("http://") || arg.hasPrefix("https://") { options.startURL = arg } else { options.project = URL(fileURLWithPath: arg, isDirectory: true) }
            }
            if let pages = args.first(where: { $0.hasPrefix("--pages=") }) { options.maxPages = Int(pages.dropFirst(8)) ?? 1 }
            if let originals = args.first(where: { $0.hasPrefix("--originals=") }) { options.originals = URL(fileURLWithPath: String(originals.dropFirst(12)), isDirectory: true) }
            if command == "audit" {
                let report = try await Auditor.run(options, log: log)
                print(report.markdown)
            } else {
                var o = OptimizeOptions()
                o.audit = options
                if flags.contains("--faster") { o.encode.speed = .faster }
                let plan = try await Optimizer.plan(o, log: log) { _ in }
                for v in plan.videos {
                    print("\(v.name): \(v.skipped ?? v.changes.map { "\($0.action.rawValue) \($0.relPath) " + ($0.action == .add ? Fmt.bytes($0.after) : $0.action == .backup ? Fmt.bytes($0.before) : "\(Fmt.bytes($0.before)) → \(Fmt.bytes($0.after))") }.joined(separator: ", "))")
                    for n in v.notes { print("  note: \(n)") }
                }
                for e in plan.edits {
                    print("--- \(e.relPath)")
                    for l in e.changedLines { print((l.removed ? "- " : "+ ") + l.text) }
                }
                if flags.contains("--apply") {
                    let result = try await Optimizer.apply(plan, log: log)
                    print(result.markdown)
                } else {
                    print("(dry run; pass --apply to write changes)")
                }
            }
        case "restore":
            guard let path = positional.first else { throw ToolError.message("usage: Squish restore <backup folder>") }
            for line in try Optimizer.restore(URL(fileURLWithPath: path, isDirectory: true)) { print(line) }
        default:
            print("""
            Squish: compress, compare, audit, and optimize web videos with FFmpeg.
              Squish compress <file>… [--av1] [--preserve-fps] [--faster]
              Squish compare <file> [--av1] [--psnr] [--faster]
              Squish audit <folder> [url] [--pages=N] [--originals=DIR]
              Squish optimize <folder> [url] [--pages=N] [--originals=DIR] [--faster] [--apply]
              Squish restore <backup folder>
            Run without arguments to open the app.
            """)
        }
    }
}
