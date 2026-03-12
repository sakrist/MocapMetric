import SwiftUI

struct ContentView: View {
    @StateObject private var logger = AccelerometerLogger()
    @State private var showGraph = true

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Button(logger.isRecording ? "Stop" : "Start") {
                    if logger.isRecording {
                        logger.stopLogging()
                    } else {
                        logger.startLogging()
                    }
                }
                .buttonStyle(.borderedProminent)

                Spacer(minLength: 8)

                Toggle("Graph", isOn: $showGraph)
                    .labelsHidden()
            }

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Accel")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(logger.latestAccelMagnitude, format: .number.precision(.fractionLength(2)))
                        .font(.caption)
                        .monospacedDigit()
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Gyro")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(logger.latestGyroMagnitude, format: .number.precision(.fractionLength(2)))
                        .font(.caption)
                        .monospacedDigit()
                }

                Spacer()

                Text("\(logger.sampleCount)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            if showGraph {
                MagnitudeGraphView(
                    accelPoints: logger.recentAccelMagnitudes,
                    gyroPoints: logger.recentGyroMagnitudes
                )
                .frame(height: 90)
            }

            Text(logger.statusMessage)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
    }
}

private struct MagnitudeGraphView: View {
    let accelPoints: [Double]
    let gyroPoints: [Double]

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.thinMaterial)

                if !accelPoints.isEmpty || !gyroPoints.isEmpty {
                    let maxValue = max(accelPoints.max() ?? 0, gyroPoints.max() ?? 0, 0.001)

                    GraphLine(points: accelPoints, maxValue: maxValue)
                        .stroke(.green, lineWidth: 2)

                    GraphLine(points: gyroPoints, maxValue: maxValue)
                        .stroke(.orange, lineWidth: 2)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
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
