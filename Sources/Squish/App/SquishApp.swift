import AppKit
import SwiftUI

struct SquishApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var state = AppState.shared
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true

    var body: some Scene {
        WindowGroup("Squish", id: "main") {
            RootView()
                .environment(state)
                .tint(Brand.indigo)
        }
        .windowResizability(.contentSize)
        .windowToolbarStyle(.unified(showsTitle: false))
        .handlesExternalEvents(matching: [])
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Videos…") { state.compress.add(Panels.chooseVideos()) }.keyboardShortcut("o")
            }
            CommandGroup(after: .sidebar) {
                Button("Simple Mode") { UserDefaults.standard.set("simple", forKey: "uiMode") }.keyboardShortcut("1", modifiers: [.command, .option])
                Button("Advanced Mode") { UserDefaults.standard.set("advanced", forKey: "uiMode") }.keyboardShortcut("2", modifiers: [.command, .option])
            }
        }

        MenuBarExtra(isInserted: $showMenuBarIcon) {
            MenuBarPanel()
                .environment(state)
                .tint(Brand.indigo)
        } label: {
            MenuBarLabel(model: state.compress)
        }
        .menuBarExtraStyle(.window)

        Settings { SettingsView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Keep running in the menu bar after the window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Files dropped on the Dock icon or opened with Squish join the queue.
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { AppState.shared.receive(urls, fromWindow: false) }
    }
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
    static let shared = AppState()

    var section: AppSection? = .compress
    let compress = CompressModel()
    let compare = CompareModel()
    let audit = AuditModel()
    let optimize = OptimizeModel()

    /// Routes dropped or opened files: the compare screen takes one video, everything else queues for compression.
    func receive(_ urls: [URL], fromWindow: Bool) {
        let advanced = UserDefaults.standard.string(forKey: "uiMode") == "advanced"
        if advanced, fromWindow, section == .compare, let first = urls.first(where: { CompressModel.videoExtensions.contains($0.pathExtension.lowercased()) }) {
            compare.setInput(first)
            return
        }
        compress.add(urls)
        if advanced, section != .compress { section = .compress }
    }
}

struct RootView: View {
    @Environment(AppState.self) private var state
    @AppStorage("uiMode") private var mode = "simple"
    @State private var dropTargeted = false

    var body: some View {
        Group {
            if mode == "advanced" {
                ContentView()
                    .frame(width: AppSize.advanced.width, height: AppSize.advanced.height)
            } else {
                SimpleView(model: state.compress)
                    .frame(width: AppSize.simple.width, height: AppSize.simple.height)
            }
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: Radius.card)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, dash: [8, 6]))
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: Radius.card))
                    .overlay {
                        Label("Drop to add videos", systemImage: "plus.circle.fill")
                            .font(.title3.weight(.semibold))
                            .padding(.horizontal, 18).padding(.vertical, 10)
                            .background(Capsule().fill(.regularMaterial))
                    }
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            state.receive(urls, fromWindow: true)
            return !urls.isEmpty
        } isTargeted: { dropTargeted = $0 }
        .onChange(of: mode) { _, newMode in
            WindowSizer.resize(to: newMode == "advanced" ? AppSize.advanced : AppSize.simple)
        }
    }
}

enum AppSize {
    static let simple = NSSize(width: 380, height: 680)
    static let advanced = NSSize(width: 940, height: 600)
}

enum WindowSizer {
    @MainActor static func resize(to size: NSSize) {
        DispatchQueue.main.async {
            guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible }) ?? NSApp.mainWindow else { return }
            let content = window.contentRect(forFrameRect: window.frame)
            let frameSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: size)).size
            var frame = window.frame
            frame.origin.y += frame.height - frameSize.height
            frame.size = frameSize
            _ = content
            window.setFrame(frame, display: true, animate: true)
        }
    }
}

struct ModeSwitch: View {
    var width: CGFloat = 170
    @AppStorage("uiMode") private var mode = "simple"

