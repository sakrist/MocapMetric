import Foundation
import AVFoundation
import SwiftUI
import Combine
import CoreMedia
import OSLog
import WatchMotionRecordingKit

final class PhoneVideoRecorder: NSObject, ObservableObject {
    struct ScheduledStartResult {
        let plannedStartUnix: Double
        let accepted: Bool
    }

    @Published var isArmed = false
    @Published private(set) var isConfigured = false
    @Published private(set) var isRecording = false
    @Published private(set) var statusMessage = "iPhone video off"
    @Published private(set) var showSyncFlash = false
    private(set) var configuredFrameRate: Double?

    nonisolated let captureSession = AVCaptureSession()

    var onRecordingSaved: (() -> Void)?

    private let logger = Logger(subsystem: "com.sakrist.MocapMetric", category: "PhoneVideoRecorder")
    private let sessionQueue = DispatchQueue(label: "PhoneVideoRecorder.SessionQueue")
    private let movieOutput = AVCaptureMovieFileOutput()
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private var currentSessionID: String?
    private var currentMetadataFileURL: URL?
    private var currentMetadata: PhoneRecordingMetadata?
    private var didConfigureSession = false
    private var needsFirstRecordedFrameTimestamp = false
    private var hasStartedMovieOutput = false

    func setArmed(_ armed: Bool) {
        logger.info("Video arming changed. armed=\(armed, privacy: .public)")
        isArmed = armed

        if armed {
            Task {
                await configureAndStartSessionIfNeeded()
            }
        } else {
            stopVideoSession()
        }
    }

    func startRemoteRecording(sessionID: String) {
        guard isArmed else {
            logger.error("Ignoring Watch video start; video is not armed. session=\(sessionID, privacy: .public)")
            statusMessage = "Watch started; iPhone video not armed"
            return
        }

        guard isConfigured else {
            logger.error("Ignoring Watch video start; camera is not configured. session=\(sessionID, privacy: .public)")
            statusMessage = "Watch started; camera not ready"
            return
        }

        logger.info("Received Watch video start. session=\(sessionID, privacy: .public)")
        sessionQueue.async {
            guard self.currentSessionID == sessionID else {
                self.logger.error("Ignoring Watch video start for a different session. requested=\(sessionID, privacy: .public) active=\(self.currentSessionID ?? "none", privacy: .public)")
                return
            }

            if self.movieOutput.isRecording {
                self.logger.info("Movie output is already recording. session=\(sessionID, privacy: .public)")
                DispatchQueue.main.async {
                    self.isRecording = true
                    self.statusMessage = "Recording iPhone video"
                }
                return
            }

            let outputURL = Self.recordingsDirectoryURL()
                .appendingPathComponent(WatchRecordingAssetNaming.videoFileName(sessionID: sessionID))

            self.removeExistingRecordingIfNeeded(at: outputURL)
            self.needsFirstRecordedFrameTimestamp = true
            self.hasStartedMovieOutput = false
            self.logger.info("Starting movie output from Watch control. session=\(sessionID, privacy: .public) file=\(outputURL.lastPathComponent, privacy: .public)")
            self.movieOutput.startRecording(to: outputURL, recordingDelegate: self)

            DispatchQueue.main.async {
                self.statusMessage = "Starting iPhone video"
            }
        }
    }

