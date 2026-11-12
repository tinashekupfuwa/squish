import AppKit
import SwiftUI

struct SquishApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var state = AppState()

    var body: some Scene {
        WindowGroup("Squish") {
            ContentView()
                .environment(state)
                .frame(minWidth: 1060, minHeight: 700)
        }
        .commands { CommandGroup(replacing: .newItem) {} }
        Settings { SettingsView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case compress, compare, audit, optimize
    var id: String { rawValue }
    var title: String {
        switch self {
        case .compress: return "Compress"
        case .compare: return "Compare quality"
        case .audit: return "Audit"
        case .optimize: return "Scan & optimize"
        }
    }
    var subtitle: String {
        switch self {
        case .compress: return "Optimize video files"
        case .compare: return "CRF vs. size table"
        case .audit: return "Folder or URL report"
        case .optimize: return "Fix a whole project"
        }
    }
    var symbol: String {
        switch self {
        case .compress: return "arrow.down.right.and.arrow.up.left"
        case .compare: return "square.split.2x1"
        case .audit: return "doc.text.magnifyingglass"
        case .optimize: return "wand.and.stars"
        }
    }
}

@Observable @MainActor
final class AppState {
    var section: AppSection? = .compress
    let compress = CompressModel()
    let compare = CompareModel()
    let audit = AuditModel()
    let optimize = OptimizeModel()
}

struct ContentView: View {
    @Environment(AppState.self) private var state
    @State private var toolsFound = Tools.locate("ffmpeg") != nil && Tools.locate("ffprobe") != nil

    var body: some View {
        @Bindable var state = state
        NavigationSplitView {
            List(selection: $state.section) {
                ForEach(AppSection.allCases) { section in
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(section.title)
                            Text(section.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: section.symbol)
                    }
                    .padding(.vertical, 3)
                    .tag(section)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        } detail: {
            VStack(spacing: 0) {
                if !toolsFound {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("FFmpeg and FFprobe are required. Install them with `brew install ffmpeg`, or set their paths in Settings.")
                        Spacer()
                        Button("Check again") { toolsFound = Tools.locate("ffmpeg") != nil && Tools.locate("ffprobe") != nil }
                    }
                    .padding(10)
                    .background(.orange.opacity(0.12))
                }
                switch state.section ?? .compress {
                case .compress: CompressView(model: state.compress)
                case .compare: CompareView(model: state.compare, compress: state.compress, select: { state.section = $0 })
                case .audit: AuditView(model: state.audit, optimize: state.optimize, select: { state.section = $0 })
                case .optimize: OptimizeView(model: state.optimize)
                }
            }
            .navigationTitle((state.section ?? .compress).title)
        }
    }
}

struct SettingsView: View {
    @AppStorage("ffmpegPath") private var ffmpegPath = ""
    @AppStorage("ffprobePath") private var ffprobePath = ""
    @AppStorage("outputMode") private var outputMode = "source"
    @AppStorage("outputFolder") private var outputFolder = ""

    var body: some View {
        Form {
            Section("Tools") {
                TextField("ffmpeg", text: $ffmpegPath, prompt: Text(Tools.locate("ffmpeg") ?? "not found"))
                TextField("ffprobe", text: $ffprobePath, prompt: Text(Tools.locate("ffprobe") ?? "not found"))
                Text("Leave empty to use Homebrew's /opt/homebrew/bin or /usr/local/bin.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Compressed files and comparisons") {
                Picker("Save to", selection: $outputMode) {
                    Text("Next to the source video").tag("source")
                    Text("A folder I choose").tag("custom")
                }
                if outputMode == "custom" {
                    HStack {
                        Text(outputFolder.isEmpty ? "No folder chosen" : outputFolder).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Choose…") { if let url = Panels.chooseFolder() { outputFolder = url.path } }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .padding()
    }
}
