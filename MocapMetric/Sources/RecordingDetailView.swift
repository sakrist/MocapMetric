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
    
    @State private var decodedRecording: DecodedMotionRecording?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var zoomScale = 2.0
    @State private var selectedRecording: RecordingSession?
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
            await loadRecording()
        }
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isLoading {
                ProgressView("Loading recording")
            } else if let errorMessage {
                Text(errorMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text("Motion Recording")
                    .font(.title2.bold())

                if let decodedRecording {
                    Text("\(decodedRecording.deviceMotion.count) motion samples • \(decodedRecording.rawAcceleration.count) raw samples")
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
                decodedRecording == nil
            )

            if let decodedRecording {
                ScrollView(.horizontal) {
                    RecordingGraphView(
                        series: graphSeries,
                        graphTimestamps: graphSeries.first?.timestamps ?? decodedRecording.deviceMotion.map(\.timestamp),
                        zoomScale: zoomScale
                    )
                }
                .frame(height: 260)
            }
        }
    }

    private var graphSeries: [GraphSeries] {
        guard let decodedRecording else { return [] }
        let samples = decodedRecording.deviceMotion
        let rawAcceleration = decodedRecording.rawAcceleration

        switch graphMode {
        case .acceleration:
            return [
                GraphSeries(id: "ax", title: "ax", color: .red, values: samples.map(\.ax)),
                GraphSeries(id: "ay", title: "ay", color: .green, values: samples.map(\.ay)),
                GraphSeries(id: "az", title: "az", color: .blue, values: samples.map(\.az)),
            ]
        case .gyro:
            return [
                GraphSeries(id: "gx", title: "gx", color: .red, values: samples.map(\.gx)),
                GraphSeries(id: "gy", title: "gy", color: .green, values: samples.map(\.gy)),
                GraphSeries(id: "gz", title: "gz", color: .blue, values: samples.map(\.gz)),
            ]
        case .gravity:
            return [
                GraphSeries(id: "grx", title: "grx", color: .red, values: samples.map(\.grx)),
                GraphSeries(id: "gry", title: "gry", color: .green, values: samples.map(\.gry)),
                GraphSeries(id: "grz", title: "grz", color: .blue, values: samples.map(\.grz)),
            ]
        case .magnitude:
            return [
                GraphSeries(id: "accMagnitude", title: "Accel Mag", color: .green, values: samples.map(\.accMagnitude)),
                GraphSeries(id: "gyroMagnitude", title: "Gyro Mag", color: .orange, values: samples.map(\.gyroMagnitude)),
            ]
        case .rawAcceleration:
            return [
                GraphSeries(id: "rawAx", title: "raw ax", color: .red, values: rawAcceleration.map(\.ax), timestamps: rawAcceleration.map(\.timestamp)),
                GraphSeries(id: "rawAy", title: "raw ay", color: .green, values: rawAcceleration.map(\.ay), timestamps: rawAcceleration.map(\.timestamp)),
                GraphSeries(id: "rawAz", title: "raw az", color: .blue, values: rawAcceleration.map(\.az), timestamps: rawAcceleration.map(\.timestamp)),
                GraphSeries(id: "rawMagnitude", title: "raw mag", color: .orange, values: rawAcceleration.map(\.magnitude), timestamps: rawAcceleration.map(\.timestamp)),
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
    private func loadRecording() async {
        isLoading = true
        errorMessage = nil

        do {
            decodedRecording = try await Task.detached(priority: .userInitiated) {
                try BinaryMotionReader().read(recording: recording)
            }.value
        } catch {
            errorMessage = error.localizedDescription
            decodedRecording = nil
        }

        isLoading = false
    }

    @MainActor
    private func exportOverlayVideo() async {
        guard let decodedRecording else { return }

        isExportingVideo = true
        defer { isExportingVideo = false }

        do {
            let exporter = VideoOverlayExporter()
            let exportURL = try await exporter.exportOverlayVideo(
                recording: recording,
                samples: decodedRecording.deviceMotion,
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
    let series: [RecordingDetailView.GraphSeries]
    let graphTimestamps: [Double]
    let zoomScale: Double

    private var maxValue: Double {
        let absoluteMax = series
            .flatMap(\.values)
            .map { abs($0) }
            .max() ?? 0
        return max(absoluteMax, 0.001)
    }

    private var graphWidth: CGFloat {
        max(600, CGFloat(graphTimestamps.count) * CGFloat(zoomScale))
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.thinMaterial)

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