    func prepareRemoteRecording(sessionID: String, leadTime: TimeInterval) -> ScheduledStartResult {
        logger.info("Received Watch video pre-roll request. session=\(sessionID, privacy: .public) leadTime=\(leadTime, privacy: .public)s")
        guard isArmed, isConfigured else {
            logger.error("Rejecting Watch video pre-roll; video is not ready. session=\(sessionID, privacy: .public) armed=\(self.isArmed, privacy: .public) configured=\(self.isConfigured, privacy: .public)")
            statusMessage = "Video not armed for sync start"
            return ScheduledStartResult(plannedStartUnix: Date().timeIntervalSince1970, accepted: false)
        }
        guard currentSessionID == nil else {
            logger.error("Rejecting Watch video pre-roll; another session is active. requested=\(sessionID, privacy: .public) active=\(self.currentSessionID ?? "none", privacy: .public)")
            statusMessage = "Video is already preparing or recording"
            return ScheduledStartResult(plannedStartUnix: Date().timeIntervalSince1970, accepted: false)
        }
        guard !sessionQueue.sync(execute: { movieOutput.isRecording }) else {
            logger.error("Rejecting Watch video pre-roll; movie output is already recording. session=\(sessionID, privacy: .public)")
            statusMessage = "Video is already recording"
            return ScheduledStartResult(plannedStartUnix: Date().timeIntervalSince1970, accepted: false)
        }

        let now = Date().timeIntervalSince1970
        let plannedStartUnix = now + max(leadTime, 1.0)
        let metadataURL = Self.recordingsDirectoryURL()
            .appendingPathComponent(WatchRecordingAssetNaming.phoneMetadataFileName(sessionID: sessionID))
        let outputURL = Self.recordingsDirectoryURL()
            .appendingPathComponent(WatchRecordingAssetNaming.videoFileName(sessionID: sessionID))

        currentSessionID = sessionID
        currentMetadataFileURL = metadataURL
        currentMetadata = PhoneRecordingMetadata(
            sessionID: sessionID,
            plannedStartUnix: plannedStartUnix,
            preRollStartUnix: now,
            actualVideoStartUnix: nil,
            syncFlashUnix: plannedStartUnix,
            createdUnix: now
        )

        saveCurrentMetadata()
        scheduleSyncFlash(at: plannedStartUnix)

        sessionQueue.async {
            guard !self.movieOutput.isRecording else {
                self.logger.error("Could not start video pre-roll; movie output is already recording. session=\(sessionID, privacy: .public)")
                return
            }
            self.removeExistingRecordingIfNeeded(at: outputURL)
            self.needsFirstRecordedFrameTimestamp = true
            self.hasStartedMovieOutput = false
            self.logger.info("Starting video pre-roll. session=\(sessionID, privacy: .public) file=\(outputURL.lastPathComponent, privacy: .public)")
            self.movieOutput.startRecording(to: outputURL, recordingDelegate: self)
        }

        logger.info("Accepted Watch video pre-roll. session=\(sessionID, privacy: .public) plannedStart=\(plannedStartUnix, privacy: .public)")
        statusMessage = "Video pre-roll started"
        return ScheduledStartResult(plannedStartUnix: plannedStartUnix, accepted: true)
    }

    func stopRemoteRecording(sessionID: String) {
        logger.info("Received Watch video stop. session=\(sessionID, privacy: .public)")
        sessionQueue.async {
            guard self.movieOutput.isRecording else {
                self.logger.info("Movie output was already stopped. session=\(sessionID, privacy: .public)")
                return
            }
            guard self.currentSessionID == sessionID else {
                self.logger.error("Ignoring Watch video stop for a different session. requested=\(sessionID, privacy: .public) active=\(self.currentSessionID ?? "none", privacy: .public)")
                return
            }
            self.movieOutput.stopRecording()
        }
    }

    private func stopVideoSession() {
        logger.info("Stopping local video session")
        sessionQueue.async {
            if self.movieOutput.isRecording {
                self.movieOutput.stopRecording()
            }
            self.hasStartedMovieOutput = false

            if self.captureSession.isRunning {
                self.captureSession.stopRunning()
            }

            DispatchQueue.main.async {
                self.isRecording = false
                self.isConfigured = false
                self.statusMessage = "iPhone video off"
            }
        }
    }

