import SwiftUI

extension View {
    /// Liquid Glass on macOS 26 and later, a translucent material before that.
    @ViewBuilder
    func glassCard(cornerRadius: CGFloat = 14, tint: Color? = nil) -> some View {
        if #available(macOS 26, *) {
            glassEffect(tint.map { Glass.regular.tint($0.opacity(0.18)) } ?? .regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            background((tint ?? .clear).opacity(0.08), in: RoundedRectangle(cornerRadius: cornerRadius))
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }

    @ViewBuilder
    func glassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26, *) {
            if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
        } else {
            if prominent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
        }
    }

    /// Lets the window's glass show through grouped forms.
    func clearFormBackground() -> some View {
        formStyle(.grouped).scrollContentBackground(.hidden)
    }
}

extension AnyTransition {
    static var card: AnyTransition {
        .asymmetric(
            insertion: .scale(scale: 0.94, anchor: .top).combined(with: .opacity).combined(with: .move(edge: .top)),
            removal: .scale(scale: 0.9).combined(with: .opacity)
        )
    }
}

/// A gradient progress bar with a moving shimmer that freezes and turns amber while paused.
struct GlowProgressBar: View {
    var value: Double
    var paused = false
    var height: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
            let clamped = min(max(value, 0), 1)
            let width = clamped > 0 ? max(height, geo.size.width * clamped) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
                TimelineView(.animation(minimumInterval: 1 / 60, paused: paused)) { timeline in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    let phase = CGFloat(t.truncatingRemainder(dividingBy: 1.8) / 1.8)
                    Capsule()
                        .fill(LinearGradient(colors: paused ? [.orange, .yellow] : [.cyan, .blue, .purple, .pink],
                                             startPoint: .leading, endPoint: .trailing))
                        .overlay {
                            if !paused {
                                LinearGradient(colors: [.clear, .white.opacity(0.6), .clear], startPoint: .leading, endPoint: .trailing)
                                    .frame(width: 70)
                                    .offset(x: -width / 2 - 35 + phase * (width + 70))
                            }
                        }
                        .overlay(alignment: .top) {
                            Capsule().fill(.white.opacity(0.35)).frame(height: height * 0.35).padding(.horizontal, height / 2).padding(.top, 1)
                        }
                        .clipShape(Capsule())
                        .frame(width: width)
                        .shadow(color: (paused ? Color.orange : Color.purple).opacity(0.45), radius: 6)
                }
            }
            .animation(.spring(response: 0.45, dampingFraction: 0.85), value: clamped)
            .animation(.easeInOut(duration: 0.3), value: paused)
        }
        .frame(height: height)
    }
}

/// Start / Pause / Resume / Stop for a running workflow.
struct TransportControls: View {
    let isRunning: Bool
    let isPaused: Bool
    let canStart: Bool
    let startTitle: String
    var compact = false
    let start: () -> Void
    let togglePause: () -> Void
    let stop: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if isRunning {
                Button(action: togglePause) {
                    Label(isPaused ? "Resume" : "Pause", systemImage: isPaused ? "play.fill" : "pause.fill")
                        .labelStyle(compact ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleAndIcon))
                        .contentTransition(.symbolEffect(.replace))
                }
                .glassButton()
                .help(isPaused ? "Resume (Space)" : "Pause (Space)")
                .keyboardShortcut(.space, modifiers: [])
                Button(role: .destructive, action: stop) {
                    Label("Stop", systemImage: "stop.fill").labelStyle(compact ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleAndIcon))
                }
                    .glassButton()
                    .help("Stop (⌘.)")
                    .keyboardShortcut(".", modifiers: .command)
                    .transition(.scale.combined(with: .opacity))
            } else {
                Button(action: start) { Label(startTitle, systemImage: "play.fill") }
                    .glassButton(prominent: true)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canStart)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isRunning)
    }
}

struct AnyLabelStyle: LabelStyle {
    private let make: (Configuration) -> AnyView
    init<S: LabelStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

struct DestinationSection: View {
    @AppStorage("outputMode") private var outputMode = "source"
    @AppStorage("outputFolder") private var outputFolder = ""

