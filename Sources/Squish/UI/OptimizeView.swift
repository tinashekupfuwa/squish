import SwiftUI

struct OptimizeView: View {
    @Bindable var model: OptimizeModel

    var body: some View {
        HStack(spacing: 0) {
            Form {
                SiteInputsSection(options: $model.options.audit)
                CodecSettingsSection(settings: $model.options.encode, showResize: false)
                Section("Replacement rules") {
                    Stepper(value: $model.options.threshold, in: 0...0.5, step: 0.05) {
                        Text("Replace only if ≥ \(Int((model.options.threshold * 100).rounded()))% smaller")
                    }
                    Toggle("Drop audio when every player is muted without controls", isOn: $model.options.removeAudioWhenMutedWithoutControls)
                }
            }
            .formStyle(.grouped)
            .frame(width: 370)
            .disabled(model.isRunning)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                if let result = model.result {
                    ResultView(result: result, model: model)
                } else if let plan = model.plan {
                    PlanView(plan: plan)
                } else if model.log.isEmpty {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "wand.and.stars").font(.system(size: 34)).foregroundStyle(.secondary)
                        Text("Scan and optimize a whole project").font(.headline)
                        Text("Squish audits every video, encodes full VP9 and H.265 outputs from the best source at the measured size, and prepares replacements plus source edits that add WebM sources. Nothing in your project changes until you press Apply, and every change is backed up.")
                            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 480)
                    }
                    .frame(maxWidth: .infinity)
                    Spacer()
                } else {
                    Spacer()
                }
                if !model.restoreLog.isEmpty {
                    Label("Backup restored: \(model.restoreLog.count) files", systemImage: "arrow.uturn.backward.circle").foregroundStyle(.green)
                }
                if let error = model.error { ErrorText(text: error) }
                if model.isRunning {
                    ProgressView(value: model.progress) { Text(model.phase).font(.callout) }
                }
                if !model.log.isEmpty, model.isRunning || (model.plan == nil && model.result == nil) { LogView(lines: model.log) }
                HStack {
                    Spacer()
                    if model.isRunning { Button("Cancel", role: .cancel) { model.cancel() } }
                    if let plan = model.plan, model.result == nil, plan.hasWork {
                        Button("Apply \(plan.changes.count + plan.edits.count) changes") { model.apply() }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.isRunning)
                    }
                    Button(model.plan == nil ? "Scan & build plan" : "Rebuild plan") { model.buildPlan() }
                        .buttonStyle(.bordered)
                        .keyboardShortcut(model.plan == nil ? .defaultAction : .init("r"))
                        .disabled(model.isRunning || model.options.audit.project == nil || model.options.encode.enabledCodecs.isEmpty)
                }
            }
            .padding()
        }
    }
}

struct PlanView: View {
    let plan: OptimizePlan

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 28) {
                    stat("Videos", "\(plan.videos.count)")
                    stat("File changes", "\(plan.changes.count)")
                    stat("Source edits", "\(plan.edits.count)")
                    stat("Replaced files", "\(Fmt.bytes(plan.storageBefore)) → \(Fmt.bytes(plan.storageAfter))")
                }
                if !plan.hasWork {
                    Label("No worthwhile improvements found; nothing would change.", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                }
                ForEach(plan.videos) { video in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(video.name).font(.headline)
                            if let source = video.source { Text("from \(source.name) · \(source.probe?.dimensions ?? "")").foregroundStyle(.secondary) }
                            Spacer()
                            if video.playbackBefore > 0, !video.changes.isEmpty {
                                Text("Playback \(Fmt.bytes(video.playbackBefore)) → \(Fmt.bytes(video.playbackAfter))").monospacedDigit().foregroundStyle(.green)
                            }
                        }
                        if let skipped = video.skipped { Text(skipped).font(.callout).foregroundStyle(.secondary) }
                        if let width = video.targetWidth { Text("Resized to \(width) px wide").font(.callout) }
                        if let audio = video.audio { Text(audio.reason).font(.callout).foregroundStyle(.secondary) }
                        ForEach(video.outputs) { output in
                            Text("\(output.codec.label) CRF \(output.crf): \(Fmt.bytes(output.bytes)) · \(output.verification.passed ? "verified" : "failed verification")")
                                .font(.callout).monospacedDigit()
                        }
                        ForEach(video.changes) { change in
                            HStack {
                                Text(change.action.rawValue).font(.caption.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Capsule().fill(color(change.action).opacity(0.18)))
                                Text(change.relPath).font(.system(.callout, design: .monospaced))
                                if change.action == .replace { Text("\(Fmt.bytes(change.before)) → \(Fmt.bytes(change.after))").monospacedDigit().foregroundStyle(.secondary) }
                                if change.action == .add { Text(Fmt.bytes(change.after)).foregroundStyle(.secondary) }
                            }
                        }
                        ForEach(video.notes, id: \.self) { Label($0, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary) }
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.07)))
                }
                if !plan.edits.isEmpty {
                    Text("Source edits").font(.headline)
                    ForEach(plan.edits) { edit in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(edit.relPath).font(.system(.callout, design: .monospaced).bold())
                            ForEach(Array(edit.changedLines.enumerated()), id: \.offset) { _, line in
                                Text((line.removed ? "- " : "+ ") + line.text)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(line.removed ? .red : .green)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.07)))
                        .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading) {
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func color(_ action: ChangeAction) -> Color {
        switch action {
        case .replace: return .blue
        case .add: return .green
        case .backup: return .orange
        }
    }
}

struct ResultView: View {
    let result: ApplyResult
    let model: OptimizeModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Label(result.problems.isEmpty ? "Changes applied and verified" : "Applied with \(result.problems.count) problem(s)",
                      systemImage: result.problems.isEmpty ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(result.problems.isEmpty ? .green : .orange)
                Text("Changed files").font(.subheadline.bold())
                ForEach(result.changed, id: \.self) { Text($0).font(.system(.callout, design: .monospaced)) }
                Text("Verification").font(.subheadline.bold())
                ForEach(result.checks, id: \.self) { Label($0, systemImage: "checkmark").font(.callout) }
                ForEach(result.problems, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange) }
                HStack {
                    Button("Copy report") { Finder.copy(result.markdown) }
                    Button("Save report…") { Panels.save(result.markdown, name: "video-optimization.md") }
                    Button("Show backup") { Finder.reveal([result.backup]) }
                    Button("Restore backup", role: .destructive) { model.restore() }
                }
                .padding(.top, 6)
            }
            .textSelection(.enabled)
        }
    }
}
