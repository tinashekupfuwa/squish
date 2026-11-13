import SwiftUI

struct CompressView: View {
    @Bindable var model: CompressModel

    var body: some View {
        HStack(spacing: 0) {
            Form {
                Section("Preset") {
                    PresetMenu(model: model)
                }
                CodecSettingsSection(settings: $model.settings)
                DestinationSection()
            }
            .clearFormBackground()
            .frame(width: 320)
            .disabled(model.isRunning)
            Divider()
            VStack(spacing: 12) {
                DropZone(title: "Add videos or folders", subtitle: "Queued until you press Start", onDrop: { urls in withAnimation(.spring) { model.add(urls) } }) {
                    let urls = Panels.chooseVideos()
                    withAnimation(.spring) { model.add(urls) }
                }
                if model.jobs.isEmpty {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "tray").font(.system(size: 30)).foregroundStyle(.secondary)
                        Text("No videos yet").font(.headline).foregroundStyle(.secondary)
                        Text("Each video becomes a WebM and an MP4 that together play in every modern browser. Squish checks every file it makes, and your originals are never changed.")
                            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
                    }
                    .transition(.opacity)
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(model.jobs) { job in
                                JobRow(job: job, paused: model.isPaused && job.state == .running) {
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { model.remove(job) }
                                }
                                .transition(.card)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .scrollContentBackground(.hidden)
                }
                controlBar
            }
            .padding(14)
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: model.jobs.map(\.id))
        }
    }

    private var controlBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(summary).font(.callout.weight(.medium)).lineLimit(1).contentTransition(.numericText())
                    Spacer()
                    if model.isRunning || model.overallProgress > 0 {
                        Text("\(Int((model.overallProgress * 100).rounded()))%").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                    }
                }
                SegmentedProgressBar(
                    segments: model.jobs.map { $0.state == .done || $0.state == .failed ? 1 : $0.progress },
                    active: model.isRunning ? model.jobs.firstIndex { $0.state == .running } : nil,
                    failed: Set(model.jobs.indices.filter { model.jobs[$0].state == .failed }),
                    paused: model.isPaused || model.isStopping,
                    height: 8
                )
            }
            Menu {
                Button("Clear finished") { withAnimation(.spring) { model.clearFinished() } }.disabled(!model.jobs.contains { $0.state == .done })
                Button("Clear all", role: .destructive) { withAnimation(.spring) { model.jobs.removeAll { $0.state != .running } } }.disabled(model.jobs.isEmpty)
            } label: { Image(systemName: "ellipsis") }
            .menuStyle(.button)
            .controlButton()
            .fixedSize()
            TransportControls(isRunning: model.isRunning, isPaused: model.isPaused,
                              canStart: !model.pending.isEmpty && !model.settings.enabledCodecs.isEmpty,
                              startTitle: "Start",
                              compact: true,
                              isStopping: model.isStopping,
                              start: model.start,
                              togglePause: { model.isPaused ? model.resume() : model.pause() },
                              stop: model.stop)
        }
        .padding(12)
        .surfaceCard()
        .animation(.easeInOut(duration: 0.25), value: model.overallProgress)
    }

    private var summary: String {
        let done = model.jobs.filter { $0.state == .done }.count
        let queued = model.pending.count
        if model.isStopping { return "Stopping…" }
        if model.isPaused { return "Paused · \(done) of \(model.jobs.count) done" }
        if model.isRunning { return "Converting · \(done) of \(model.jobs.count) done" }
        if model.jobs.isEmpty { return "No videos queued" }
        return queued == 0 ? "All \(done) done" : "\(queued) ready to convert" + (done > 0 ? " · \(done) done" : "")
    }
}

struct JobRow: View {
    let job: CompressJob
    let paused: Bool
    let onRemove: () -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(color)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.pulse, isActive: job.state == .running && !paused)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.url.lastPathComponent).font(.headline).lineLimit(1).truncationMode(.middle)
                    if let probe = job.probe { Text(probe.summary).font(.caption).foregroundStyle(.secondary).transition(.opacity) }
                }
                Spacer()
                Text(paused ? "Paused" : job.status).font(.caption).foregroundStyle(.secondary).contentTransition(.opacity)
                if job.state != .running {
                    Button(action: onRemove) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.borderless).help("Remove from list").accessibilityLabel("Remove \(job.url.lastPathComponent)")
                }
            }
            if job.state == .running {
                HStack(spacing: 10) {
                    MiniTickBar(value: job.progress, paused: paused)
                    if let speed = job.speed, !paused {
                        Text(Fmt.speed(speed)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).fixedSize()
                            .contentTransition(.numericText())
                    }
                    Text("\(Int((job.progress * 100).rounded()))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
                        .contentTransition(.numericText())
                }
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .leading)))
            }
            if let error = job.error { ErrorText(text: error).transition(.opacity) }
            if let note = job.audioNote { Label(note, systemImage: "speaker.wave.2").font(.caption).foregroundStyle(.secondary) }
            ForEach(job.notes, id: \.self) { Label($0, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary) }
            if !job.outputs.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    ForEach(job.outputs) { output in
                        GridRow {
                            Text(output.codec.shortLabel).fontWeight(.medium).fixedSize()
                            Text(output.url.lastPathComponent).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                            Text("\(Fmt.bytes(output.sourceBytes)) → \(Fmt.bytes(output.bytes))").monospacedDigit().fixedSize()
                            Text(output.sourceBytes > 0 ? String(format: "%+.0f%%", (Double(output.bytes) / Double(output.sourceBytes) - 1) * 100) : "–")
                                .foregroundStyle(output.bytes < output.sourceBytes ? Brand.green : Brand.amber).monospacedDigit().fixedSize()
                            Image(systemName: output.verification.passed ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(output.verification.passed ? .green : .orange)
                                .help((output.verification.checks + output.verification.issues).joined(separator: "\n"))
                            Button("Show") { Finder.reveal([output.url]) }.buttonStyle(.link)
                        }
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .font(.callout)
                DisclosureGroup("Commands, verification, and HTML", isExpanded: $expanded.animation(.spring(response: 0.35))) {
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
        .padding(12)
        .surfaceCard(tint: job.state == .running ? (paused ? .orange : .accentColor) : job.state == .failed ? .red : nil)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: job.state)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: job.outputs.count)
    }

    private var icon: String {
        if paused { return "pause.circle.fill" }
        switch job.state {
        case .queued: return "clock"
        case .running: return "gearshape.2.fill"
        case .done: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .cancelled: return "stop.circle"
        }
    }

    private var color: Color {
        if paused { return .orange }
        switch job.state {
        case .done: return .green
        case .failed: return .red
        case .running: return .accentColor
        default: return .secondary
        }
    }
}
