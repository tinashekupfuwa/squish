import AppKit
import SwiftUI

/// Renders the main screens with sample data to PNGs (`Squish snapshot <folder>`), for docs and visual checks.
@MainActor
enum Snapshots {
    static func render(to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let empty = AppState()
        let busy = AppState()
        fill(busy.compress)
        busy.compress.quality = 35
        let stopping = AppState()
        fill(stopping.compress)
        stopping.compress.isStopping = true
        stopping.compress.quality = 0
        let shots: [(String, AnyView, NSSize)] = [
            ("simple-empty", AnyView(SimpleView(model: empty.compress).environment(empty)), AppSize.simple),
            ("simple-running", AnyView(SimpleView(model: busy.compress).environment(busy)), AppSize.simple),
            ("simple-stopping", AnyView(SimpleView(model: stopping.compress).environment(stopping)), AppSize.simple),
            ("menubar", AnyView(MenuBarPanel().environment(busy)), NSSize(width: 320, height: 470)),
            ("advanced-compress", AnyView(CompressView(model: busy.compress).environment(busy)), NSSize(width: AppSize.advanced.width - 200, height: AppSize.advanced.height - 52)),
        ]
        for (base, view, size) in shots {
          for dark in [false, true] {
            let name = base + (dark ? "-dark" : "-light")
            let host = NSHostingView(rootView: view.tint(Brand.indigo).environment(\.colorScheme, dark ? .dark : .light).frame(width: size.width, height: size.height).background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            host.appearance = window.appearance
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("\(name).png"))
          }
        }
    }

    private static func fill(_ model: CompressModel) {
        func probe(_ name: String, _ w: Int, _ h: Int, _ bytes: Int64) -> ProbeInfo {
            ProbeInfo(source: name, bytes: bytes, duration: 12.4, codedWidth: w, codedHeight: h, rotation: 0, fps: Rational(30, 1), pixFmt: "yuv420p", videoCodec: "h264", profile: "", level: 0, bitRate: 0, audio: [])
        }
        let done = CompressJob(url: URL(fileURLWithPath: "/Movies/hero-loop.mov"))
        done.probe = probe("hero", 1920, 1080, 48_200_000)
        done.state = .done
        done.progress = 1
        let verification = Verification(probe: probe("out", 1920, 1080, 6_100_000), checks: [], issues: [])
        done.outputs = [
            EncodeOutput(codec: .vp9, crf: 42, url: URL(fileURLWithPath: "/Movies/hero-loop-vp9.webm"), bytes: 6_100_000, sourceBytes: 48_200_000, command: "", verification: verification),
            EncodeOutput(codec: .h265, crf: 30, url: URL(fileURLWithPath: "/Movies/hero-loop-h265.mp4"), bytes: 7_400_000, sourceBytes: 48_200_000, command: "", verification: verification),
        ]
        let running = CompressJob(url: URL(fileURLWithPath: "/Movies/product-demo.mp4"))
        running.probe = probe("demo", 3840, 2160, 210_000_000)
        running.state = .running
        running.status = "Encoding VP9 (1/2)…"
        running.progress = 0.46
        let waiting = CompressJob(url: URL(fileURLWithPath: "/Movies/team-intro.mov"))
        waiting.probe = probe("intro", 1280, 720, 22_000_000)
        model.jobs = [done, running, waiting]
        model.isRunning = true
    }
}
