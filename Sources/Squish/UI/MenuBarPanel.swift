import SwiftUI

struct MenuBarLabel: View {
    let model: CompressModel

    var body: some View {
        if model.isRunning {
            HStack(spacing: 3) {
                Image(systemName: model.isPaused ? "pause.circle.fill" : "arrow.down.right.and.arrow.up.left.circle.fill")
                Text("\(Int((model.overallProgress * 100).rounded()))%").monospacedDigit()
            }
        } else {
            Image(systemName: "arrow.down.right.and.arrow.up.left.circle")
        }
    }
}

struct MenuBarPanel: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let model = state.compress
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                AppGlyph(size: 22)
                Text("Squish").font(.headline)
                Spacer()
                SettingsLink { Image(systemName: "gearshape") }.buttonStyle(.plain).foregroundStyle(.secondary)
            }

            QueueStatus(model: model)

            if !model.jobs.isEmpty {
                Divider().opacity(0.4)
                HStack {
                    stat("Done", "\(model.doneJobs.count)")
                    stat("Waiting", "\(model.pending.count)")
                    stat("Saved", Fmt.bytes(model.savedBytes))
                }
            }

            HStack(spacing: 8) {
                Button { NSApp.activate(ignoringOtherApps: true); model.add(Panels.chooseVideos()) } label: {
                    Label("Add videos", systemImage: "plus")
                }
                .buttonStyle(PanelButtonStyle())
                if model.isStopping {
                    StoppingIndicator().frame(maxWidth: .infinity)
                } else if model.isRunning {
                    Button { model.isPaused ? model.resume() : model.pause() } label: {
                        Image(systemName: model.isPaused ? "play.fill" : "pause.fill")
                    }
                    .buttonStyle(PanelButtonStyle())
                    .frame(width: 52)
                    Button { model.stop() } label: { Image(systemName: "stop.fill") }
                        .buttonStyle(PanelButtonStyle(tint: .red))
                        .frame(width: 52)
                } else {
                    Button { model.start() } label: { Label("Start", systemImage: "play.fill") }
                        .buttonStyle(PanelButtonStyle(primary: !model.pending.isEmpty))
                        .disabled(model.pending.isEmpty)
                }
            }

            Button {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            } label: { Text("Open Squish") }
            .buttonStyle(PanelButtonStyle())

            HStack {
                Spacer()
                Button("Quit Squish") { NSApp.terminate(nil) }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.callout, design: .monospaced))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
