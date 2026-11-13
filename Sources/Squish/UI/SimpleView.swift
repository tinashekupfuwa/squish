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
            if model.hasLargeVideo {
                TickBar(value: finished ? 1 : model.displayProgress, paused: model.isPaused || model.isStopping, running: model.isRunning, done: finished, tint: Brand.green, tickWidth: 2, spacing: 2.5, height: 30)
            } else {
                SegmentedProgressBar(
                    segments: model.jobs.map { $0.state == .done ? 1 : $0.state == .failed ? 1 : $0.progress },
                    active: model.isRunning ? model.jobs.firstIndex { $0.state == .running } : nil,
                    failed: Set(model.jobs.indices.filter { model.jobs[$0].state == .failed }),
                    paused: model.isPaused || model.isStopping,
                    done: finished
                )
            }
        }
    }

    private var finished: Bool { !model.isRunning && !model.doneJobs.isEmpty && model.pending.isEmpty }

    private var bigNumber: String {
        if finished { return "\(Int((model.savedRatio * 100).rounded()))" }
        return "\(Int((model.displayProgress * 100).rounded()))"
    }
    private var unit: String { finished ? "% smaller" : "%" }

    private var headline: String {
        if model.isStopping { return "Stopping…" }
        if model.isPaused { return "Paused" }
        if model.isRunning { return "Compressing" }
        if finished { return "Saved \(Fmt.bytes(model.savedBytes))" }
        if model.jobs.isEmpty { return "Ready" }
        return "\(model.pending.count) waiting"
    }
    private var headlineColor: Color { model.isStopping ? .red : model.isPaused ? Brand.amber : model.isRunning ? Brand.statusGrey : finished ? Brand.green : .primary }

    private var detail: String {
        if let job = model.currentJob { return "\(job.url.lastPathComponent) · \(model.doneJobs.count + 1) of \(model.jobs.count)" }
        if finished { return "\(model.doneJobs.count) video\(model.doneJobs.count == 1 ? "" : "s") done" }
        if model.jobs.isEmpty { return "Add videos to begin" }
        return "Press Start when ready"
    }
}

