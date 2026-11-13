import AppKit
import Foundation

enum Fmt {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    /// Formats a set of sizes in one shared unit so they compare at a glance.
    static func bytes(_ value: Int64, sharedWith all: [Int64]) -> String {
        let largest = all.max() ?? value
        if largest >= 1_000_000 { return String(format: "%.2f MB", Double(value) / 1_000_000) }
        return String(format: "%.0f KB", Double(value) / 1_000)
    }

    static func savings(from original: Int64, to new: Int64) -> String {
        guard original > 0 else { return "–" }
        let ratio = 1 - Double(new) / Double(original)
        return String(format: ratio >= 0 ? "%.1f%% smaller" : "%.1f%% larger", abs(ratio) * 100)
    }

    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0s" }
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        let total = Int(seconds.rounded())
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60) : String(format: "%d:%02d", total / 60, total % 60)
    }

    static func bitrate(_ bps: Int64) -> String {
        bps >= 1_000_000 ? String(format: "%.1f Mbps", Double(bps) / 1_000_000) : String(format: "%.0f kbps", Double(bps) / 1_000)
    }

    /// ffmpeg speed as a multiple of real time, e.g. "2.4× real time".
    static func speed(_ x: Double) -> String {
        String(format: x < 1 ? "%.2f× real time" : x < 10 ? "%.1f× real time" : "%.0f× real time", x)
    }

    static func dB(_ value: Double) -> String {
        value.isFinite ? String(format: "%.1f dBFS", value) : "-inf dBFS"
    }

    static func markdownLink(_ title: String, _ url: URL) -> String {
        let path = url.path
        return path.contains(" ") ? "[\(title)](<\(path)>)" : "[\(title)](\(path))"
    }
}

enum OutputLocation {
    static var usesCustomFolder: Bool { UserDefaults.standard.string(forKey: "outputMode") == "custom" }
    static var customFolder: String { UserDefaults.standard.string(forKey: "outputFolder") ?? "" }

    static func directory(for input: URL) throws -> URL {
        let fm = FileManager.default
        if usesCustomFolder, customFolder.isEmpty {
            throw ToolError.message("Choose a destination folder, or switch Save to back to “Next to each source”.")
        }
        if usesCustomFolder {
            let url = URL(fileURLWithPath: customFolder, isDirectory: true)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        let sibling = input.deletingLastPathComponent()
        if fm.isWritableFile(atPath: sibling.path) { return sibling }
        let fallback = fm.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("Squish", isDirectory: true)
        try fm.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }

    static func unique(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let dir = url.deletingLastPathComponent()
        var n = 2
        while true {
            let candidate = dir.appendingPathComponent(ext.isEmpty ? "\(base)-\(n)" : "\(base)-\(n).\(ext)")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }
}

enum Finder {
    static func reveal(_ urls: [URL]) { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    static func open(_ url: URL) { NSWorkspace.shared.open(url) }
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

extension URL {
    func relativePath(from base: URL) -> String {
        let basePath = base.standardizedFileURL.path
        let path = standardizedFileURL.path
        if path.hasPrefix(basePath + "/") { return String(path.dropFirst(basePath.count + 1)) }
        return path
    }

    var fileSize: Int64 {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
    }
}
