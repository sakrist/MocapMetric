import Foundation
import CoreMotion
import Combine
import AVFoundation

final class AccelerometerLogger: ObservableObject {
    private static let requestedDeviceMotionInterval = 1.0 / 200.0
    private static let scheduledLeadTime: TimeInterval = 1.0

    private struct WatchRecordingMetadata: Codable {
        let sessionID: String
        let plannedStartUnix: Double
        let actualWatchStartUnix: Double
        let requestedDeviceMotionInterval: Double
        let createdUnix: Double
    }

    @Published private(set) var isRecording = false
    @Published private(set) var sampleCount = 0
    @Published private(set) var currentFileName: String?
    @Published private(set) var latestAccelMagnitude = 0.0
    @Published private(set) var latestGyroMagnitude = 0.0
    @Published private(set) var recentAccelMagnitudes: [Double] = []
    @Published private(set) var recentGyroMagnitudes: [Double] = []
    @Published private(set) var isArmed = false
    @Published private(set) var countdownSecondsRemaining: Double?
    @Published private(set) var statusMessage = "Idle"

    private let motionManager = CMMotionManager()
    private let transferManager = WatchRecordingTransferManager.shared
    private let motionQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "AccelerometerLogger.MotionQueue"
        queue.qualityOfService = .userInitiated
        return queue
    }()

    private let fileQueue = DispatchQueue(label: "AccelerometerLogger.FileQueue")
    private var fileHandle: FileHandle?
    private var currentCSVFileURL: URL?
    private var currentAudioFileURL: URL?
    private var currentMetadataFileURL: URL?
    private var currentSessionID: String?
    private var audioRecorder: AVAudioRecorder?

    private let maxHistorySamples = 150

    init() {
        transferManager.activate()
    }

    deinit {
        motionManager.stopDeviceMotionUpdates()
        audioRecorder?.stop()
        try? fileHandle?.close()
    }

    func startLogging() {
        guard !isRecording else { return }
        Task { [weak self] in
            await self?.startLoggingSession()
        }
    }

    private func startLoggingSession() async {
        guard motionManager.isDeviceMotionAvailable else {
            setStatus("Device motion unavailable")
            return
        }

        let hasAudioPermission = await requestAudioPermission()
        guard hasAudioPermission else {
            setStatus("Microphone permission denied")
            return
        }

        do {
            let sessionID = Self.makeSessionID()
            let csvFileURL = try createRecordingFileURL(sessionID: sessionID, fileExtension: "csv")
            let audioFileURL = try createRecordingFileURL(sessionID: sessionID, fileExtension: "m4a")
            let metadataFileURL = try createMetadataFileURL(sessionID: sessionID)
            let handle = try prepareLogFile(at: csvFileURL)
            let recorder = try prepareAudioRecorder(at: audioFileURL)

            fileHandle = handle
            currentCSVFileURL = csvFileURL
            currentAudioFileURL = audioFileURL
            currentMetadataFileURL = metadataFileURL
            currentSessionID = sessionID
            audioRecorder = recorder

            sampleCount = 0
            latestAccelMagnitude = 0
            latestGyroMagnitude = 0
            recentAccelMagnitudes.removeAll(keepingCapacity: true)
            recentGyroMagnitudes.removeAll(keepingCapacity: true)
            isArmed = false
            countdownSecondsRemaining = nil
            currentFileName = csvFileURL.deletingPathExtension().lastPathComponent

            let scheduledStart = await transferManager.requestScheduledStart(
                sessionID: sessionID,
                leadTime: Self.scheduledLeadTime
            )

            let plannedStartUnix = scheduledStart?.plannedStartUnix ?? Date().timeIntervalSince1970

            if plannedStartUnix > Date().timeIntervalSince1970 {
                isArmed = true
                setStatus("Armed, starting soon")
                startCountdown(to: plannedStartUnix)
                let delayNanoseconds = UInt64((plannedStartUnix - Date().timeIntervalSince1970) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }

            let actualWatchStartUnix = Date().timeIntervalSince1970
            isArmed = false
            countdownSecondsRemaining = nil
            try saveWatchMetadata(
                to: metadataFileURL,
                metadata: WatchRecordingMetadata(
                    sessionID: sessionID,
                    plannedStartUnix: plannedStartUnix,
                    actualWatchStartUnix: actualWatchStartUnix,
                    requestedDeviceMotionInterval: Self.requestedDeviceMotionInterval,
                    createdUnix: Date().timeIntervalSince1970
                )
            )

            recorder.record(atTime: recorder.deviceCurrentTime + max(0, plannedStartUnix - actualWatchStartUnix))
            transferManager.sendRecordingControl(action: .start, sessionID: sessionID)

            // Request a very high sample rate; Core Motion clamps to the hardware maximum.
            motionManager.deviceMotionUpdateInterval = Self.requestedDeviceMotionInterval
            motionManager.startDeviceMotionUpdates(to: motionQueue) { [weak self] motion, error in
                guard let self else { return }

                if let error {
                    DispatchQueue.main.async {
                        self.setStatus("Motion error: \(error.localizedDescription)")
                        self.stopLogging()
                    }
                    return
                }

                guard let motion else { return }
                self.appendSample(motion)
            }

            isRecording = true
            statusMessage = "Recording motion + audio"
        } catch {
            isArmed = false
            countdownSecondsRemaining = nil
            cleanupIncompleteSession()
            setStatus("Failed to start: \(error.localizedDescription)")
        }
    }

    func stopLogging() {
        guard isRecording else { return }

        motionManager.stopDeviceMotionUpdates()
        audioRecorder?.stop()
        audioRecorder = nil
        isArmed = false
        countdownSecondsRemaining = nil
        try? AVAudioSession.sharedInstance().setActive(false)

        let handle = fileHandle
        fileHandle = nil

        fileQueue.sync {
            try? handle?.synchronize()
            try? handle?.close()
        }

        isRecording = false

        if let sessionID = currentSessionID {
            transferManager.sendRecordingControl(action: .stop, sessionID: sessionID)
            let files = [currentCSVFileURL, currentAudioFileURL, currentMetadataFileURL].compactMap { $0 }
            transferManager.transferRecordingFiles(sessionID: sessionID, fileURLs: files)
            statusMessage = "Stopped (queued CSV + audio)"
        } else {
            statusMessage = "Stopped"
        }
    }

    private func appendSample(_ motion: CMDeviceMotion) {
        let timestamp = Date().timeIntervalSince1970
        let acceleration = motion.userAcceleration
        let gyro = motion.rotationRate
        let gravity = motion.gravity

        let accelMagnitude = magnitude3(x: acceleration.x, y: acceleration.y, z: acceleration.z)
        let gyroMagnitude = magnitude3(x: gyro.x, y: gyro.y, z: gyro.z)

        let line = String(
            format: "%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f\n",
            timestamp,
            acceleration.x, acceleration.y, acceleration.z,
            gyro.x, gyro.y, gyro.z,
            gravity.x, gravity.y, gravity.z
        )

        let handle = fileHandle

        fileQueue.async {
            guard let bytes = line.data(using: .utf8) else { return }

            do {
                try handle?.seekToEnd()
                try handle?.write(contentsOf: bytes)
            } catch {
                DispatchQueue.main.async {
                    self.setStatus("Write error: \(error.localizedDescription)")
                }
            }
        }

        DispatchQueue.main.async {
            self.latestAccelMagnitude = accelMagnitude
            self.latestGyroMagnitude = gyroMagnitude
            self.sampleCount += 1

            self.recentAccelMagnitudes.append(accelMagnitude)
            self.recentGyroMagnitudes.append(gyroMagnitude)

            if self.recentAccelMagnitudes.count > self.maxHistorySamples {
                self.recentAccelMagnitudes.removeFirst(self.recentAccelMagnitudes.count - self.maxHistorySamples)
            }
            if self.recentGyroMagnitudes.count > self.maxHistorySamples {
                self.recentGyroMagnitudes.removeFirst(self.recentGyroMagnitudes.count - self.maxHistorySamples)
            }
        }
    }

    private func magnitude3(x: Double, y: Double, z: Double) -> Double {
        sqrt((x * x) + (y * y) + (z * z))
    }

    private func requestAudioPermission() async -> Bool {
        let application = AVAudioApplication.shared

        switch application.recordPermission {
        case .granted:
            return true
        case .undetermined:
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    private func createRecordingFileURL(sessionID: String, fileExtension: String) throws -> URL {
        let documentsDirectory = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        return documentsDirectory.appendingPathComponent("recording_\(sessionID).\(fileExtension)")
    }

    private func createMetadataFileURL(sessionID: String) throws -> URL {
        let documentsDirectory = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        return documentsDirectory.appendingPathComponent("recording_\(sessionID).watch.json")
    }

    private func prepareLogFile(at url: URL) throws -> FileHandle {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let header = "timestamp,ax,ay,az,gx,gy,gz,grx,gry,grz\n"
        try header.write(to: url, atomically: true, encoding: .utf8)
        return try FileHandle(forWritingTo: url)
    }

    private func prepareAudioRecorder(at url: URL) throws -> AVAudioRecorder {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default)
        try session.setActive(true)

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]

        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.prepareToRecord()
        return recorder
    }

    private func saveWatchMetadata(to url: URL, metadata: WatchRecordingMetadata) throws {
        let data = try JSONEncoder().encode(metadata)
        try data.write(to: url, options: .atomic)
    }

    private func startCountdown(to plannedStartUnix: Double) {
        Task { [weak self] in
            guard let self else { return }

            while self.isArmed {
                let remaining = max(0, plannedStartUnix - Date().timeIntervalSince1970)

                await MainActor.run {
                    self.countdownSecondsRemaining = remaining
                }

                if remaining <= 0.05 {
                    break
                }

                try? await Task.sleep(nanoseconds: 100_000_000)
            }

            await MainActor.run {
                if self.isArmed {
                    self.countdownSecondsRemaining = 0
                }
            }
        }
    }

    private func cleanupIncompleteSession() {
        let fileManager = FileManager.default

        if let currentCSVFileURL {
            try? fileManager.removeItem(at: currentCSVFileURL)
        }
        if let currentAudioFileURL {
            try? fileManager.removeItem(at: currentAudioFileURL)
        }

        currentCSVFileURL = nil
        currentAudioFileURL = nil
        currentMetadataFileURL = nil
        currentSessionID = nil
        audioRecorder = nil
        fileHandle = nil
    }

    private static func makeSessionID() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: Date())
    }

    private func setStatus(_ message: String) {
        if Thread.isMainThread {
            statusMessage = message
        } else {
            DispatchQueue.main.async {
                self.statusMessage = message
            }
        }
    }
}