struct SimpleView: View {
    @Bindable var model: CompressModel
    @State private var toolsFound = Tools.locate("ffmpeg") != nil

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                AppGlyph(size: 28)
                Text("Squish").font(.title3.weight(.semibold)).fixedSize()
                Spacer(minLength: 8)
                ModeSwitch(width: 160)
            }
            .frame(height: 32)

            if !toolsFound {
                FFmpegSetupCard { toolsFound = Tools.locate("ffmpeg") != nil }
            }

            PanelCard { QueueStatus(model: model) }

            queue

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    CapsLabel("Compression")
                    Spacer()
                    PresetMenu(model: model)
                }
                QualityRuler(quality: $model.quality)
            }
            .disabled(model.isRunning)

            controls

            OutputFolderRow()
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
        .padding(.top, 4)
        .toolbar(.hidden, for: .windowToolbar)
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
                    Text("or click to choose").font(.callout).foregroundStyle(.secondary)
                    Text("Squish saves smaller copies that play on the web. Your original videos are never changed.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 250)
                        .padding(.top, 10)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(Color.primary.opacity(0.22), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
                .contentShape(RoundedRectangle(cornerRadius: Radius.card))
            }
            .buttonStyle(.plain)
            .frame(maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                HStack {
                    CapsLabel("Videos · \(model.jobs.count)")
                    Spacer()
                    if !model.doneJobs.isEmpty, !model.isRunning {
                        Button("Clear finished") { withAnimation(.spring(response: 0.3)) { model.clearFinished() } }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                    }
                    Button { model.add(Panels.chooseVideos()) } label: { Image(systemName: "plus") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).padding(.leading, 6).help("Add videos").accessibilityLabel("Add videos")
                }
                .padding(.bottom, 6)
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(model.jobs) { job in
                            SimpleJobRow(job: job, paused: model.isPaused && job.state == .running, stopping: model.isStopping && job.state == .running) {
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
            if model.isStopping {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Stopping…")
                }
                .font(.body.weight(.semibold))
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(Capsule().fill(Color.red.opacity(0.12)))
                .transition(.opacity)
            } else if model.isRunning {
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
                if model.pending.isEmpty {
                    Button { model.add(Panels.chooseVideos()) } label: { Label(model.jobs.isEmpty ? "Add videos" : "Add more videos", systemImage: "plus") }
                        .buttonStyle(PanelButtonStyle(primary: true))
                } else {
                    Button { model.start() } label: { Label("Start", systemImage: "play.fill") }
                        .buttonStyle(PanelButtonStyle(primary: true))
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }
}

struct SimpleJobRow: View {
    let job: CompressJob
    let paused: Bool
    var stopping = false
    let remove: () -> Void
    @State private var hovering = false

    private var speedLine: String {
        if stopping { return "Stopping…" }
        if paused { return "Paused" }
        guard let speed = job.speed else { return "Measuring speed…" }
        return Fmt.speed(speed)
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(color.opacity(0.18)).frame(width: 28, height: 28)
                Image(systemName: icon).font(.system(size: 12, weight: .bold)).foregroundStyle(color)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(job.url.lastPathComponent).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                if job.state == .running {
                    MiniTickBar(value: job.progress, paused: paused || stopping, height: 9)
                        .padding(.top, 2)
                    Text(speedLine)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .contentTransition(.numericText())
                } else {
                    Text(subtitle).font(.subheadline).foregroundStyle(job.state == .failed ? .red : .secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            trailing
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .surfaceCard(cornerRadius: Radius.row)
        .overlay(RoundedRectangle(cornerRadius: Radius.row).fill(Color.primary.opacity(hovering ? 0.04 : 0)).allowsHitTesting(false))
        .onHover { hovering = $0 }
        .help(job.error ?? (job.outputs.isEmpty ? "" : (job.outputs.map { "\($0.url.lastPathComponent): \(Fmt.bytes($0.bytes))" } + ["MP4 plays everywhere. WebM is smaller for Chrome, Firefox, and Edge. Use both on a website, or just the MP4 elsewhere. Double-click to show in Finder."]).joined(separator: "\n")))
        .onTapGesture(count: 2) { if !job.outputs.isEmpty { Finder.reveal(job.outputs.map(\.url)) } }
    }

    @ViewBuilder
    private var trailing: some View {
        if stopping {
            Text("Stopping…").font(.caption.weight(.semibold)).foregroundStyle(.red)
        } else if job.state == .running {
            Text("\(Int((job.progress * 100).rounded()))%").font(.callout.monospacedDigit()).foregroundStyle(.secondary).contentTransition(.numericText())
        } else if job.state == .done, let smallest = job.outputs.map(\.bytes).min(), let source = job.outputs.first?.sourceBytes, source > 0 {
            HStack(spacing: 6) {
                Text("−\(Int(((1 - Double(smallest) / Double(source)) * 100).rounded()))%")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Brand.green)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(Brand.green.opacity(0.15)))
                Button { Finder.reveal(job.outputs.map(\.url)) } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Show in Finder").accessibilityLabel("Show \(job.url.lastPathComponent) in Finder")
            }
        } else if hovering {
            Button(action: remove) { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary).help("Remove from list").accessibilityLabel("Remove \(job.url.lastPathComponent)")
        }
    }

    private var subtitle: String {
        switch job.state {
        case .done:
            guard let smallest = job.outputs.map(\.bytes).min(), let source = job.outputs.first?.sourceBytes else { return "Done" }
            return "\(Fmt.bytes(source)) → \(Fmt.bytes(smallest)) · \(job.outputs.map { $0.codec.fileExtension.uppercased() }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: " + "))"
        case .failed: return job.error ?? "Failed"
        case .cancelled: return "Stopped · starts over when you press Start"
        default:
            return job.probe.map { "\($0.dimensions)\($0.bitDepth > 8 ? " · \($0.bitDepth)-bit" : "") · \(Fmt.duration($0.duration)) · \(Fmt.bytes($0.bytes))" } ?? "Waiting"
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
        if paused { return Brand.amber }
        switch job.state {
        case .done: return Brand.green
        case .failed: return .red
        case .running: return Brand.orange
        default: return .secondary
        }
    }
}

/// Shown when FFmpeg is missing: what it is, the one command to install it, and a way to re-check.
struct FFmpegSetupCard: View {
    let recheck: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text("One-time setup needed")
            } icon: {
                Image(systemName: "wrench.and.screwdriver.fill").foregroundStyle(Brand.amber)
            }
            .font(.callout.weight(.semibold))
            Text("Squish uses FFmpeg, a free video tool, to make videos smaller. Open Terminal, paste this command, and press Return:")
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text("brew install ffmpeg").font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                Spacer(minLength: 4)
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("brew install ffmpeg", forType: .string)
                    copied = true
                }
                .controlButton()
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: Radius.small).fill(Color.primary.opacity(0.06)))
            HStack {
                Link("No Homebrew? Get it at brew.sh", destination: URL(string: "https://brew.sh")!).font(.subheadline)
                Spacer()
                Button("Check again", action: recheck).controlButton()
            }
        }
        .padding(12)
        .surfaceCard(cornerRadius: Radius.row, tint: Brand.amber)
    }
}

/// Folder icon labelled "Output folder"; shows where files go and opens a menu to change it.
struct OutputFolderRow: View {
    @AppStorage("outputMode") private var outputMode = "source"
    @AppStorage("outputFolder") private var outputFolder = ""

    private var custom: Bool { outputMode == "custom" && !outputFolder.isEmpty }

    var body: some View {
        Menu {
            Button { outputMode = "source" } label: {
                if outputMode == "source" { Label("Same folder as each original", systemImage: "checkmark") } else { Text("Same folder as each original") }
            }
            Button("Choose a folder…") {
                if let url = Panels.chooseFolder() { outputFolder = url.path; outputMode = "custom" }
            }
            if custom {
                Divider()
                Button("Show in Finder") { Finder.open(URL(fileURLWithPath: outputFolder)) }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Brand.indigo)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Output folder").font(.callout.weight(.medium)).foregroundStyle(.primary)
                    Text(custom ? (outputFolder as NSString).abbreviatingWithTildeInPath : "Same folder as each original")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .surfaceCard(cornerRadius: Radius.row)
        .help("Choose where compressed videos are saved")
    }
}
