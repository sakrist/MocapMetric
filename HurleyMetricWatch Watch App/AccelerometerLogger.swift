import Foundation
import CoreMotion
import Combine

final class AccelerometerLogger: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var sampleCount = 0
    @Published private(set) var currentFileName: String?
    @Published private(set) var latestAccelMagnitude = 0.0
    @Published private(set) var latestGyroMagnitude = 0.0
    @Published private(set) var recentAccelMagnitudes: [Double] = []
    @Published private(set) var recentGyroMagnitudes: [Double] = []
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
    private var currentFileURL: URL?

    private let maxHistorySamples = 150

    init() {
        transferManager.activate()
    }

    deinit {
        motionManager.stopDeviceMotionUpdates()
        try? fileHandle?.close()
    }

    func startLogging() {
        guard !isRecording else { return }
        guard motionManager.isDeviceMotionAvailable else {
            setStatus("Device motion unavailable")
            return
        }

        do {
            let fileURL = try createNewLogFileURL()
            let handle = try prepareLogFile(at: fileURL)
            fileHandle = handle
            currentFileURL = fileURL

            sampleCount = 0
            latestAccelMagnitude = 0
            latestGyroMagnitude = 0
            recentAccelMagnitudes.removeAll(keepingCapacity: true)
            recentGyroMagnitudes.removeAll(keepingCapacity: true)
            currentFileName = fileURL.lastPathComponent

            motionManager.deviceMotionUpdateInterval = 1.0 / 50.0
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
            statusMessage = "Recording"
        } catch {
            setStatus("Failed to start: \(error.localizedDescription)")
        }
    }

    func stopLogging() {
        guard isRecording else { return }

        motionManager.stopDeviceMotionUpdates()

        let handle = fileHandle
        fileHandle = nil

        fileQueue.sync {
            try? handle?.synchronize()
            try? handle?.close()
        }

        isRecording = false

        if let completedFileURL = currentFileURL {
            transferManager.transferRecording(at: completedFileURL)
            statusMessage = "Stopped (queued for phone)"
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

    private func createNewLogFileURL() throws -> URL {
        let documentsDirectory = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = formatter.string(from: Date())

        return documentsDirectory.appendingPathComponent("accelerometer_\(timestamp).csv")
    }

    private func prepareLogFile(at url: URL) throws -> FileHandle {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let header = "timestamp,ax,ay,az,gx,gy,gz,grx,gry,grz\n"
        try header.write(to: url, atomically: true, encoding: .utf8)
        return try FileHandle(forWritingTo: url)
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