    var body: some View {
        Section("Destination") {
            Picker("Save to", selection: $outputMode) {
                Text("Next to each source").tag("source")
                Text("Custom folder").tag("custom")
            }
            if outputMode == "custom" {
                HStack {
                    Image(systemName: "folder.fill").foregroundStyle(.tint)
                    Text(outputFolder.isEmpty ? "No folder chosen" : (outputFolder as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(outputFolder.isEmpty ? .secondary : .primary)
                    Spacer()
                    if !outputFolder.isEmpty {
                        Button { Finder.open(URL(fileURLWithPath: outputFolder)) } label: { Image(systemName: "arrow.up.forward.square") }
                            .buttonStyle(.borderless).help("Open in Finder")
                    }
                    Button("Choose…") { if let url = Panels.chooseFolder() { outputFolder = url.path } }
                }
                .dropDestination(for: URL.self) { urls, _ in
                    guard let url = urls.first, url.hasDirectoryPath else { return false }
                    outputFolder = url.path
                    return true
                }
            }
        }
    }
}

/// Pill-shaped segmented control with a sliding thumb.
struct PillSegmented: View {
    let options: [(String, String)]
    @Binding var selection: String
    @Namespace private var thumb

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, title in
                let selected = selection == value
                Text(title)
                    .font(.callout.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background {
                        if selected {
                            Capsule().fill(Color.white.opacity(0.14))
                                .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
                                .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                                .matchedGeometryEffect(id: "thumb", in: thumb)
                        }
                    }
                    .contentShape(Capsule())
                    .onTapGesture {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { selection = value }
                    }
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.white.opacity(0.06)))
    }
}

/// A row of rounded ticks that fill from the left, after the meters in Pulse-style panels.
struct TickBar: View {
    var value: Double
    var count = 36
    var paused = false
    var running = false
    var tint: Color = .orange
    var height: CGFloat = 22

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !running || paused)) { timeline in
            let filled = Int((min(max(value, 0), 1) * Double(count)).rounded(.down))
            let pulse = (sin(timeline.date.timeIntervalSinceReferenceDate * 5) + 1) / 2
            HStack(spacing: 3) {
                ForEach(0..<count, id: \.self) { i in
                    Capsule()
                        .fill(color(i, filled: filled, pulse: pulse))
                        .frame(height: height)
                }
            }
        }
        .animation(.easeOut(duration: 0.25), value: Int(value * Double(count)))
    }

    private func color(_ i: Int, filled: Int, pulse: Double) -> Color {
        let active = paused ? Color.yellow : tint
        if i < filled { return active }
        if i == filled && running { return active.opacity(0.35 + 0.5 * pulse) }
        let distance = Double(i - filled)
        return Color.white.opacity(max(0.07, 0.5 - distance * 0.09))
    }
}

/// Ruler-style quality picker: drag along the ticks, tap a preset name, or reset to Balanced.
struct QualityRuler: View {
    @Binding var value: Int
    private let ticks = 25
    private let presets: [(String, Int)] = [("Smaller", 20), ("Balanced", 50), ("Better", 80)]

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                ForEach(presets, id: \.0) { name, target in
                    let selected = CompressModel.qualityName(value).hasPrefix(name)
                    Text(name)
                        .font(.callout.weight(selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Color.accentColor : .secondary)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation(.spring(response: 0.3)) { value = target } }
                }
            }
            HStack(spacing: 12) {
                Text("\(value)")
                    .font(.system(size: 22, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 38, alignment: .leading)
                    .contentTransition(.numericText(value: Double(value)))
                GeometryReader { geo in
                    let width = geo.size.width
                    let x = width * CGFloat(value) / 100
                    ZStack(alignment: .leading) {
                        HStack(spacing: 0) {
                            ForEach(0...ticks, id: \.self) { i in
                                let position = Double(i) / Double(ticks) * 100
                                let major = i % 6 == 0
                                Capsule()
                                    .fill(position <= Double(value) ? Color.accentColor.opacity(0.85) : Color.white.opacity(0.28))
                                    .frame(width: major ? 2 : 1.5, height: position <= Double(value) ? (major ? 26 : 22) : (major ? 22 : 14))
                                if i < ticks { Spacer(minLength: 0) }
                            }
                        }
                        .frame(maxHeight: .infinity)
                        Capsule()
                            .fill(Color.accentColor)
                            .frame(width: 2.5, height: 40)
                            .shadow(color: Color.accentColor.opacity(0.7), radius: 4)
                            .offset(x: x - 1.25)
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                        value = Int((min(max(drag.location.x / width, 0), 1) * 100).rounded())
                    })
                }
                .frame(height: 40)
                Button {
                    withAnimation(.spring(response: 0.3)) { value = 50 }
                } label: {
                    Image(systemName: "arrow.counterclockwise").font(.body.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(value == 50 ? .tertiary : .secondary)
                .help("Reset to Balanced (the skill's defaults)")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Capsule().fill(Color.white.opacity(0.06)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5))
        }
    }
}

/// The dark rounded card used by Simple mode and the menu bar panel.
struct PanelCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 18).fill(Color.white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.white.opacity(0.07), lineWidth: 0.5))
    }
}

struct CapsLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased()).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(.secondary).tracking(0.8)
    }
}

/// White pill for the main call to action, dark capsule for secondary ones.
struct PanelButtonStyle: ButtonStyle {
    var primary = false
    var tint: Color? = nil

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .foregroundStyle(primary ? Color.black : (tint ?? Color.primary))
            .background(
                Capsule().fill(primary ? Color.white : Color.white.opacity(0.08))
            )
            .overlay(Capsule().strokeBorder(Color.white.opacity(primary ? 0 : 0.08), lineWidth: 0.5))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
