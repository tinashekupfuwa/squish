import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum Panels {
    static let videoTypes: [UTType] = [.movie, .video, .mpeg4Movie, .quickTimeMovie, .avi, .mpeg2Video] + ["webm", "mkv", "ogv", "m4v"].compactMap { UTType(filenameExtension: $0) }

    @MainActor static func chooseVideos(multiple: Bool = true) -> [URL] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = multiple
        panel.canChooseDirectories = multiple
        panel.allowedContentTypes = videoTypes
        return panel.runModal() == .OK ? panel.urls : []
    }

    @MainActor static func chooseFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    @MainActor static func save(_ text: String, name: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        if panel.runModal() == .OK, let url = panel.url { try? text.write(to: url, atomically: true, encoding: .utf8) }
    }
}

struct DropZone: View {
    let title: String
    let subtitle: String
    let onDrop: ([URL]) -> Void
    let onChoose: () -> Void
    @State private var targeted = false

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: targeted ? "film.stack.fill" : "film.stack")
                .font(.system(size: 28))
                .foregroundStyle(targeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: targeted)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Choose…", action: onChoose).controlButton()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .surfaceCard(tint: targeted ? .accentColor : nil)
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                .foregroundStyle(targeted ? Color.accentColor : Color.secondary.opacity(0.35))
        )
        .scaleEffect(targeted ? 1.015 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: targeted)
        .dropDestination(for: URL.self) { urls, _ in
            onDrop(urls)
            return !urls.isEmpty
        } isTargeted: { targeted = $0 }
    }
}

struct FolderField: View {
    let label: String
    @Binding var url: URL?
    var optional = false

    var body: some View {
        LabeledContent(label) {
            HStack {
                Text(url?.path ?? (optional ? "Optional" : "None"))
                    .foregroundStyle(url == nil ? .secondary : .primary)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if url != nil, optional { Button { url = nil } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless) }
                Button("Choose…") { if let picked = Panels.chooseFolder() { url = picked } }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            url = urls.first
            return true
        }
    }
}

struct OptionalIntField: View {
    let label: String
    @Binding var value: Int?
    var prompt = "Source"

    var body: some View {
        LabeledContent(label) {
            TextField("", value: $value, format: .number, prompt: Text(prompt))
                .frame(width: 90)
                .multilineTextAlignment(.trailing)
        }
    }
}

struct CodecSettingsSection: View {
    @Binding var settings: EncodeSettings
    var showResize = true

    var body: some View {
        Section("Formats") {
            codecRow(.vp9, isOn: $settings.vp9)
            codecRow(.h265, isOn: $settings.h265)
            codecRow(.av1, isOn: $settings.av1)
        }
        Section("Options") {
            Picker("Audio", selection: $settings.audio) {
                ForEach(AudioMode.allCases) { Text($0.label).tag($0) }
            }
            Picker("Above 30 fps", selection: $settings.frameRate) {
                ForEach(FrameRateMode.allCases) { Text($0.label).tag($0) }
            }
            if showResize { OptionalIntField(label: "Max width (px)", value: $settings.maxWidth) }
            Toggle("10-bit output", isOn: $settings.tenBit)
                .help("Highest bit depth web players support. Keeps gradients smooth and preserves 10-bit and 12-bit sources as closely as possible.")
            Picker("Encoder speed", selection: $settings.speed) {
                ForEach(SpeedMode.allCases) { Text($0.label).tag($0) }
            }
        }
    }

    private func codecRow(_ codec: Codec, isOn: Binding<Bool>) -> some View {
        HStack {
            Toggle(codec.label, isOn: isOn)
            Spacer()
            Stepper(value: Binding(get: { settings.crf(for: codec) }, set: { settings.crf[codec] = $0 }), in: codec.crfRange) {
                Text("CRF \(settings.crf(for: codec))").monospacedDigit().foregroundStyle(isOn.wrappedValue ? .primary : .secondary)
            }
            .disabled(!isOn.wrappedValue)
        }
    }
}

struct LogView: View {
    let lines: [String]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Text(line).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).id(index)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .frame(minHeight: 70, maxHeight: 140)
            .surfaceCard(cornerRadius: Radius.row)
            .onChange(of: lines.count) { _, count in proxy.scrollTo(count - 1, anchor: .bottom) }
        }
    }
}

struct CodeBlock: View {
    let text: String

    var body: some View {
        HStack(alignment: .top) {
            Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            Button { Finder.copy(text) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).help("Copy")
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: Radius.small).fill(Color.secondary.opacity(0.08)))
    }
}

struct ErrorText: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "xmark.octagon.fill")
            .foregroundStyle(.red)
            .textSelection(.enabled)
            .font(.callout)
    }
}
