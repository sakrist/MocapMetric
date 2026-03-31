import Foundation
import AVFoundation
import SwiftUI
import Combine
import CoreMedia

final class PhoneVideoRecorder: NSObject, ObservableObject {
    struct ScheduledStartResult {
        let plannedStartUnix: Double
        let accepted: Bool
    }

    private struct PhoneRecordingMetadata: Codable {
        let sessionID: String
        let plannedStartUnix: Double
        let preRollStartUnix: Double
        let actualVideoStartUnix: Double?
        let syncFlashUnix: Double
        let createdUnix: Double
    }

    @Published var isArmed = false
    @Published private(set) var isConfigured = false
    @Published private(set) var isRecording = false
    @Published private(set) var statusMessage = "iPhone video off"
    @Published private(set) var showSyncFlash = false
    private(set) var configuredFrameRate: Double?

    nonisolated let captureSession = AVCaptureSession()

    var onRecordingSaved: (() -> Void)?

    private let sessionQueue = DispatchQueue(label: "PhoneVideoRecorder.SessionQueue")
    private let movieOutput = AVCaptureMovieFileOutput()
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private var currentSessionID: String?
    private var currentMetadataFileURL: URL?
    private var currentMetadata: PhoneRecordingMetadata?
    private var didConfigureSession = false
    private var needsFirstRecordedFrameTimestamp = false

    func setArmed(_ armed: Bool) {
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
            statusMessage = "Watch started; iPhone video not armed"
            return
        }

        guard isConfigured else {
            statusMessage = "Watch started; camera not ready"
            return
        }

        sessionQueue.async {
            guard !self.movieOutput.isRecording else { return }

            let outputURL = Self.recordingsDirectoryURL()
                .appendingPathComponent("recording_\(sessionID).mov")

            try? FileManager.default.removeItem(at: outputURL)
            self.currentSessionID = sessionID
            self.needsFirstRecordedFrameTimestamp = true
            self.movieOutput.startRecording(to: outputURL, recordingDelegate: self)

            DispatchQueue.main.async {
                self.isRecording = true
                self.statusMessage = "Recording iPhone video"
            }
        }
    }

    func prepareRemoteRecording(sessionID: String, leadTime: TimeInterval) -> ScheduledStartResult {
        guard isArmed, isConfigured else {
            statusMessage = "Video not armed for sync start"
            return ScheduledStartResult(plannedStartUnix: Date().timeIntervalSince1970, accepted: false)
        }

        let now = Date().timeIntervalSince1970
        let plannedStartUnix = now + max(leadTime, 1.0)
        let metadataURL = Self.recordingsDirectoryURL()
            .appendingPathComponent("recording_\(sessionID).phone.json")
        let outputURL = Self.recordingsDirectoryURL()
            .appendingPathComponent("recording_\(sessionID).mov")

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
            guard !self.movieOutput.isRecording else { return }
            try? FileManager.default.removeItem(at: outputURL)
            self.needsFirstRecordedFrameTimestamp = true
            self.movieOutput.startRecording(to: outputURL, recordingDelegate: self)
        }

        statusMessage = "Video pre-roll started"
        return ScheduledStartResult(plannedStartUnix: plannedStartUnix, accepted: true)
    }

    func stopRemoteRecording(sessionID: String) {
        sessionQueue.async {
            guard self.movieOutput.isRecording else { return }
            guard self.currentSessionID == sessionID else { return }
            self.movieOutput.stopRecording()
        }
    }

    private func stopVideoSession() {
        sessionQueue.async {
            if self.movieOutput.isRecording {
                self.movieOutput.stopRecording()
            }

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
        let delay = max(0, plannedStartUnix - Date().timeIntervalSince1970)

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            self.showSyncFlash = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self.showSyncFlash = false
            }
        }
    }

    private func configureAndStartSessionIfNeeded() async {
        let permissionGranted = await requestCameraPermission()
        guard permissionGranted else {
            statusMessage = "Camera permission denied"
            isArmed = false
            return
        }

        sessionQueue.async {
            if !self.didConfigureSession {
                do {
                    try self.configureSession()
                    self.didConfigureSession = true
                } catch {
                    DispatchQueue.main.async {
                        self.statusMessage = "Camera setup failed: \(error.localizedDescription)"
                        self.isArmed = false
                    }
                    return
                }
            }

            if !self.captureSession.isRunning {
                self.captureSession.startRunning()
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
        if captureSession.canAddInput(videoInput) {
            captureSession.addInput(videoInput)
        }

        videoDataOutput.alwaysDiscardsLateVideoFrames = true
        videoDataOutput.setSampleBufferDelegate(self, queue: sessionQueue)
        if captureSession.canAddOutput(videoDataOutput) {
            captureSession.addOutput(videoDataOutput)
        }

        if captureSession.canAddOutput(movieOutput) {
            captureSession.addOutput(movieOutput)
        }
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

    private func saveCurrentMetadata() {
        guard let currentMetadataFileURL, let currentMetadata else { return }
        if let data = try? JSONEncoder().encode(currentMetadata) {
            try? data.write(to: currentMetadataFileURL, options: .atomic)
        }
    }

    private func recordFirstFrameTimestampIfNeeded(estimatedUnixTime: Double) {
        guard needsFirstRecordedFrameTimestamp, movieOutput.isRecording else { return }
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
        DispatchQueue.main.async {
            if var currentMetadata = self.currentMetadata, currentMetadata.actualVideoStartUnix == nil {
                currentMetadata = PhoneRecordingMetadata(
                    sessionID: currentMetadata.sessionID,
                    plannedStartUnix: currentMetadata.plannedStartUnix,
                    preRollStartUnix: currentMetadata.preRollStartUnix,
                    actualVideoStartUnix: Date().timeIntervalSince1970,
                    syncFlashUnix: currentMetadata.syncFlashUnix,
                    createdUnix: currentMetadata.createdUnix
                )
                self.currentMetadata = currentMetadata
                self.saveCurrentMetadata()
            }
            self.statusMessage = "Recording iPhone video"
        }
    }

    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        DispatchQueue.main.async {
            self.isRecording = false
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
