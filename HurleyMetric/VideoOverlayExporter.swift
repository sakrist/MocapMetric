import Foundation
import AVFoundation
import UIKit
import SwiftUI

enum VideoOverlayExporterError: LocalizedError, Equatable {
    case missingVideo
    case missingMetadata
    case invalidMetadata
    case exportFailed
    case mismatchedSessionID
    case mismatchedPlannedStart

    var errorDescription: String? {
        switch self {
        case .missingVideo:
            return "No video is available for this recording."
        case .missingMetadata:
            return "Sync metadata is missing for this recording."
        case .invalidMetadata:
            return "Sync metadata is invalid."
        case .exportFailed:
            return "Video export failed."
        case .mismatchedSessionID:
            return "Phone and watch sync files do not belong to the same session."
        case .mismatchedPlannedStart:
            return "Phone and watch sync files disagree about the planned start time."
        }
    }
}

struct ExportGraphSeries {
    let title: String
    let color: UIColor
    let values: [Double]
}

struct VideoOverlayAlignment {
    struct WatchRecordingMetadata: Decodable {
        let sessionID: String
        let plannedStartUnix: Double
        let actualWatchStartUnix: Double
        let requestedDeviceMotionInterval: Double
        let createdUnix: Double
    }

    struct PhoneRecordingMetadata: Decodable {
        let sessionID: String
        let plannedStartUnix: Double
        let preRollStartUnix: Double
        let actualVideoStartUnix: Double?
        let syncFlashUnix: Double
        let createdUnix: Double
    }

    struct Solution {
        let watchToPhoneClockOffset: Double
        let actualVideoStartUnix: Double
    }

    static func solve(
        phoneMetadata: PhoneRecordingMetadata,
        watchMetadata: WatchRecordingMetadata
    ) throws -> Solution {
        guard phoneMetadata.sessionID == watchMetadata.sessionID else {
            throw VideoOverlayExporterError.mismatchedSessionID
        }
        guard abs(phoneMetadata.plannedStartUnix - watchMetadata.plannedStartUnix) <= 0.050 else {
            throw VideoOverlayExporterError.mismatchedPlannedStart
        }
        guard let actualVideoStartUnix = phoneMetadata.actualVideoStartUnix else {
            throw VideoOverlayExporterError.invalidMetadata
        }

        let watchToPhoneClockOffset = phoneMetadata.plannedStartUnix - watchMetadata.actualWatchStartUnix
        return Solution(
            watchToPhoneClockOffset: watchToPhoneClockOffset,
            actualVideoStartUnix: actualVideoStartUnix
        )
    }

    static func sampleVideoTimes(
        sampleTimestamps: [Double],
        phoneMetadata: PhoneRecordingMetadata,
        watchMetadata: WatchRecordingMetadata
    ) throws -> [Double] {
        let solution = try solve(phoneMetadata: phoneMetadata, watchMetadata: watchMetadata)
        return sampleTimestamps.map { ($0 + solution.watchToPhoneClockOffset) - solution.actualVideoStartUnix }
    }

    static func loadPhoneMetadata(from url: URL) throws -> PhoneRecordingMetadata {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(PhoneRecordingMetadata.self, from: data)
    }

    static func loadWatchMetadata(from url: URL) throws -> WatchRecordingMetadata {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(WatchRecordingMetadata.self, from: data)
    }
}

final class VideoOverlayExporter {

    private let visibleWindowSeconds: Double = 3.0
    private let panelInset: CGFloat = 14

