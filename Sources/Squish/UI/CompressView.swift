import SwiftUI

struct CompressView: View {
    @Bindable var model: CompressModel

    var body: some View {
        HStack(spacing: 0) {
            Form { CodecSettingsSection(settings: $model.settings) }
                .formStyle(.grouped)
                .frame(width: 350)
                .disabled(model.isRunning)
            Divider()
            VStack(spacing: 12) {
                DropZone(title: "Drop videos or folders", subtitle: "Each video becomes a VP9 WebM and an H.265 MP4 by default", onDrop: model.add) {
                    model.add(Panels.chooseVideos())
                }
                if model.jobs.isEmpty {
                    Spacer()
                    Text("Outputs are verified with FFprobe and a full decode, then shown here with their savings and the exact commands used.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
                    Spacer()
                } else {
                    List {
                        ForEach(model.jobs) { job in
                            JobRow(job: job) { model.remove(job) }
                        }
                    }
                    .listStyle(.inset)
                }
                HStack {
                    Button("Clear finished") { model.clearFinished() }.disabled(!model.jobs.contains { $0.state == .done })
                    Spacer()
                    if model.isRunning { Button("Cancel", role: .cancel) { model.cancel() } }
                    Button(model.isRunning ? "Compressing…" : "Compress \(model.pending.count) video\(model.pending.count == 1 ? "" : "s")") { model.start() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isRunning || model.pending.isEmpty || model.settings.enabledCodecs.isEmpty)
                }
            }
            .padding()
        }
    }
}

struct JobRow: View {
    let job: CompressJob
    let onRemove: () -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: icon).foregroundStyle(color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.url.lastPathComponent).font(.headline).lineLimit(1).truncationMode(.middle)
                    if let probe = job.probe { Text(probe.summary).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                Text(job.status).font(.caption).foregroundStyle(.secondary)
                if job.state != .running {
                    Button(action: onRemove) { Image(systemName: "xmark") }.buttonStyle(.borderless)
                }
            }
            if job.state == .running { ProgressView(value: job.progress) }
            if let error = job.error { ErrorText(text: error) }
            if let note = job.audioNote { Label(note, systemImage: "speaker.wave.2").font(.caption).foregroundStyle(.secondary) }
            ForEach(job.notes, id: \.self) { Label($0, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary) }
            if !job.outputs.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    ForEach(job.outputs) { output in
                        GridRow {
                            Text(output.codec.label).fontWeight(.medium)
                            Text(output.url.lastPathComponent).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                            Text("\(Fmt.bytes(output.sourceBytes)) → \(Fmt.bytes(output.bytes))").monospacedDigit()
                            Text(Fmt.savings(from: output.sourceBytes, to: output.bytes))
                                .foregroundStyle(output.bytes < output.sourceBytes ? .green : .orange).monospacedDigit()
                            Image(systemName: output.verification.passed ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(output.verification.passed ? .green : .orange)
                                .help((output.verification.checks + output.verification.issues).joined(separator: "\n"))
                            Button("Show") { Finder.reveal([output.url]) }.buttonStyle(.link)
                        }
                    }
                }
                .font(.callout)
                DisclosureGroup("Commands, verification, and HTML", isExpanded: $expanded) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(job.outputs) { output in
                            Text("\(output.codec.label): \(output.verification.checks.joined(separator: ", "))\(output.verification.issues.isEmpty ? "" : " — issues: " + output.verification.issues.joined(separator: "; "))")
                                .font(.caption).foregroundStyle(output.verification.passed ? Color.secondary : Color.orange)
                            CodeBlock(text: output.command)
                        }
                        if let html = job.html {
                            Text("HTML snippet").font(.caption).bold()
                            CodeBlock(text: html)
                        }
                    }
                    .padding(.top, 4)
                }
                .font(.callout)
            }
        }
        .padding(.vertical, 6)
    }

    private var icon: String {
        switch job.state {
        case .queued: return "clock"
        case .running: return "gearshape.2"
        case .done: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .cancelled: return "stop.circle"
        }
    }

    private var color: Color {
        switch job.state {
        case .done: return .green
        case .failed: return .red
        case .running: return .accentColor
        default: return .secondary
        }
    }
}
