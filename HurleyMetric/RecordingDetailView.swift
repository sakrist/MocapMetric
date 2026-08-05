import SwiftUI

struct RecordingDetailView: View {
    private enum GraphMode: String, CaseIterable, Identifiable {
        case acceleration = "Acceleration"
        case gyro = "Gyro"
        case gravity = "Gravity"
        case magnitude = "Magnitude"
        case rawAcceleration = "Raw 800 Hz"

        var id: String { rawValue }
    }

    struct GraphSeries: Identifiable {
        let id: String
        let title: String
        let color: Color
        let values: [Double]
        let timestamps: [Double]?

        init(
            id: String,
            title: String,
            color: Color,
            values: [Double],
            timestamps: [Double]? = nil
        ) {
            self.id = id
            self.title = title
            self.color = color
            self.values = values
            self.timestamps = timestamps
        }
    }

    let recording: RecordingSession
    
    let maxZoom = 10.0
    
    @State private var analysis: RecordingAnalysis?
    @State private var isProcessing = false
    @State private var errorMessage: String?
    @State private var zoomScale = 2.0
    @State private var selectedRecording: RecordingSession?
    @State private var selectedHit: HitRange?
    @State private var graphMode: GraphMode = .magnitude
    @State private var showingDeleteConfirmation = false
    @State private var isExportingVideo = false
    @State private var exportedItems: [Any] = []
    @State private var showingExportShare = false
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var inboxStore: RecordingInboxStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                summarySection
                selectedHitSection
                graphSection
            }
            .padding()
        }
        .navigationTitle(recording.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    selectedRecording = recording
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(recording.shareItems.isEmpty)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    showingDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                }
            }
        }
        .sheet(item: $selectedRecording) { selectedRecording in
            ActivityView(items: selectedRecording.shareItems)
        }
        .sheet(isPresented: $showingExportShare) {
            ActivityView(items: exportedItems)
        }
        .confirmationDialog("Delete this recording?", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                inboxStore.deleteRecording(recording)
                dismiss()
            }
        }
        .task(id: recording.id) {
            await processRecording()
        }
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isProcessing {
                ProgressView("Processing recording")
            } else if let errorMessage {
                Text(errorMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text("\(analysis?.hitRanges.count ?? 0) hits found")
                    .font(.title2.bold())

                if let analysis {
                    Text("\(analysis.samples.count) motion samples • \(analysis.rawAcceleration.count) raw samples")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(recording.createdAt, format: Date.FormatStyle(date: .abbreviated, time: .standard))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var selectedHitSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Selected Hit")
                .font(.headline)

            if let selectedHit {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Samples: \(selectedHit.sampleRangeLabel)")
                        .font(.subheadline.weight(.semibold))

                    Text("Confidence: \(selectedHit.peakProbability, format: .number.precision(.fractionLength(2)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("Speed: N/A")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("Strength: N/A")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
            } else if !isProcessing && errorMessage == nil {
                Text("Tap a highlighted hit range in the graph to inspect it.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var graphSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Motion Graph")
                .font(.headline)

            Picker("Graph Mode", selection: $graphMode) {
                ForEach(GraphMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 12) {
                ForEach(graphSeries) { series in
                    legendChip(color: series.color, title: series.title)
                }
            }

            HStack {
                Text("Zoom")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Slider(value: $zoomScale, in: 0.5...maxZoom)
            }

            Button {
                Task {
                    await exportOverlayVideo()
                }
            } label: {
                HStack {
                    if isExportingVideo {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(isExportingVideo ? "Exporting…" : "Export Overlay Video")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                isExportingVideo ||
                recording.videoURL == nil ||
                recording.phoneMetadataURL == nil ||
                recording.watchMetadataURL == nil ||
                analysis == nil
            )

            if let analysis {
                ScrollView(.horizontal) {
                    RecordingGraphView(
                        samples: analysis.samples,
                        hitRanges: analysis.hitRanges,
                        selectedHit: selectedHit,
                        series: graphSeries,
                        graphTimestamps: graphSeries.first?.timestamps ?? analysis.samples.map(\.timestamp),
                        zoomScale: zoomScale,
                        onSelectHit: { hit in
                            selectedHit = hit
                        }
                    )
                }
                .frame(height: 260)
            }
        }
    }

    private var graphSeries: [GraphSeries] {
        guard let analysis else { return [] }

        switch graphMode {
        case .acceleration:
            return [
                GraphSeries(id: "ax", title: "ax", color: .red, values: analysis.samples.map(\.ax)),
                GraphSeries(id: "ay", title: "ay", color: .green, values: analysis.samples.map(\.ay)),
                GraphSeries(id: "az", title: "az", color: .blue, values: analysis.samples.map(\.az)),
            ]
        case .gyro:
            return [
                GraphSeries(id: "gx", title: "gx", color: .red, values: analysis.samples.map(\.gx)),
                GraphSeries(id: "gy", title: "gy", color: .green, values: analysis.samples.map(\.gy)),
                GraphSeries(id: "gz", title: "gz", color: .blue, values: analysis.samples.map(\.gz)),
            ]
        case .gravity:
            return [
                GraphSeries(id: "grx", title: "grx", color: .red, values: analysis.samples.map(\.grx)),
                GraphSeries(id: "gry", title: "gry", color: .green, values: analysis.samples.map(\.gry)),
                GraphSeries(id: "grz", title: "grz", color: .blue, values: analysis.samples.map(\.grz)),
            ]
        case .magnitude:
            return [
                GraphSeries(id: "accMagnitude", title: "Accel Mag", color: .green, values: analysis.samples.map(\.accMagnitude)),
                GraphSeries(id: "gyroMagnitude", title: "Gyro Mag", color: .orange, values: analysis.samples.map(\.gyroMagnitude)),
            ]
        case .rawAcceleration:
            return [
                GraphSeries(id: "rawAx", title: "raw ax", color: .red, values: analysis.rawAcceleration.map(\.ax), timestamps: analysis.rawAcceleration.map(\.timestamp)),
                GraphSeries(id: "rawAy", title: "raw ay", color: .green, values: analysis.rawAcceleration.map(\.ay), timestamps: analysis.rawAcceleration.map(\.timestamp)),
                GraphSeries(id: "rawAz", title: "raw az", color: .blue, values: analysis.rawAcceleration.map(\.az), timestamps: analysis.rawAcceleration.map(\.timestamp)),
                GraphSeries(id: "rawMagnitude", title: "raw mag", color: .orange, values: analysis.rawAcceleration.map(\.magnitude), timestamps: analysis.rawAcceleration.map(\.timestamp)),
            ]
        }
    }

    private func legendChip(color: Color, title: String) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @MainActor
    private func processRecording() async {
        isProcessing = true
        errorMessage = nil

        do {
            let analysis = try await Task.detached(priority: .userInitiated) {
                try await StrikeDetector.shared.analyze(recording: recording)
            }.value
            self.analysis = analysis
            selectedHit = analysis.hitRanges.first
        } catch {
            errorMessage = error.localizedDescription
            analysis = nil
            selectedHit = nil
        }

        isProcessing = false
    }

    @MainActor
    private func exportOverlayVideo() async {
        guard let analysis else { return }

        isExportingVideo = true
        defer { isExportingVideo = false }

        do {
            let exporter = VideoOverlayExporter()
            let exportURL = try await exporter.exportOverlayVideo(
                recording: recording,
                samples: analysis.samples,
                series: exportSeries,
                modeTitle: graphMode.rawValue
            )

            exportedItems = [exportURL]
            showingExportShare = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var exportSeries: [ExportGraphSeries] {
        graphSeries.map {
            ExportGraphSeries(
                title: $0.title,
                color: UIColor($0.color),
                values: $0.values,
                timestamps: $0.timestamps
            )
        }
    }
}

private struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {
    }
}

private struct RecordingGraphView: View {
    let samples: [MotionSample]
    let hitRanges: [HitRange]
    let selectedHit: HitRange?
    let series: [RecordingDetailView.GraphSeries]
    let graphTimestamps: [Double]
    let zoomScale: Double
    let onSelectHit: (HitRange) -> Void

    private var maxValue: Double {
        let absoluteMax = series
            .flatMap(\.values)
            .map { abs($0) }
            .max() ?? 0
        return max(absoluteMax, 0.001)
    }

    private var graphWidth: CGFloat {
        max(600, CGFloat(samples.count) * CGFloat(zoomScale))
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.thinMaterial)

                ForEach(hitRanges) { hitRange in
                    let isSelected = selectedHit?.id == hitRange.id

                    Button {
                        onSelectHit(hitRange)
                    } label: {
                        Rectangle()
                            .fill(isSelected ? Color.red.opacity(0.28) : Color.red.opacity(0.14))
                            .frame(width: highlightWidth(for: hitRange))
                    }
                    .buttonStyle(.plain)
                    .offset(x: xPosition(for: hitRange.lowerSample))
                }

                ForEach(series) { graphSeries in
                    MetricLineShape(values: graphSeries.values, maxValue: maxValue)
                        .stroke(graphSeries.color, lineWidth: 2)
                }

                midline(in: geometry.size)
                    .stroke(Color.secondary.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
            .frame(width: graphWidth, height: geometry.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .frame(width: graphWidth, height: 240)
    }

    private func xPosition(for sampleIndex: Int) -> CGFloat {
        guard samples.indices.contains(sampleIndex) else { return 0 }
        return xPosition(forTimestamp: samples[sampleIndex].timestamp)
    }

    private func xPosition(forTimestamp timestamp: Double) -> CGFloat {
        guard let firstTimestamp = graphTimestamps.first,
              let lastTimestamp = graphTimestamps.last,
              lastTimestamp > firstTimestamp else {
            return 0
        }
        let progress = (timestamp - firstTimestamp) / (lastTimestamp - firstTimestamp)
        return CGFloat(min(max(progress, 0), 1)) * graphWidth
    }

    private func highlightWidth(for hitRange: HitRange) -> CGFloat {
        let start = xPosition(for: hitRange.lowerSample)
        let end = xPosition(for: hitRange.upperSample)
        return max(8, end - start)
    }

    private func midline(in size: CGSize) -> Path {
        var path = Path()
        let y = size.height / 2
        path.move(to: CGPoint(x: 0, y: y))
        path.addLine(to: CGPoint(x: graphWidth, y: y))
        return path
    }
}

private struct MetricLineShape: Shape {
    let values: [Double]
    let maxValue: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count > 1 else { return path }

        let denominator = CGFloat(max(values.count - 1, 1))

        for (index, value) in values.enumerated() {
            let x = rect.minX + (CGFloat(index) / denominator) * rect.width
            let normalized = CGFloat((value / maxValue).clamped(to: -1...1))
            let y = rect.midY - (normalized * rect.height * 0.45)
            let point = CGPoint(x: x, y: y)

            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }

        return path
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
