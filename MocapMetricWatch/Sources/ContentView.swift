import Foundation
import SwiftUI
import WatchMotionRecordingKit

struct ContentView: View {
    @StateObject private var recorder = WatchRecordingCoordinator(
        configuration: WatchRecordingConfiguration(
            scheduledLeadTime: 0,
            allowsPhoneRecordingFallback: true,
            recordsAudio: true
        )
    )
    @StateObject private var workoutSession = WatchWorkoutSessionManager()
    @State private var showGraph = false

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Button(recorder.isRecording ? "Stop" : "Start") {
                    toggleRecording()
                }
                .buttonStyle(.borderedProminent)

                Spacer(minLength: 8)

                Toggle("Graph", isOn: $showGraph)
                    .labelsHidden()
            }

            if recorder.isArmed, let countdown = recorder.countdownSecondsRemaining {
                HStack(spacing: 6) {
                    Circle()
                        .fill(.yellow)
                        .frame(width: 8, height: 8)

                    Text("Starting \(countdown, format: .number.precision(.fractionLength(1)))s")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let startedAt = recorder.recordingStartedAt {
                HStack(spacing: 6) {
                    Image(systemName: "record.circle.fill")
                        .foregroundStyle(.red)

                    TimelineView(.periodic(from: startedAt, by: 1)) { timeline in
                        Text(Self.elapsedTimeString(from: startedAt, to: timeline.date))
                            .font(.title3.weight(.semibold))
                            .monospacedDigit()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Accel")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(recorder.latestAccelMagnitude, format: .number.precision(.fractionLength(2)))
                        .font(.caption)
                        .monospacedDigit()
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Gyro")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(recorder.latestGyroMagnitude, format: .number.precision(.fractionLength(2)))
                        .font(.caption)
                        .monospacedDigit()
                }

                Spacer()

                Text("\(recorder.sampleCount)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            if showGraph {
                MagnitudeGraphView(
                    accelPoints: recorder.recentAccelMagnitudes,
                    gyroPoints: recorder.recentGyroMagnitudes
                )
                .frame(height: 90)
            }

            Text(recorder.statusMessage)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let workoutErrorMessage = workoutSession.lastErrorMessage {
                Text(workoutErrorMessage)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(8)
        .onAppear {
            recorder.setLiveGraphEnabled(showGraph)
        }
        .onChange(of: showGraph) { _, isVisible in
            recorder.setLiveGraphEnabled(isVisible)
        }
        .onChange(of: recorder.isRecording) { _, isRecording in
            if !isRecording {
                workoutSession.endIfNeeded()
            }
        }
        .onChange(of: recorder.isPreparing) { _, isPreparing in
            // A failed start never changes `isRecording` from false to true, so
            // use the end of preparation to release the workout in that case.
            if !isPreparing, !recorder.isRecording {
                workoutSession.endIfNeeded()
            }
        }
    }

    private func toggleRecording() {
        if recorder.isRecording {
            recorder.stopRecording()
            workoutSession.endIfNeeded()
            return
        }

        Task {
            guard recorder.isHighFrequencyRecordingSupported else {
                recorder.startRecording()
                return
            }
            guard await workoutSession.startIfNeeded() else { return }
            recorder.startRecording()
        }
    }

    /// Formats a stable elapsed time instead of Watch's relative-time wording.
    private static func elapsedTimeString(from start: Date, to current: Date) -> String {
        let totalSeconds = max(0, Int(current.timeIntervalSince(start)))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
}

private struct MagnitudeGraphView: View {
    let accelPoints: [Double]
    let gyroPoints: [Double]

    var body: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            let rect = CGRect(origin: .zero, size: size)
            context.fill(
                Path(roundedRect: rect, cornerRadius: 8),
                with: .color(.secondary.opacity(0.14))
            )

            guard !accelPoints.isEmpty || !gyroPoints.isEmpty else { return }

            let maxValue = max(accelPoints.max() ?? 0, gyroPoints.max() ?? 0, 0.001)
            context.stroke(
                GraphLine(points: accelPoints, maxValue: maxValue).path(in: rect),
                with: .color(.green),
                lineWidth: 2
            )
            context.stroke(
                GraphLine(points: gyroPoints, maxValue: maxValue).path(in: rect),
                with: .color(.orange),
                lineWidth: 2
            )
        }
    }
}

private struct GraphLine: Shape {
    let points: [Double]
    let maxValue: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()

        guard points.count > 1 else { return path }

        let denominator = CGFloat(max(points.count - 1, 1))

        for (index, value) in points.enumerated() {
            let x = rect.minX + (CGFloat(index) / denominator) * rect.width
            let normalized = CGFloat(min(max(value / maxValue, 0), 1))
            let y = rect.maxY - (normalized * rect.height)
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

#Preview {
    ContentView()
}
