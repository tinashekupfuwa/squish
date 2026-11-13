import AppKit
import SwiftUI

/// The app's corner radii: cards and panels, rows and controls inside them, and small insets. Pills use Capsule.
enum Radius {
    static let card: CGFloat = 16
    static let row: CGFloat = 12
    static let small: CGFloat = 8
}

enum Brand {
    static let teal = Color(red: 0.11, green: 0.71, blue: 0.67)
    static let indigo = Color(red: 0.38, green: 0.33, blue: 0.90)
    static let lightPurple = Color(red: 0.78, green: 0.69, blue: 1.00)
    static let darkPurple = Color(red: 0.36, green: 0.13, blue: 0.70)
    static let amber = Color(red: 0.96, green: 0.68, blue: 0.16)
    static let orange = Color(red: 0.98, green: 0.55, blue: 0.18)
    /// Neutral in-progress status text: #666666 on light (4.6:1 on cards), #A3A3A3 on dark (4.9:1).
    static let statusGrey = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0xA3 / 255, green: 0xA3 / 255, blue: 0xA3 / 255, alpha: 1)
            : NSColor(srgbRed: 0x66 / 255, green: 0x66 / 255, blue: 0x66 / 255, alpha: 1)
    })
    static let green = Color(red: 0.20, green: 0.74, blue: 0.42)

    /// Linear blend between two colors in sRGB, t in 0...1.
    static func mix(_ a: Color, _ b: Color, _ t: Double) -> Color {
        guard let ca = NSColor(a).usingColorSpace(.sRGB), let cb = NSColor(b).usingColorSpace(.sRGB) else { return a }
        let t = CGFloat(min(max(t, 0), 1))
        return Color(.sRGB,
                     red: Double(ca.redComponent + (cb.redComponent - ca.redComponent) * t),
                     green: Double(ca.greenComponent + (cb.greenComponent - ca.greenComponent) * t),
                     blue: Double(ca.blueComponent + (cb.blueComponent - ca.blueComponent) * t))
    }
}

extension View {
    /// A quiet card surface that keeps text contrast in light and dark appearance.
    func surfaceCard(cornerRadius: CGFloat = Radius.card, tint: Color? = nil) -> some View {
        background {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(tint.map { $0.opacity(0.08) } ?? Color.primary.opacity(0.04))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder((tint ?? Color.primary).opacity(tint == nil ? 0.08 : 0.25), lineWidth: 0.75))
        }
    }

    @ViewBuilder
    func controlButton(prominent: Bool = false) -> some View {
        if prominent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
    }

    func clearFormBackground() -> some View { formStyle(.grouped).controlSize(.small).font(.callout) }
}

extension AnyTransition {
    static var card: AnyTransition { .opacity }
}

/// Rounded ticks that fill from the left in the tint color. Amber while paused or stopping, green when done.
struct TickBar: View {
    var value: Double
    var paused = false
    var running = false
    var done = false
    var tint: Color = Brand.green
    var tickWidth: CGFloat = 6
    var spacing: CGFloat = 3.5
    var height: CGFloat = 22
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let count = max(8, Int((geo.size.width + spacing) / (tickWidth + spacing)))
            let filled = Int((min(max(value, 0), 1) * Double(count)).rounded(.down))
            TimelineView(.animation(minimumInterval: 1 / 30, paused: !running || paused || reduceMotion)) { timeline in
                let pulse = reduceMotion ? 0.6 : (sin(timeline.date.timeIntervalSinceReferenceDate * 4) + 1) / 2
                HStack(spacing: 0) {
                    ForEach(0..<count, id: \.self) { i in
                        Capsule()
                            .fill(color(i, count: count, filled: filled, pulse: pulse))
                            .frame(width: tickWidth, height: height)
                        if i < count - 1 { Spacer(minLength: 0) }
                    }
                }
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
    }

    private func color(_ i: Int, count: Int, filled: Int, pulse: Double) -> Color {
        let fill: Color = paused ? Brand.amber : done ? Brand.green : tint
        if i < filled { return fill }
        if i == filled && running && !paused { return fill.opacity(0.3 + 0.55 * pulse) }
        guard running || value > 0 else { return Color.primary.opacity(0.08) }
        let distance = Double(i - filled)
        return Color.primary.opacity(max(0.1, 0.42 - distance * 0.08))
    }
}