    private func scheduleSyncFlash(at plannedStartUnix: Double) {
        // Convert the agreed wall-clock start time into a local delay for the UI flash.
        let delay = max(0, plannedStartUnix - Date().timeIntervalSince1970)

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            self.showSyncFlash = true
            // Keep the flash brief so it is easy to spot in the recorded video.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self.showSyncFlash = false
            }
        }
    }

    private func configureAndStartSessionIfNeeded() async {
        let permissionGranted = await requestCameraPermission()
        guard permissionGranted else {
            logger.error("Camera permission was denied")
            await MainActor.run {
                self.statusMessage = "Camera permission denied"
                self.isArmed = false
            }
            return
        }

        sessionQueue.async {
            guard self.isArmed else { return }

            if !self.didConfigureSession {
                do {
                    // Build the capture graph only once; later arming just restarts the session.
                    try self.configureSession()
                    self.didConfigureSession = true
                    self.logger.info("Camera capture session configured")
                } catch {
                    self.logger.error("Camera setup failed: \(error.localizedDescription, privacy: .public)")
                    DispatchQueue.main.async {
                        self.statusMessage = "Camera setup failed: \(error.localizedDescription)"
                        self.isArmed = false
                    }
                    return
                }
            }

            if !self.captureSession.isRunning {
                guard self.isArmed else { return }
                // Start camera delivery ahead of the watch signal so recording can begin immediately.
                self.captureSession.startRunning()
                self.logger.info("Camera capture session started")
            }

            DispatchQueue.main.async {
                self.isConfigured = true
                if let configuredFrameRate = self.configuredFrameRate {
                    self.statusMessage = String(format: "Waiting for watch start (%.0f fps max)", configuredFrameRate)
                } else {
                    self.statusMessage = "Waiting for watch start"
                }
            }
        }
    }

    private func configureSession() throws {
        guard
            let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        else {
            throw NSError(domain: "PhoneVideoRecorder", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Back camera unavailable",
            ])
        }

        try configureHighestFrameRate(for: camera)

        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }

        captureSession.sessionPreset = .inputPriority

        let videoInput = try AVCaptureDeviceInput(device: camera)
        guard captureSession.canAddInput(videoInput) else {
            throw NSError(domain: "PhoneVideoRecorder", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Camera input unavailable",
            ])
        }
        captureSession.addInput(videoInput)

        videoDataOutput.alwaysDiscardsLateVideoFrames = true
        videoDataOutput.setSampleBufferDelegate(self, queue: sessionQueue)
        guard captureSession.canAddOutput(videoDataOutput) else {
            throw NSError(domain: "PhoneVideoRecorder", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Video timestamp output unavailable",
            ])
        }
        captureSession.addOutput(videoDataOutput)

        guard captureSession.canAddOutput(movieOutput) else {
            throw NSError(domain: "PhoneVideoRecorder", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "Movie output unavailable",
            ])
        }
        captureSession.addOutput(movieOutput)
    }

    private func configureHighestFrameRate(for camera: AVCaptureDevice) throws {
        try camera.lockForConfiguration()
        defer { camera.unlockForConfiguration() }

        var bestFormat: AVCaptureDevice.Format?
        var bestFrameRateRange: AVFrameRateRange?

        for format in camera.formats {
            for frameRateRange in format.videoSupportedFrameRateRanges {
                guard bestFrameRateRange == nil || frameRateRange.maxFrameRate > bestFrameRateRange!.maxFrameRate else {
                    continue
                }

                bestFormat = format
                bestFrameRateRange = frameRateRange
            }
        }

        guard let bestFormat, let bestFrameRateRange else { return }

        camera.activeFormat = bestFormat
        camera.activeVideoMinFrameDuration = bestFrameRateRange.minFrameDuration
        camera.activeVideoMaxFrameDuration = bestFrameRateRange.minFrameDuration
        configuredFrameRate = bestFrameRateRange.maxFrameRate
    }

    private func requestCameraPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        default:
            return false
        }
    }

    private static func recordingsDirectoryURL() -> URL {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directoryURL = documentsURL.appendingPathComponent("WatchRecordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }

    private func removeExistingRecordingIfNeeded(at url: URL) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return }

        do {
            try fileManager.removeItem(at: url)
        } catch {
            logger.error("Could not replace existing video. file=\(url.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private func saveCurrentMetadata() {
        guard let currentMetadataFileURL, let currentMetadata else { return }
        do {
            let data = try JSONEncoder().encode(currentMetadata)
            try data.write(to: currentMetadataFileURL, options: .atomic)
        } catch {
            logger.error("Failed to save phone video metadata. file=\(currentMetadataFileURL.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private func recordFirstFrameTimestampIfNeeded(estimatedUnixTime: Double) {
        guard needsFirstRecordedFrameTimestamp, hasStartedMovieOutput else { return }
        guard var currentMetadata = currentMetadata else {
            needsFirstRecordedFrameTimestamp = false
            return
        }

        currentMetadata = PhoneRecordingMetadata(
            sessionID: currentMetadata.sessionID,
            plannedStartUnix: currentMetadata.plannedStartUnix,
            preRollStartUnix: currentMetadata.preRollStartUnix,
            actualVideoStartUnix: estimatedUnixTime,
            syncFlashUnix: currentMetadata.syncFlashUnix,
            createdUnix: currentMetadata.createdUnix
        )

        self.currentMetadata = currentMetadata
        needsFirstRecordedFrameTimestamp = false
        saveCurrentMetadata()
    }

    nonisolated private static func estimateUnixTime(
        for sampleBuffer: CMSampleBuffer,
        sessionClock: CMClock?
    ) -> Double {
        let callbackUnixNow = Date().timeIntervalSince1970
        guard let sessionClock else {
            return callbackUnixNow
        }

        let samplePresentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let currentSessionClockTime = CMClockGetTime(sessionClock)
        let secondsFromSampleToCallback = CMTimeSubtract(currentSessionClockTime, samplePresentationTime).seconds
        return callbackUnixNow - secondsFromSampleToCallback
    }
}

extension PhoneVideoRecorder: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didStartRecordingTo fileURL: URL,
        from connections: [AVCaptureConnection]
    ) {
        self.sessionQueue.async {
            self.hasStartedMovieOutput = true
        }
        logger.info("Movie output started. file=\(fileURL.lastPathComponent, privacy: .public)")
        DispatchQueue.main.async {
            self.isRecording = true
            self.statusMessage = "Recording iPhone video"
        }
    }

    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        self.sessionQueue.async {
            self.hasStartedMovieOutput = false
        }
        if let error {
            logger.error("Movie output finished with an error. file=\(outputFileURL.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        } else {
            logger.info("Movie output finished successfully. file=\(outputFileURL.lastPathComponent, privacy: .public)")
        }
        DispatchQueue.main.async {
            self.isRecording = false
            self.currentSessionID = nil
            self.currentMetadataFileURL = nil
            self.currentMetadata = nil
            if let error {
                self.statusMessage = "Video save failed: \(error.localizedDescription)"
            } else {
                self.statusMessage = "Saved \(outputFileURL.lastPathComponent)"
                self.onRecordingSaved?()
            }
        }
    }
}

extension PhoneVideoRecorder: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let estimatedUnixTime = Self.estimateUnixTime(
            for: sampleBuffer,
            sessionClock: captureSession.synchronizationClock
        )
        sessionQueue.async {
            self.recordFirstFrameTimestampIfNeeded(estimatedUnixTime: estimatedUnixTime)
        }
    }
}

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let previewView = PreviewView()
        previewView.previewLayer.session = session
        previewView.previewLayer.videoGravity = .resizeAspectFill
        return previewView
    }

    func updateUIView(_ previewView: PreviewView, context: Context) {
        previewView.previewLayer.session = session
    }
}

final class PreviewView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }
}