    func exportOverlayVideo(
        recording: RecordingSession,
        samples: [MotionSample],
        series: [ExportGraphSeries],
        modeTitle: String
    ) async throws -> URL {
        guard let videoURL = recording.videoURL else {
            throw VideoOverlayExporterError.missingVideo
        }
        guard
            let phoneMetadataURL = recording.phoneMetadataURL,
            let watchMetadataURL = recording.watchMetadataURL
        else {
            throw VideoOverlayExporterError.missingMetadata
        }

        let phoneMetadata = try VideoOverlayAlignment.loadPhoneMetadata(from: phoneMetadataURL)
        let watchMetadata = try VideoOverlayAlignment.loadWatchMetadata(from: watchMetadataURL)
        let alignment = try VideoOverlayAlignment.solve(
            phoneMetadata: phoneMetadata,
            watchMetadata: watchMetadata
        )

        let asset = AVURLAsset(url: videoURL)
        let composition = AVMutableComposition()

        guard
            let videoTrack = try await asset.loadTracks(withMediaType: .video).first
        else {
            throw VideoOverlayExporterError.missingVideo
        }

        let compositionVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        try compositionVideoTrack?.insertTimeRange(
            CMTimeRange(start: .zero, duration: asset.duration),
            of: videoTrack,
            at: .zero
        )
        compositionVideoTrack?.preferredTransform = videoTrack.preferredTransform

        if let audioTrack = try await asset.loadTracks(withMediaType: .audio).first {
            let compositionAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            try compositionAudioTrack?.insertTimeRange(
                CMTimeRange(start: .zero, duration: asset.duration),
                of: audioTrack,
                at: .zero
            )
        }

        let renderSize = try await renderSize(for: videoTrack)
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: composition.duration)

        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compositionVideoTrack!)
        layerInstruction.setTransform(videoTrack.preferredTransform, at: .zero)
        instruction.layerInstructions = [layerInstruction]
        videoComposition.instructions = [instruction]

        let parentLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: renderSize)

        let videoLayer = CALayer()
        videoLayer.frame = CGRect(origin: .zero, size: renderSize)
        parentLayer.addSublayer(videoLayer)

        let overlayLayer = buildOverlayLayer(
            renderSize: renderSize,
            videoDuration: composition.duration.seconds,
            alignment: alignment,
            samples: samples,
            series: series,
            modeTitle: modeTitle
        )
        parentLayer.addSublayer(overlayLayer)

        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer,
            in: parentLayer
        )

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("overlay_\(recording.id)_\(UUID().uuidString).mov")
        try? FileManager.default.removeItem(at: outputURL)

        guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw VideoOverlayExporterError.exportFailed
        }

        exportSession.videoComposition = videoComposition
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mov
        exportSession.shouldOptimizeForNetworkUse = true

        return try await withCheckedThrowingContinuation { continuation in
            exportSession.exportAsynchronously {
                switch exportSession.status {
                case .completed:
                    continuation.resume(returning: outputURL)
                default:
                    continuation.resume(throwing: exportSession.error ?? VideoOverlayExporterError.exportFailed)
                }
            }
        }
    }

    private func buildOverlayLayer(
        renderSize: CGSize,
        videoDuration: Double,
        alignment: VideoOverlayAlignment.Solution,
        samples: [MotionSample],
        series: [ExportGraphSeries],
        modeTitle: String
    ) -> CALayer {
        let overlayLayer = CALayer()
        overlayLayer.frame = CGRect(origin: .zero, size: renderSize)

        let panelHeight = min(renderSize.height * 0.30, 250)
        let panelFrame = CGRect(
            x: panelInset,
            y: renderSize.height - panelHeight - panelInset,
            width: renderSize.width - (panelInset * 2),
            height: panelHeight
        )

        let panelLayer = CALayer()
        panelLayer.frame = panelFrame
        panelLayer.backgroundColor = UIColor.black.withAlphaComponent(0.58).cgColor
        panelLayer.cornerRadius = 18
        overlayLayer.addSublayer(panelLayer)

        addLegend(to: panelLayer, series: series, modeTitle: modeTitle)

        let graphInset: CGFloat = 18
        let graphFrame = CGRect(
            x: graphInset,
            y: 34,
            width: panelFrame.width - graphInset * 2,
            height: panelFrame.height - 56
        )

        let graphContainer = CALayer()
        graphContainer.frame = graphFrame
        graphContainer.masksToBounds = true
        panelLayer.addSublayer(graphContainer)

        addGrid(to: graphContainer)

        let sampleVideoTimes = sampleVideoTimes(
            samples: samples,
            alignment: alignment
        )
        let pixelsPerSecond = graphFrame.width / visibleWindowSeconds
        let graphImageWidth = max(CGFloat(videoDuration) * pixelsPerSecond, graphFrame.width)
        let graphImage = renderGraphImage(
            videoTimes: sampleVideoTimes,
            series: series,
            graphHeight: graphFrame.height,
            graphWidth: graphImageWidth,
            videoDuration: videoDuration,
            pixelsPerSecond: pixelsPerSecond
        )

        let graphImageLayer = CALayer()
        graphImageLayer.contents = graphImage.cgImage
        graphImageLayer.frame = CGRect(
            x: graphFrame.width / 2,
            y: 0,
            width: graphImage.size.width,
            height: graphImage.size.height
        )
        graphContainer.addSublayer(graphImageLayer)

        let animation = CABasicAnimation(keyPath: "transform.translation.x")
        animation.beginTime = AVCoreAnimationBeginTimeAtZero
        animation.fromValue = 0
        animation.toValue = -(videoDuration * pixelsPerSecond)
        animation.duration = videoDuration
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.isRemovedOnCompletion = false
        animation.fillMode = .forwards
        graphImageLayer.add(animation, forKey: "graphPan")

        let centerLine = CALayer()
        centerLine.backgroundColor = UIColor.red.cgColor
        centerLine.frame = CGRect(
            x: graphFrame.midX - 1.5,
            y: graphFrame.minY,
            width: 3,
            height: graphFrame.height
        )
        panelLayer.addSublayer(centerLine)

        let zeroLine = CALayer()
        zeroLine.backgroundColor = UIColor.white.withAlphaComponent(0.35).cgColor
        zeroLine.frame = CGRect(
            x: graphFrame.minX,
            y: graphFrame.midY,
            width: graphFrame.width,
            height: 1
        )
        panelLayer.addSublayer(zeroLine)

        let axisLabel = CATextLayer()
        axisLabel.string = "video time (s)"
        axisLabel.fontSize = 18
        axisLabel.foregroundColor = UIColor.white.withAlphaComponent(0.85).cgColor
        axisLabel.alignmentMode = .center
        axisLabel.contentsScale = UIScreen.main.scale
        axisLabel.frame = CGRect(x: graphFrame.minX, y: panelFrame.height - 24, width: graphFrame.width, height: 18)
        panelLayer.addSublayer(axisLabel)

        return overlayLayer
    }

    private func sampleVideoTimes(
        samples: [MotionSample],
        alignment: VideoOverlayAlignment.Solution
    ) -> [Double] {
        samples.map { ($0.timestamp + alignment.watchToPhoneClockOffset) - alignment.actualVideoStartUnix }
    }

    private func renderGraphImage(
        videoTimes: [Double],
        series: [ExportGraphSeries],
        graphHeight: CGFloat,
        graphWidth: CGFloat,
        videoDuration: Double,
        pixelsPerSecond: CGFloat
    ) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: graphWidth, height: graphHeight))
        let absoluteMax = max(
            series.flatMap(\.values).map { abs($0) }.max() ?? 0,
            0.001
        )

        return renderer.image { context in
            let cgContext = context.cgContext
            cgContext.setFillColor(UIColor.clear.cgColor)
            cgContext.fill(CGRect(origin: .zero, size: CGSize(width: graphWidth, height: graphHeight)))

            for graphSeries in series {
                let path = UIBezierPath()
                var hasPoint = false

                for (index, value) in graphSeries.values.enumerated() {
                    guard index < videoTimes.count else { continue }

                    let time = videoTimes[index]
                    guard time >= 0, time <= videoDuration else { continue }

                    let x = CGFloat(time) * pixelsPerSecond
                    let normalized = CGFloat((value / absoluteMax).clamped(to: -1...1))
                    let y = graphHeight / 2 - normalized * graphHeight * 0.42
                    let point = CGPoint(x: x, y: y)

                    if !hasPoint {
                        path.move(to: point)
                        hasPoint = true
                    } else {
                        path.addLine(to: point)
                    }
                }

                path.lineWidth = 3
                graphSeries.color.setStroke()
                path.stroke()
            }
        }
    }

    private func addGrid(to panelLayer: CALayer) {
        let gridLayer = CALayer()
        gridLayer.frame = panelLayer.bounds
        panelLayer.addSublayer(gridLayer)

        let horizontalPadding: CGFloat = 0
        let verticalPadding: CGFloat = 0

        for index in 1...4 {
            let horizontal = CALayer()
            horizontal.backgroundColor = UIColor.white.withAlphaComponent(0.18).cgColor
            horizontal.frame = CGRect(
                x: horizontalPadding,
                y: CGFloat(index) * (panelLayer.bounds.height - verticalPadding * 2) / 5,
                width: panelLayer.bounds.width - horizontalPadding * 2,
                height: 1
            )
            gridLayer.addSublayer(horizontal)
        }

        for index in 1...5 {
            let vertical = CALayer()
            vertical.backgroundColor = UIColor.white.withAlphaComponent(0.10).cgColor
            vertical.frame = CGRect(
                x: CGFloat(index) * panelLayer.bounds.width / 6,
                y: verticalPadding,
                width: 1,
                height: panelLayer.bounds.height - verticalPadding * 2
            )
            gridLayer.addSublayer(vertical)
        }
    }

    private func addLegend(to panelLayer: CALayer, series: [ExportGraphSeries], modeTitle: String) {
        let titleLayer = CATextLayer()
        titleLayer.string = modeTitle
        titleLayer.fontSize = 20
        titleLayer.foregroundColor = UIColor.white.cgColor
        titleLayer.contentsScale = UIScreen.main.scale
        titleLayer.frame = CGRect(x: 18, y: 8, width: 220, height: 18)
        panelLayer.addSublayer(titleLayer)

        var xOffset: CGFloat = panelLayer.bounds.width - 140
        for graphSeries in series {
            let legendText = CATextLayer()
            legendText.string = graphSeries.title
            legendText.fontSize = 18
            legendText.foregroundColor = graphSeries.color.cgColor
            legendText.alignmentMode = .right
            legendText.contentsScale = UIScreen.main.scale
            legendText.frame = CGRect(x: xOffset, y: 8, width: 120, height: 18)
            panelLayer.addSublayer(legendText)
            xOffset -= 90
        }
    }

    private func renderSize(for videoTrack: AVAssetTrack) async throws -> CGSize {
        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let transformedRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        return CGSize(width: abs(transformedRect.width), height: abs(transformedRect.height))
    }

}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