/// One segment per video in the queue, each filling with that video's progress. A single video is one solid bar.
struct SegmentedProgressBar: View {
    var segments: [Double]
    var active: Int?
    var failed: Set<Int> = []
    var paused = false
    var done = false
    var tint: Color = Brand.green
    var height: CGFloat = 14
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let count = max(segments.count, 1)
            let spacing = min(5, geo.size.width / CGFloat(count) * 0.25)
            let width = (geo.size.width - spacing * CGFloat(count - 1)) / CGFloat(count)
            TimelineView(.animation(minimumInterval: 1 / 30, paused: active == nil || paused || reduceMotion)) { timeline in
                let pulse = reduceMotion ? 0.6 : (sin(timeline.date.timeIntervalSinceReferenceDate * 4) + 1) / 2
                HStack(spacing: spacing) {
                    ForEach(0..<count, id: \.self) { i in
                        segment(i, width: width, pulse: pulse)
                    }
                }
            }
        }
        .frame(height: height)
        .animation(.easeInOut(duration: 0.25), value: segments)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue("\(segments.filter { $0 >= 1 }.count) of \(segments.count) videos done")
    }

    private func segment(_ i: Int, width: CGFloat, pulse: Double) -> some View {
        let value = i < segments.count ? min(max(segments[i], 0), 1) : 0
        let fill: Color = failed.contains(i) ? .red : paused ? Brand.amber : done ? Brand.green : tint
        let isActive = i == active && !paused
        return ZStack(alignment: .leading) {
            Capsule().fill(isActive ? fill.opacity(0.18 + 0.2 * pulse) : Color.primary.opacity(0.1))
            Capsule()
                .fill(fill)
                .frame(width: max(value > 0 ? height : 0, width * value))
                .shadow(color: fill.opacity(isActive ? 0.35 + 0.45 * pulse : 0), radius: 5)
                .opacity(failed.contains(i) ? 0.5 : 1)
        }
        .frame(width: width, height: height)
    }
}

/// The same meter, smaller and with thinner ticks, for a single converting video.
struct MiniTickBar: View {
    var value: Double
    var paused = false
    var height: CGFloat = 10
    var tint: Color = Brand.orange

    var body: some View {
        TickBar(value: value, paused: paused, running: value < 1, tint: tint, tickWidth: 2.5, spacing: 2.5, height: max(height, 8))
    }
}

/// Start / Pause / Resume / Stop for a running workflow.
struct TransportControls: View {
    let isRunning: Bool
    let isPaused: Bool
    let canStart: Bool
    let startTitle: String
    var compact = false
    var isStopping = false
    let start: () -> Void
    let togglePause: () -> Void
    let stop: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if isStopping {
                StoppingIndicator()
            } else if isRunning {
                Button(action: togglePause) {
                    Label(isPaused ? "Resume" : "Pause", systemImage: isPaused ? "play.fill" : "pause.fill")
                        .labelStyle(compact ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleAndIcon))
                        .frame(minWidth: compact ? 20 : nil)
                }
                .controlButton()
                .help(isPaused ? "Resume (Space)" : "Pause (Space)")
                .keyboardShortcut(.space, modifiers: [])
                Button(role: .destructive, action: stop) {
                    Label("Stop", systemImage: "stop.fill")
                        .labelStyle(compact ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleAndIcon))
                        .frame(minWidth: compact ? 20 : nil)
                }
                .controlButton()
                .help("Stop (⌘.)")
                .keyboardShortcut(".", modifiers: .command)
            } else {
                Button(action: start) { Label(startTitle, systemImage: "play.fill") }
                    .controlButton(prominent: true)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canStart)
            }
        }
        .controlSize(.large)
    }
}

