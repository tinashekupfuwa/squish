import AppKit
import WebKit

struct Viewport: Hashable, Sendable, Identifiable {
    let name: String
    let width: Int
    let height: Int
    var id: String { name }

    static let defaults = [
        Viewport(name: "Mobile", width: 390, height: 844),
        Viewport(name: "Tablet", width: 768, height: 1024),
        Viewport(name: "Laptop", width: 1440, height: 900),
        Viewport(name: "Desktop", width: 1920, height: 1080),
    ]
}

struct RenderedVideo: Codable, Hashable, Sendable {
    let currentSrc: String
    let sources: [String]
    let w: Double
    let h: Double
    let top: Double
    let vw: Int
    let vh: Int
    let fit: String
    let visible: Bool
    let autoplay: Bool
    let muted: Bool
    let loop: Bool
    let controls: Bool
    let playsinline: Bool
    let preload: String?
    let poster: Bool
    let readyState: Int
    let error: Int
}

struct PageSnapshot: Codable, Sendable {
    let url: String
    let title: String
    let videos: [RenderedVideo]
    let links: [String]
    let embeds: [String]
}

@MainActor
final class PageRenderer: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private let window: NSWindow
    private var pending: CheckedContinuation<Void, Error>?

    override init() {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1440, height: 900), configuration: config)
        window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 1440, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        super.init()
        webView.navigationDelegate = self
        window.orderBack(nil)
    }

    func close() {
        webView.stopLoading()
        window.orderOut(nil)
    }

    func render(_ url: URL, viewport: Viewport, scroll: Bool = true) async throws -> PageSnapshot {
        window.setContentSize(NSSize(width: viewport.width, height: viewport.height))
        webView.frame = NSRect(x: 0, y: 0, width: viewport.width, height: viewport.height)
        try await load(url)
        try await Task.sleep(nanoseconds: 600_000_000)
        if scroll {
            let height = (try? await evaluate("Math.max(document.documentElement.scrollHeight, document.body ? document.body.scrollHeight : 0)") as? Double) ?? 0
            var y = 0.0
            var steps = 0
            while y < height && steps < 40 {
                y += Double(viewport.height) * 0.8
                steps += 1
                _ = try? await evaluate("window.scrollTo(0, \(Int(y))); 0")
                try await Task.sleep(nanoseconds: 250_000_000)
            }
            _ = try? await evaluate("window.scrollTo(0, 0); 0")
            try await Task.sleep(nanoseconds: 800_000_000)
        }
        guard let json = try await evaluate(Self.collectScript) as? String, let data = json.data(using: .utf8) else {
            throw ToolError.message("Could not read videos from \(url.absoluteString).")
        }
        return try JSONDecoder().decode(PageSnapshot.self, from: data)
    }

    private func load(_ url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pending?.resume(throwing: CancellationError())
            pending = continuation
            webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 35_000_000_000)
                if let self, let pending = self.pending {
                    self.pending = nil
                    self.webView.stopLoading()
                    pending.resume(throwing: ToolError.message("Timed out loading \(url.absoluteString)."))
                }
            }
        }
    }

    private func evaluate(_ script: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
            webView.evaluateJavaScript(script) { value, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: value) }
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { finish(nil) }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { finish(error) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { finish(error) }
    }

    private func finish(_ error: Error?) {
        guard let pending else { return }
        self.pending = nil
        if let error { pending.resume(throwing: error) } else { pending.resume() }
    }

    static let collectScript = """
    (() => {
      const embedHosts = /youtube\\.com|youtu\\.be|vimeo\\.com|wistia|loom\\.com|mux\\.com|cloudflarestream|jwplayer|brightcove|vidyard/i;
      const videos = [...document.querySelectorAll('video')].map(v => {
        const r = v.getBoundingClientRect();
        const cs = getComputedStyle(v);
        const sources = [...v.querySelectorAll('source')].map(s => s.src).filter(Boolean);
        return {
          currentSrc: v.currentSrc || v.src || sources[0] || '',
          sources: v.src ? [v.src, ...sources] : sources,
          w: r.width, h: r.height, top: r.top + window.scrollY,
          vw: v.videoWidth || 0, vh: v.videoHeight || 0,
          fit: cs.objectFit || 'fill',
          visible: cs.display !== 'none' && cs.visibility !== 'hidden' && r.width > 0 && r.height > 0,
          autoplay: v.autoplay, muted: v.muted || v.hasAttribute('muted'), loop: v.loop, controls: v.controls,
          playsinline: v.hasAttribute('playsinline') || v.playsInline === true,
          preload: v.getAttribute('preload'), poster: !!v.getAttribute('poster'),
          readyState: v.readyState, error: v.error ? v.error.code : 0
        };
      });
      const links = [...document.querySelectorAll('a[href]')].map(a => a.href);
      const embeds = [...document.querySelectorAll('iframe[src]')].map(f => f.src).filter(s => embedHosts.test(s));
      return JSON.stringify({ url: location.href, title: document.title, videos, links, embeds });
    })()
    """
}
