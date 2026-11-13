import SwiftUI

struct CompareView: View {
    @Bindable var model: CompareModel
    let compress: CompressModel
    let select: (AppSection) -> Void
    @State private var positions = "25, 50, 75"

    var body: some View {
        HStack(spacing: 0) {
            settings
                .frame(width: 320)
                .disabled(model.isRunning)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                if model.input == nil {
                    DropZone(title: "Drop a video to compare", subtitle: "Encodes short samples at several CRF levels and estimates full-video sizes", onDrop: { if let url = $0.first { model.setInput(url) } }) {
                        if let url = Panels.chooseVideos(multiple: false).first { model.setInput(url) }
                    }
                    Spacer()
                } else {
                    inputHeader
                    if model.isRunning {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(model.isPaused ? "Paused · \(model.status)" : model.status).font(.callout)
                                Spacer()
                                Text("\(Int((model.progress * 100).rounded()))%").font(.callout.monospacedDigit()).foregroundStyle(.secondary).contentTransition(.numericText())
                            }
                            MiniTickBar(value: model.progress, paused: model.isPaused)
                        }
                        .padding(12)
                        .surfaceCard()
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    if let error = model.error { ErrorText(text: error) }
                    if let result = model.result {
                        ScrollView { results(result) }
                    } else {
                        Spacer()
                    }
                }
                HStack {
                    Spacer()
                    TransportControls(isRunning: model.isRunning, isPaused: model.isPaused,
                                      canStart: model.input != nil && (2...8).contains(model.options.candidates.count),
                                      startTitle: "Run comparison",
                                      start: {
                                          model.options.samplePositions = positions.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }.map { min(max($0, 0), 100) / 100 }
                                          if model.options.samplePositions.isEmpty { model.options.samplePositions = [0.25, 0.5, 0.75] }
                                          model.start()
                                      },
                                      togglePause: model.togglePause,
                                      stop: model.cancel)
                }
            }
            .padding(14)
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: model.isRunning)
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: model.result != nil)
        }
    }

    private var settings: some View {
        Form {
            Section {
                ForEach($model.options.candidates) { $candidate in
                    HStack {
                        Picker("", selection: $candidate.codec) {
                            ForEach(Codec.allCases) { Text($0.label).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 140)
                        Stepper(value: $candidate.crf, in: candidate.codec.crfRange) { Text("CRF \(candidate.crf)").monospacedDigit() }
                        Spacer()
                        Button { model.options.candidates.removeAll { $0.id == candidate.id } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                HStack {
                    Button("Add") { model.options.candidates.append(Candidate(codec: .h265, crf: 30)) }.disabled(model.options.candidates.count >= 8)
                    Button("Add AV1 36/42/48") {
                        model.options.candidates.append(contentsOf: [36, 42, 48].map { Candidate(codec: .av1, crf: $0) })
                        model.options.candidates = Array(model.options.candidates.prefix(8))
                    }
                    Button("Reset") { model.options.candidates = Candidate.defaults }
                }
                .buttonStyle(.link)
            } header: {
                Text("Candidates (\(model.options.candidates.count) of 2–8)")
            }
            Section("Samples") {
                TextField("Positions (% of duration)", text: $positions)
                Stepper(value: $model.options.sampleDuration, in: 0.5...10, step: 0.5) {
                    Text("Length: \(String(format: "%g", model.options.sampleDuration)) s each")
                }
            }
            Section("Transform") {
                OptionalIntField(label: "Max width (px)", value: $model.options.maxWidth)
                Picker("Above 30 fps", selection: $model.options.frameRate) {
                    ForEach(FrameRateMode.allCases) { Text($0.label).tag($0) }
                }
                Toggle("10-bit", isOn: $model.options.tenBit)
                Picker("Encoder speed", selection: $model.options.speed) {
                    ForEach(SpeedMode.allCases) { Text($0.label).tag($0) }
                }
            }
            Section("Report") {
                Toggle("Measure PSNR too", isOn: $model.options.psnr)
                Toggle("Show SSIM / PSNR columns", isOn: $model.showMetrics)
            }
            DestinationSection()
        }
        .clearFormBackground()
    }

    private var inputHeader: some View {
        HStack {
            Image(systemName: "film").font(.title2).foregroundStyle(.secondary)
            VStack(alignment: .leading) {
                Text(model.input!.lastPathComponent).font(.headline)
                if let probe = model.probe { Text(probe.summary).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            Button("Change…") { if let url = Panels.chooseVideos(multiple: false).first { model.setInput(url) } }.disabled(model.isRunning)
        }
        .dropDestination(for: URL.self) { urls, _ in
            if let url = urls.first, !model.isRunning { model.setInput(url) }
            return true
        }
    }

    @ViewBuilder
    private func results(_ result: CompareResult) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                GridRow {
                    Text("Format"); Text("CRF").gridColumnAlignment(.trailing); Text("Estimated size").gridColumnAlignment(.trailing); Text("File")
                    if model.showMetrics { Text("SSIM").gridColumnAlignment(.trailing); Text("PSNR").gridColumnAlignment(.trailing); Text("Pareto") }
                }
                .font(.caption.bold()).foregroundStyle(.secondary)
                Divider()
                ForEach(result.ordered) { row in
                    GridRow {
                        HStack(spacing: 4) {
                            if row.recommended { Image(systemName: "star.fill").foregroundStyle(.yellow).help("Recommended") }
                            Text(row.candidate.codec.label)
                        }
                        Text("\(row.candidate.crf)").monospacedDigit()
                        Text(result.size(row)).monospacedDigit()
                        Button("Preview") { Finder.open(row.previewURL) }.buttonStyle(.link)
                        if model.showMetrics {
                            Text(String(format: "%.4f", row.ssim)).monospacedDigit()
                            Text(row.psnr.map { $0.isFinite ? String(format: "%.2f dB", $0) : "∞" } ?? "–").monospacedDigit()
                            Text(row.onFrontier ? "frontier" : "").foregroundStyle(.secondary)
                        }
                    }
                    .fontWeight(row.recommended ? .semibold : .regular)
                }
            }
            if let rec = result.recommended {
                Text(result.recommendationText(rec)).font(.callout)
            }
            Text(result.coverageText).font(.caption).foregroundStyle(.secondary)
            Text("These metrics measure encoding loss against the transformed reference. Check resizing separately at the intended display size.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Copy Markdown table") { Finder.copy(result.markdown) }
                Button("Show files") { Finder.reveal([result.outputDirectory]) }
                if let rec = result.recommended {
                    Button("Compress with \(rec.candidate.codec.shortLabel) CRF \(rec.candidate.crf)") {
                        compress.settings.crf[rec.candidate.codec] = rec.candidate.crf
                        switch rec.candidate.codec {
                        case .vp9: compress.settings.vp9 = true
                        case .h265: compress.settings.h265 = true
                        case .av1: compress.settings.av1 = true
                        }
                        compress.settings.maxWidth = model.options.maxWidth
                        compress.add([result.source])
                        select(.compress)
                    }
                }
            }
            Text("Middle frame of each preview").font(.caption.bold()).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 12)], spacing: 12) {
                if let still = result.referenceStill { thumbnail(still, title: "Lossless reference", url: result.referenceURL) }
                ForEach(result.ordered) { row in
                    if let still = row.stillURL { thumbnail(still, title: "\(row.candidate.codec.shortLabel) CRF \(row.candidate.crf) · \(result.size(row))", url: row.previewURL) }
                }
            }
        }
        .padding(14)
        .surfaceCard(cornerRadius: 16)
        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
    }

    private func thumbnail(_ image: URL, title: String, url: URL) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let nsImage = NSImage(contentsOf: image) {
                Image(nsImage: nsImage).resizable().aspectRatio(contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 6))
            }
            Text(title).font(.caption)
        }
        .padding(6)
        .surfaceCard(cornerRadius: 10)
        .onTapGesture { Finder.open(url) }
        .help("Open preview")
    }
}