/// Shown the moment Stop is pressed, until the encoder has shut down.
struct StoppingIndicator: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Stopping…").font(.body.weight(.semibold))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .foregroundStyle(.red)
        .background(Capsule().fill(Color.red.opacity(0.12)))
        .accessibilityLabel("Stopping")
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
        Section("Output folder") {
            Picker("Save to", selection: $outputMode) {
                Text("Same folder as each original").tag("source")
                Text("A folder I choose").tag("custom")
            }
            if outputMode == "custom" {
                HStack {
                    Image(systemName: "folder.fill").foregroundStyle(Brand.indigo)
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
    @Environment(\.colorScheme) private var scheme

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
                            Capsule()
                                .fill(scheme == .dark ? Color.white.opacity(0.16) : Color.white)
                                .shadow(color: .black.opacity(scheme == .dark ? 0.3 : 0.12), radius: 2, y: 1)
                                .matchedGeometryEffect(id: "thumb", in: thumb)
                        }
                    }
                    .contentShape(Capsule())
                    .onTapGesture {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { selection = value }
                    }
                    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.primary.opacity(scheme == .dark ? 0.08 : 0.07)))
    }
}

/// Compression ruler. Light purple on the left is light compression; deep purple on the right is the strongest.
/// The binding is the encoder quality (0 = smallest files, 100 = best quality); the ruler shows compression = 100 - quality.
struct QualityRuler: View {
    @Binding var quality: Int
    @State private var lastTick = -1
    @Environment(\.colorScheme) private var scheme
    private let ticks = 28
    private let presets: [(String, Int)] = [("Light", 20), ("Balanced", 50), ("Strong", 80)]

    private var compression: Int { 100 - quality }

    static func color(at compression: Double) -> Color {
        Brand.mix(Brand.lightPurple, Brand.darkPurple, compression / 100)
    }

    /// Same hue family, kept dark enough to read as text on light and dark backgrounds.
    static func textColor(at compression: Double, dark: Bool = false) -> Color {
        dark ? Brand.mix(Brand.lightPurple, Brand.darkPurple, 0.1 + compression / 330)
             : Brand.mix(Brand.lightPurple, Brand.darkPurple, 0.55 + compression / 250)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ForEach(presets, id: \.0) { name, target in
                    let selected = presetName == name
                    Button {
                        withAnimation(.spring(response: 0.3)) { quality = 100 - target }
                    } label: {
                        Text(name)
                            .font(.callout.weight(selected ? .semibold : .regular))
                            .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                            .frame(maxWidth: .infinity)
                            .animation(.easeOut(duration: 0.2), value: selected)
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(alignment: .top, spacing: 12) {
                Text("\(compression)")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Self.textColor(at: Double(compression), dark: scheme == .dark))
                    .lineLimit(1)
                    .fixedSize()
                    .frame(width: 64, height: 40, alignment: .leading)
                    .contentTransition(.numericText(value: Double(compression)))
                GeometryReader { geo in
                    let width = geo.size.width
                    let x = width * CGFloat(compression) / 100
                    ZStack(alignment: .topLeading) {
                        HStack(spacing: 0) {
                            ForEach(0...ticks, id: \.self) { i in
                                let position = Double(i) / Double(ticks) * 100
                                let active = position <= Double(compression)
                                let major = i % 7 == 0
                                Capsule()
                                    .fill(active ? Self.color(at: position) : Color.primary.opacity(0.22))
                                    .frame(width: major ? 2.5 : 2, height: active ? (major ? 26 : 22) : (major ? 20 : 13))
                                if i < ticks { Spacer(minLength: 0) }
                            }
                        }
                        .frame(height: 40)
                        Capsule()
                            .fill(Self.color(at: Double(compression)))
                            .frame(width: 3, height: 40)
                            .shadow(color: Self.color(at: Double(compression)).opacity(0.6), radius: 4)
                            .offset(x: x - 1.5)
                        ForEach([0, 25, 50, 75, 100], id: \.self) { mark in
                            let near = abs(compression - mark) <= 4
                            Text("\(mark)")
                                .font(.system(size: 10, weight: near ? .bold : .medium, design: .monospaced))
                                .foregroundStyle(near ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                                .fixedSize()
                                .position(x: width * CGFloat(mark) / 100, y: 50)
                        }
                    }
                    .animation(.spring(response: 0.28, dampingFraction: 0.82), value: compression)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                        let c = Int((min(max(drag.location.x / width, 0), 1) * 100).rounded())
                        quality = 100 - c
                    })
                }
                .frame(height: 56)
                Button {
                    withAnimation(.spring(response: 0.3)) { quality = 50 }
                } label: {
                    Image(systemName: "arrow.counterclockwise").font(.body.weight(.semibold))
                        .frame(height: 40)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .opacity(quality == 50 ? 0.5 : 1)
                .help("Reset to Balanced")
                .accessibilityLabel("Reset to Balanced")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: Radius.card).fill(Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Compression")
            .accessibilityValue("\(compression), \(presetName)")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: quality = max(0, quality - 5)
                case .decrement: quality = min(100, quality + 5)
                @unknown default: break
                }
            }
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .contentTransition(.opacity)
                .animation(.easeOut(duration: 0.2), value: presetName)
        }
        .onChange(of: compression) { old, new in
            let tick = Int((Double(new) / 100 * Double(ticks)).rounded())
            let crossedPreset = presets.contains { (min(old, new)...max(old, new)).contains($0.1) && old != $0.1 } || new == 0 || new == 100
            if crossedPreset {
                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            } else if tick != lastTick {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
            lastTick = tick
        }
    }

