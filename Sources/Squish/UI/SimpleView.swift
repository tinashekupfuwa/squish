import SwiftUI

struct AppGlyph: View {
    var size: CGFloat = 30
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28)
            .fill(LinearGradient(colors: [Color(red: 0.10, green: 0.78, blue: 0.72), Color(red: 0.29, green: 0.25, blue: 0.86)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay(Image(systemName: "arrow.down.right.and.arrow.up.left").font(.system(size: size * 0.42, weight: .bold)).foregroundStyle(.white))
    }
}

/// Big percentage and tick meter shared by Simple mode and the menu bar panel.
struct QueueStatus: View {
    let model: CompressModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(bigNumber)
                    .font(.system(size: 54, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(unit).font(.system(size: 20, weight: .light, design: .rounded)).foregroundStyle(.secondary)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(headline).font(.callout.weight(.medium)).foregroundStyle(headlineColor)
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            TickBar(value: model.isRunning || model.overallProgress > 0 ? model.overallProgress : 0,
                    count: 34, paused: model.isPaused, running: model.isRunning, tint: model.doneJobs.isEmpty || model.isRunning ? .orange : .green, height: 20)
        }
    }

    private var finished: Bool { !model.isRunning && !model.doneJobs.isEmpty && model.pending.isEmpty }

    private var bigNumber: String {
        if finished { return "\(Int((model.savedRatio * 100).rounded()))" }
        return "\(Int((model.overallProgress * 100).rounded()))"
    }
    private var unit: String { finished ? "% smaller" : "%" }

    private var headline: String {
        if model.isPaused { return "Paused" }
        if model.isRunning { return "Compressing" }
        if finished { return "Saved \(Fmt.bytes(model.savedBytes))" }
        if model.jobs.isEmpty { return "Ready" }
        return "\(model.pending.count) waiting"
    }
    private var headlineColor: Color { model.isPaused ? .yellow : model.isRunning ? .orange : finished ? .green : .primary }

    private var detail: String {
        if let job = model.currentJob { return "\(job.url.lastPathComponent) · \(model.doneJobs.count + 1) of \(model.jobs.count)" }
        if finished { return "\(model.doneJobs.count) video\(model.doneJobs.count == 1 ? "" : "s") done" }
        if model.jobs.isEmpty { return "Add videos to begin" }
        return "Press Start when ready"
    }
}

struct SimpleView: View {
    @Bindable var model: CompressModel
    @AppStorage("outputMode") private var outputMode = "source"
    @AppStorage("outputFolder") private var outputFolder = ""
    @State private var toolsFound = Tools.locate("ffmpeg") != nil

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                AppGlyph(size: 26)
                Text("Squish").font(.title3.weight(.semibold)).fixedSize()
                Spacer(minLength: 8)
                ModeSwitch(width: 150)
            }
            .padding(.leading, 64)
            .frame(height: 28)

            if !toolsFound {
                Text("Install FFmpeg first: brew install ffmpeg").font(.callout).foregroundStyle(.orange)
                    .onTapGesture { toolsFound = Tools.locate("ffmpeg") != nil }
            }

            PanelCard { QueueStatus(model: model) }

            queue

            VStack(alignment: .leading, spacing: 8) {
                CapsLabel("Quality")
                QualityRuler(value: $model.quality)
            }
            .disabled(model.isRunning)

            controls

            HStack(spacing: 6) {
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text(destinationText).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Menu {
                    Button("Next to each original") { outputMode = "source" }
                    Button("Choose folder…") {
                        if let url = Panels.chooseFolder() { outputFolder = url.path; outputMode = "custom" }
                    }
                } label: { Text("Change").font(.caption) }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
        .padding(.top, 2)
        .toolbar(.hidden, for: .windowToolbar)
        .ignoresSafeArea(.container, edges: .top)
        .padding(.top, 10)
    }

    private var destinationText: String {
        outputMode == "custom" && !outputFolder.isEmpty ? "Saving to " + (outputFolder as NSString).abbreviatingWithTildeInPath : "Saving next to each original"
    }

    @ViewBuilder
    private var queue: some View {
        if model.jobs.isEmpty {
            Button {
                model.add(Panels.chooseVideos())
            } label: {
                VStack(spacing: 8) {
                    Image(systemName: "plus.circle").font(.system(size: 28, weight: .light))
                    Text("Drop videos here").font(.headline)
                    Text("or click to choose").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.white.opacity(0.15), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
                .contentShape(RoundedRectangle(cornerRadius: 18))
            }
            .buttonStyle(.plain)
            .frame(maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                HStack {
                    CapsLabel("Queue · \(model.jobs.count)")
                    Spacer()
                    if !model.doneJobs.isEmpty, !model.isRunning {
                        Button("Clear done") { withAnimation(.spring(response: 0.3)) { model.clearFinished() } }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                    }
                    Button { model.add(Panels.chooseVideos()) } label: { Image(systemName: "plus") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).padding(.leading, 6).help("Add videos")
                }
                .padding(.bottom, 6)
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(model.jobs) { job in
                            SimpleJobRow(job: job, paused: model.isPaused && job.state == .running) {
                                withAnimation(.spring(response: 0.3)) { model.remove(job) }
                            }
                            .transition(.opacity)
                        }
                    }
                }
                .scrollIndicators(.never)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            if model.isRunning {
                Button { model.isPaused ? model.resume() : model.pause() } label: {
                    Label(model.isPaused ? "Resume" : "Pause", systemImage: model.isPaused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(PanelButtonStyle(primary: true))
                .keyboardShortcut(.space, modifiers: [])
                Button(role: .destructive) { model.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                    .buttonStyle(PanelButtonStyle(tint: .red))
                    .frame(width: 110)
                    .keyboardShortcut(".", modifiers: .command)
            } else {
                Button { model.start() } label: { Label(model.pending.isEmpty && !model.jobs.isEmpty ? "All done" : "Start", systemImage: "play.fill") }
                    .buttonStyle(PanelButtonStyle(primary: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.pending.isEmpty)
                    .opacity(model.pending.isEmpty ? 0.5 : 1)
            }
        }
    }
}

struct SimpleJobRow: View {
    let job: CompressJob
    let paused: Bool
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(color.opacity(0.18)).frame(width: 28, height: 28)
                Image(systemName: icon).font(.system(size: 12, weight: .bold)).foregroundStyle(color)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(job.url.lastPathComponent).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                if job.state == .running {
                    GlowProgressBar(value: job.progress, paused: paused, height: 4)
                } else {
                    Text(subtitle).font(.caption).foregroundStyle(job.state == .failed ? .red : .secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            trailing
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(hovering ? 0.08 : 0.04)))
        .onHover { hovering = $0 }
        .help(job.error ?? job.outputs.map { "\($0.url.lastPathComponent): \(Fmt.bytes($0.bytes))" }.joined(separator: "\n"))
        .onTapGesture(count: 2) { if !job.outputs.isEmpty { Finder.reveal(job.outputs.map(\.url)) } }
    }

    @ViewBuilder
    private var trailing: some View {
        if job.state == .running {
            Text("\(Int((job.progress * 100).rounded()))%").font(.callout.monospacedDigit()).foregroundStyle(.secondary).contentTransition(.numericText())
        } else if job.state == .done, let smallest = job.outputs.map(\.bytes).min(), let source = job.outputs.first?.sourceBytes, source > 0 {
            HStack(spacing: 6) {
                Text("−\(Int(((1 - Double(smallest) / Double(source)) * 100).rounded()))%")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.green)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(Color.green.opacity(0.15)))
                Button { Finder.reveal(job.outputs.map(\.url)) } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Show in Finder")
            }
        } else if hovering {
            Button(action: remove) { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.tertiary)
        }
    }

    private var subtitle: String {
        switch job.state {
        case .done:
            guard let smallest = job.outputs.map(\.bytes).min(), let source = job.outputs.first?.sourceBytes else { return "Done" }
            return "\(Fmt.bytes(source)) → \(Fmt.bytes(smallest))"
        case .failed: return job.error ?? "Failed"
        case .cancelled: return "Stopped · will restart"
        default:
            return job.probe.map { "\($0.dimensions) · \(Fmt.duration($0.duration)) · \(Fmt.bytes($0.bytes))" } ?? "Waiting"
        }
    }

    private var icon: String {
        if paused { return "pause.fill" }
        switch job.state {
        case .queued: return "clock"
        case .running: return "bolt.fill"
        case .done: return "checkmark"
        case .failed: return "exclamationmark"
        case .cancelled: return "stop.fill"
        }
    }

    private var color: Color {
        if paused { return .yellow }
        switch job.state {
        case .done: return .green
        case .failed: return .red
        case .running: return .orange
        default: return .secondary
        }
    }
}