    var body: some View {
        PillSegmented(options: [("simple", "Simple"), ("advanced", "Advanced")], selection: $mode)
            .frame(width: width)
            .help("Simple shows only what you need. Advanced shows every option.")
    }
}

struct ContentView: View {
    @Environment(AppState.self) private var state
    @State private var toolsFound = Tools.locate("ffmpeg") != nil && Tools.locate("ffprobe") != nil

    var body: some View {
        @Bindable var state = state
        NavigationSplitView(columnVisibility: .constant(.all)) {
            Sidebar(section: $state.section)
                .toolbar(removing: .sidebarToggle)
                .navigationSplitViewColumnWidth(200)
        } detail: {
            VStack(spacing: 0) {
                if !toolsFound {
                    MissingToolsBanner { toolsFound = Tools.locate("ffmpeg") != nil && Tools.locate("ffprobe") != nil }
                }
                switch state.section ?? .compress {
                case .compress: CompressView(model: state.compress)
                case .compare: CompareView(model: state.compare, compress: state.compress, select: { state.section = $0 })
                case .audit: AuditView(model: state.audit, optimize: state.optimize, select: { state.section = $0 })
                case .optimize: OptimizeView(model: state.optimize)
                }
            }
            .transaction { $0.animation = nil }
            .navigationTitle((state.section ?? .compress).title)
            .toolbar(.visible, for: .windowToolbar)
        }
    }
}

/// Compact navigation: app name, two labelled groups of single-line rows, and the mode switch at the bottom.
struct Sidebar: View {
    @Binding var section: AppSection?
    @State private var hovered: AppSection?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                AppGlyph(size: 20)
                Text("Squish").font(.system(size: 13, weight: .semibold))
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 16)
            group("Videos", [.compress, .compare])
            group("Projects", [.audit, .optimize])
            Spacer(minLength: 0)
            ModeSwitch(width: 176)
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func group(_ title: String, _ sections: [AppSection]) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
            ForEach(sections) { row($0) }
        }
        .padding(.bottom, 16)
    }

    private func row(_ item: AppSection) -> some View {
        let selected = (section ?? .compress) == item
        let index = AppSection.allCases.firstIndex(of: item)! + 1
        return Button { section = item } label: {
            HStack(spacing: 8) {
                Image(systemName: item.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(selected ? AnyShapeStyle(Brand.indigo) : AnyShapeStyle(.secondary))
                    .frame(width: 16)
                Text(item.title)
                    .font(.system(size: 13, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.primary.opacity(0.78)))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: Radius.small)
                    .fill(Color.primary.opacity(selected ? 0.08 : hovered == item ? 0.04 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? item : (hovered == item ? nil : hovered) }
        .keyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: .command)
        .help("\(item.subtitle)  ⌘\(index)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct MissingToolsBanner: View {
    let recheck: () -> Void
    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("FFmpeg is required. Install it with `brew install ffmpeg`, or set its path in Settings.").font(.callout)
            Spacer()
            Button("Check again", action: recheck)
        }
        .padding(10)
        .background(.orange.opacity(0.12))
    }
}

struct SettingsView: View {
    @AppStorage("ffmpegPath") private var ffmpegPath = ""
    @AppStorage("ffprobePath") private var ffprobePath = ""
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true

    var body: some View {
        Form {
            Section("General") {
                Toggle("Show Squish in the menu bar", isOn: $showMenuBarIcon)
            }
            DestinationSection()
            Section("Tools") {
                TextField("ffmpeg", text: $ffmpegPath, prompt: Text(Tools.locate("ffmpeg") ?? "not found"))
                TextField("ffprobe", text: $ffprobePath, prompt: Text(Tools.locate("ffprobe") ?? "not found"))
                Text("Leave empty to use Homebrew's /opt/homebrew/bin or /usr/local/bin.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding()
    }
}
