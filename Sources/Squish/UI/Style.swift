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
    let start: () -> Void
    let togglePause: () -> Void
    let stop: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if isRunning {
                Button(action: togglePause) {
                    Label(isPaused ? "Resume" : "Pause", systemImage: isPaused ? "play.fill" : "pause.fill")
                        .contentTransition(.symbolEffect(.replace))
                }
                .glassButton()
                .keyboardShortcut(.space, modifiers: [])
                Button(role: .destructive, action: stop) { Label("Stop", systemImage: "stop.fill") }
                    .glassButton()
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
                .transition(.opacity.combined(with: .move(edge: .top)))
                .dropDestination(for: URL.self) { urls, _ in
                    guard let url = urls.first, url.hasDirectoryPath else { return false }
                    outputFolder = url.path
                    return true
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: outputMode)
    }
}
