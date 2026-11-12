import SwiftUI

struct SiteInputsSection: View {
    @Binding var options: AuditOptions
    var showPages = true

    var body: some View {
        Section("Website") {
            FolderField(label: "Source folder", url: $options.project, optional: true)
            TextField("Page URL", text: $options.startURL, prompt: Text("https://… or http://localhost:3000"))
            FolderField(label: "Originals", url: $options.originals, optional: true)
        }
        Section("Measurement") {
            Stepper(value: $options.density, in: 1...3, step: 0.5) { Text("Density: \(String(format: "%g", options.density))× per CSS px") }
            if showPages { Stepper(value: $options.maxPages, in: 1...50) { Text("Pages to crawl: \(options.maxPages)") } }
            ForEach(Viewport.defaults) { viewport in
                Toggle("\(viewport.name) \(viewport.width)×\(viewport.height)", isOn: Binding(
                    get: { options.viewports.contains(viewport) },
                    set: { on in
                        if on { options.viewports = Viewport.defaults.filter { options.viewports.contains($0) || $0 == viewport } }
                        else { options.viewports.removeAll { $0 == viewport } }
                    }))
            }
            OptionalIntField(label: "Fallback display width (CSS px)", value: $options.manualDisplayWidth, prompt: "None")
            Toggle("Analyze audio for silence", isOn: $options.analyzeAudio)
        }
    }
}

struct AuditView: View {
    @Bindable var model: AuditModel
    let optimize: OptimizeModel
    let select: (AppSection) -> Void

    var body: some View {
        HStack(spacing: 0) {
            Form { SiteInputsSection(options: $model.options) }
                .formStyle(.grouped)
                .frame(width: 360)
                .disabled(model.isRunning)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                if let report = model.report {
                    ReportView(report: report)
                } else if model.log.isEmpty && model.error == nil {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "doc.text.magnifyingglass").font(.system(size: 34)).foregroundStyle(.secondary)
                        Text("Audit a website's videos").font(.headline)
                        Text("Pick the source folder, a page URL, or both. Squish finds every video reference, renders the page at each layout to measure the largest displayed size, inspects each file, and recommends dimensions and fixes without changing anything.")
                            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 460)
                    }
                    .frame(maxWidth: .infinity)
                    Spacer()
                } else {
                    Spacer()
                }
                if let error = model.error { ErrorText(text: error) }
                if model.isRunning || model.report == nil, !model.log.isEmpty { LogView(lines: model.log) }
                HStack {
                    if let report = model.report {
                        Button("Copy Markdown") { Finder.copy(report.markdown) }
                        Button("Save report…") { Panels.save(report.markdown, name: "video-audit.md") }
                        if report.options.project != nil {
                            Button("Optimize this project →") {
                                optimize.options.audit = report.options
                                optimize.options.audit.maxPages = max(report.options.maxPages, optimize.options.audit.maxPages)
                                select(.optimize)
                            }
                        }
                    }
                    Spacer()
                    if model.isRunning { Button("Cancel", role: .cancel) { model.cancel() } }
                    Button(model.isRunning ? "Auditing…" : "Run audit") { model.start() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.isRunning || (model.options.project == nil && model.options.startURL.trimmingCharacters(in: .whitespaces).isEmpty))
                }
            }
            .padding()
        }
    }
}

struct ReportView: View {
    let report: AuditReport

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 28) {
                    stat("Videos in use", "\(report.videos.count)")
                    stat("Total size", Fmt.bytes(report.totalBytes))
                    stat("Measured", "\(report.videos.filter { $0.maxPictureWidth != nil }.count)")
                    stat("Findings", "\(report.videos.reduce(0) { $0 + $1.findings.count })")
                    stat("Unreferenced files", "\(report.unused.count)")
                }
                ForEach(report.videos) { VideoCard(video: $0) }
                if !report.unused.isEmpty {
                    group("Video files with no references found") {
                        ForEach(report.unused) { Text("\($0.key) · \(Fmt.bytes($0.bytes))").font(.callout) }
                    }
                }
                if !report.embeds.isEmpty || !report.unresolved.isEmpty {
                    group("Not re-encodable here") {
                        ForEach(report.embeds, id: \.self) { Text("Third-party player: \($0)").font(.callout) }
                        ForEach(report.unresolved, id: \.self) { Text($0).font(.callout) }
                    }
                }
                group("Coverage") {
                    if report.pages.isEmpty { Text("No pages rendered.").font(.callout) }
                    ForEach(report.pages, id: \.self) { Text($0).font(.callout) }
                    if !report.pages.isEmpty { Text("Layouts: " + report.options.viewports.map { "\($0.name) \($0.width) px" }.joined(separator: ", ")).font(.callout) }
                    ForEach(report.pageErrors, id: \.self) { Text("Failed: \($0)").font(.callout).foregroundStyle(.orange) }
                    ForEach(report.gaps, id: \.self) { Text("Gap: \($0)").font(.callout).foregroundStyle(.secondary) }
                }
            }
            .padding(.trailing, 6)
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading) {
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            content()
        }
    }
}

struct VideoCard: View {
    let video: LogicalVideo

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(video.name).font(.headline)
                Text(Fmt.bytes(video.totalBytes)).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
            }
            Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 4) {
                row("Current", video.variants.map { "\($0.name): \($0.probe?.summary ?? $0.probeError ?? "not inspected")" }.joined(separator: "\n"))
                row("Usages", (video.pages.map { "Page " + (URL(string: $0)?.path ?? $0) } + video.usages.map { "\($0.location) \($0.kind.rawValue)" }).joined(separator: "\n"))
                row("Max display", video.maxPictureWidth.map { "\(Int($0.rounded())) CSS px picture width" } ?? "Unmeasured")
                row("Recommended", video.recommendedWidth.map { "\($0) px wide (\(video.basis))" } ?? "Keep current (\(video.basis))")
                row("Best source", "\(video.bestSource?.name ?? "–") \(video.bestSourceNote)")
                row("Action", video.action)
            }
            .font(.callout)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(video.findings, id: \.self) { finding in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: symbol(finding.kind)).foregroundStyle(.secondary).frame(width: 16)
                        Text("**\(finding.kind.rawValue):** \(finding.text)\(finding.measured ? "" : " *(unmeasured)*")")
                    }
                    .font(.callout)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.07)))
        .textSelection(.enabled)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value)
        }
    }

    private func symbol(_ kind: Finding.Kind) -> String {
        switch kind {
        case .resolution: return "arrow.up.left.and.arrow.down.right"
        case .compression: return "archivebox"
        case .audio: return "speaker.wave.2"
        case .delivery: return "shippingbox"
        case .fullscreen: return "arrow.up.backward.and.arrow.down.forward"
        case .source: return "film"
        case .coverage: return "exclamationmark.triangle"
        }
    }
}