    private var presetName: String {
        compression < 35 ? "Light" : compression <= 65 ? "Balanced" : "Strong"
    }

    private var caption: String {
        switch presetName {
        case "Light": return "Bigger files that look the same as the original."
        case "Balanced": return "Much smaller files with no visible quality loss. Recommended."
        default: return "Smallest files. Fine detail may look softer."
        }
    }
}

struct PanelCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surfaceCard()
    }
}

struct CapsLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased()).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary).tracking(0.8)
    }
}

/// High-contrast pill for the main action, quiet capsule for secondary ones. Adapts to light and dark.
struct PanelButtonStyle: ButtonStyle {
    var primary = false
    var tint: Color? = nil
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .foregroundStyle(primary ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor)) : AnyShapeStyle(tint ?? Color.primary))
            .background(Capsule().fill(primary ? Color.primary.opacity(0.9) : Color.primary.opacity(0.07)))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(primary ? 0 : 0.1), lineWidth: 0.75))
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Pick a built-in or saved preset, save the current settings as a preset, or delete one of yours.
struct PresetMenu: View {
    @Bindable var model: CompressModel
    var compact = false
    @State private var naming = false
    @State private var name = ""

    var body: some View {
        Menu {
            Section("Built-in") {
                ForEach(EncodePreset.builtIns) { preset in item(preset) }
            }
            if !model.userPresets.isEmpty {
                Section("Your presets") {
                    ForEach(model.userPresets) { preset in item(preset) }
                }
            }
            Divider()
            Button("Save Current Settings as Preset…") {
                name = model.activePreset.map { $0.builtIn ? "" : $0.name } ?? ""
                naming = true
            }
            if !model.userPresets.isEmpty {
                Menu("Delete Preset") {
                    ForEach(model.userPresets) { preset in
                        Button(preset.name, role: .destructive) { model.deletePreset(preset) }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                if !compact { Image(systemName: "slider.horizontal.3").foregroundStyle(.secondary) }
                Text(model.activePreset?.name ?? "Presets")
                    .font(compact ? .caption.weight(.semibold) : .callout)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, compact ? 10 : 0)
            .padding(.vertical, compact ? 4 : 0)
            .background { if compact { Capsule().fill(Color.primary.opacity(0.07)) } }
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(model.activePreset.map { "\($0.name): \($0.detail)" } ?? "Your settings don't match a preset. Save them to reuse later.")
        .alert("Save preset", isPresented: $naming) {
            TextField("Preset name", text: $name)
            Button("Save") { model.savePreset(named: name) }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves the formats, compression, audio, frame rate, size, and speed (\(model.presetSummary)). Saving with an existing name replaces it.")
        }
    }

    @ViewBuilder
    private func item(_ preset: EncodePreset) -> some View {
        Button { model.apply(preset) } label: {
            if model.activePreset?.id == preset.id {
                Label("\(preset.name) — \(preset.detail)", systemImage: "checkmark")
            } else {
                Text("\(preset.name) — \(preset.detail)")
            }
        }
    }
}
