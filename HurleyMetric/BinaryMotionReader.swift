import Foundation
import WatchMotionRecordingKit

struct RawAccelerationSample: Identifiable {
    let id: Int
    let timestamp: Double
    let ax: Double
    let ay: Double
    let az: Double

    var magnitude: Double {
        sqrt((ax * ax) + (ay * ay) + (az * az))
    }
}

struct DecodedMotionRecording {
    let deviceMotion: [MotionSample]
    let rawAcceleration: [RawAccelerationSample]
}

enum BinaryMotionReaderError: LocalizedError, Equatable {
    case incompleteMotionSet
    case invalidMetadata(String)
    case invalidBinary(String)
    case unsupportedFrequency(stream: String, actual: Int)
    case nonMonotonicTimestamps(stream: String)
    case emptyDeviceMotion

    var errorDescription: String? {
        switch self {
        case .incompleteMotionSet:
            return "The motion recording is still waiting for one or more binary assets."
        case .invalidMetadata(let reason):
            return "The Watch recording metadata is invalid: \(reason)"
        case .invalidBinary(let reason):
            return "The Watch binary recording is invalid: \(reason)"
        case .unsupportedFrequency(let stream, let actual):
            return "The \(stream) recording reports \(actual) Hz; HurleyMetric requires its native frequency."
        case .nonMonotonicTimestamps(let stream):
            return "The \(stream) recording timestamps are not monotonic."
        case .emptyDeviceMotion:
            return "The motion recording contains no device-motion samples."
        }
    }
}

struct BinaryMotionReader {
    nonisolated init() {}

    nonisolated func read(recording: RecordingSession) throws -> DecodedMotionRecording {
        guard let deviceMotionURL = recording.deviceMotionURL,
              let rawAccelerationURL = recording.rawAccelerometerURL,
              let metadataURL = recording.watchMetadataURL else {
            throw BinaryMotionReaderError.incompleteMotionSet
        }

        let metadata: WatchRecordingMetadata
        do {
            metadata = try JSONDecoder().decode(
                WatchRecordingMetadata.self,
                from: Data(contentsOf: metadataURL)
            )
        } catch {
            throw BinaryMotionReaderError.invalidMetadata(error.localizedDescription)
        }

        try validateMetadata(
            metadata,
            recording: recording,
            deviceMotionURL: deviceMotionURL,
            rawAccelerationURL: rawAccelerationURL,
            metadataURL: metadataURL
        )

        let deviceData = try loadData(from: deviceMotionURL)
        let rawData = try loadData(from: rawAccelerationURL)
        let deviceMotion = try readDeviceMotion(
            from: deviceData,
            expectedSessionID: recording.id
        )
        let rawAcceleration = try readRawAcceleration(
            from: rawData,
            expectedSessionID: recording.id
        )

        guard !deviceMotion.isEmpty else {
            throw BinaryMotionReaderError.emptyDeviceMotion
        }
        guard UInt64(deviceMotion.count) == metadata.deviceMotionSampleCount,
              UInt64(rawAcceleration.count) == metadata.rawAccelerometerSampleCount else {
            throw BinaryMotionReaderError.invalidMetadata("binary sample counts do not match the Watch sidecar")
        }
        return DecodedMotionRecording(
            deviceMotion: deviceMotion,
            rawAcceleration: rawAcceleration
        )
    }

    private nonisolated func validateMetadata(
        _ metadata: WatchRecordingMetadata,
        recording: RecordingSession,
        deviceMotionURL: URL,
        rawAccelerationURL: URL,
        metadataURL: URL
    ) throws {
        guard sessionIDsMatch(metadata.sessionID, recording.id) else {
            throw BinaryMotionReaderError.invalidMetadata("session identifier does not match the inbox group")
        }
        guard let deviceFileName = metadata.deviceMotionFileName,
              let rawFileName = metadata.rawAccelerometerFileName,
              let deviceByteCount = metadata.deviceMotionByteCount,
              let rawByteCount = metadata.rawAccelerometerByteCount,
              let deviceHash = metadata.deviceMotionSHA256,
              let rawHash = metadata.rawAccelerometerSHA256,
              let deviceFormatVersion = metadata.deviceMotionFormatVersion,
              let rawFormatVersion = metadata.rawAccelerometerFormatVersion,
              let deviceSampleCount = metadata.deviceMotionSampleCount,
              let rawSampleCount = metadata.rawAccelerometerSampleCount else {
            throw BinaryMotionReaderError.invalidMetadata("finalized binary asset details are incomplete")
        }

        guard deviceFileName == deviceMotionURL.lastPathComponent,
              rawFileName == rawAccelerationURL.lastPathComponent,
              metadataURL.lastPathComponent == WatchRecordingAssetNaming.metadataFileName(sessionID: recording.id) else {
            throw BinaryMotionReaderError.invalidMetadata("asset filenames do not match the session")
        }
        guard deviceFormatVersion == WatchMotionBinaryContract.formatVersion,
              rawFormatVersion == WatchMotionBinaryContract.formatVersion else {
            throw BinaryMotionReaderError.invalidMetadata("unsupported binary format version")
        }
        guard metadata.actualDeviceMotionFrequency == Int(WatchMotionBinaryStream.deviceMotion.nominalFrequencyHz),
              metadata.actualRawAccelerometerFrequency == Int(WatchMotionBinaryStream.rawAccelerometer.nominalFrequencyHz) else {
            throw BinaryMotionReaderError.invalidMetadata("native stream frequencies are not 200/800 Hz")
        }

        let actualDeviceByteCount = try WatchMotionFileIntegrity.byteCount(for: deviceMotionURL)
        let actualRawByteCount = try WatchMotionFileIntegrity.byteCount(for: rawAccelerationURL)
        guard actualDeviceByteCount == deviceByteCount,
              actualRawByteCount == rawByteCount else {
            throw BinaryMotionReaderError.invalidMetadata("binary byte counts do not match the Watch sidecar")
        }
        guard try WatchMotionFileIntegrity.sha256Hex(for: deviceMotionURL) == deviceHash,
              try WatchMotionFileIntegrity.sha256Hex(for: rawAccelerationURL) == rawHash else {
            throw BinaryMotionReaderError.invalidMetadata("binary integrity hashes do not match the Watch sidecar")
        }
        guard deviceSampleCount > 0, rawSampleCount > 0 else {
            throw BinaryMotionReaderError.invalidMetadata("the finalized binary streams are empty")
        }
    }

    private nonisolated func loadData(from url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw BinaryMotionReaderError.invalidBinary(error.localizedDescription)
        }
    }

    private nonisolated func readDeviceMotion(from data: Data, expectedSessionID: String) throws -> [MotionSample] {
        let header = try decodeHeader(
            from: data,
            expectedStream: .deviceMotion,
            expectedSessionID: expectedSessionID
        )
        guard header.actualFrequencyHz == WatchMotionBinaryStream.deviceMotion.nominalFrequencyHz else {
            throw BinaryMotionReaderError.unsupportedFrequency(
                stream: "device motion",
                actual: Int(header.actualFrequencyHz)
            )
        }
        let count = try checkedCount(header.sampleCount)
        var samples: [MotionSample] = []
        samples.reserveCapacity(count)
        var previousTimestamp: Int64?

        for index in 0..<count {
            let record = try deviceRecord(at: index, in: data)
            if let previousTimestamp, record.timestampUnixMicroseconds < previousTimestamp {
                throw BinaryMotionReaderError.nonMonotonicTimestamps(stream: "device motion")
            }
            previousTimestamp = record.timestampUnixMicroseconds
            let values = [
                record.userAccelerationX, record.userAccelerationY, record.userAccelerationZ,
                record.rotationRateX, record.rotationRateY, record.rotationRateZ,
                record.gravityX, record.gravityY, record.gravityZ,
            ]
            guard values.allSatisfy(\.isFinite) else {
                throw BinaryMotionReaderError.invalidBinary("device motion contains a non-finite value")
            }
            samples.append(MotionSample(
                id: index,
                timestamp: Double(record.timestampUnixMicroseconds) / 1_000_000,
                ax: record.userAccelerationX,
                ay: record.userAccelerationY,
                az: record.userAccelerationZ,
                gx: record.rotationRateX,
                gy: record.rotationRateY,
                gz: record.rotationRateZ,
                grx: record.gravityX,
                gry: record.gravityY,
                grz: record.gravityZ,
                accMagnitude: magnitude(x: record.userAccelerationX, y: record.userAccelerationY, z: record.userAccelerationZ),
                gyroMagnitude: magnitude(x: record.rotationRateX, y: record.rotationRateY, z: record.rotationRateZ)
            ))
        }
        return samples
    }

    private nonisolated func readRawAcceleration(from data: Data, expectedSessionID: String) throws -> [RawAccelerationSample] {
        let header = try decodeHeader(
            from: data,
            expectedStream: .rawAccelerometer,
            expectedSessionID: expectedSessionID
        )
        guard header.actualFrequencyHz == WatchMotionBinaryStream.rawAccelerometer.nominalFrequencyHz else {
            throw BinaryMotionReaderError.unsupportedFrequency(
                stream: "raw acceleration",
                actual: Int(header.actualFrequencyHz)
            )
        }
        let count = try checkedCount(header.sampleCount)
        var samples: [RawAccelerationSample] = []
        samples.reserveCapacity(count)
        var previousTimestamp: Int64?

        for index in 0..<count {
            let record = try rawRecord(at: index, in: data)
            if let previousTimestamp, record.timestampUnixMicroseconds < previousTimestamp {
                throw BinaryMotionReaderError.nonMonotonicTimestamps(stream: "raw acceleration")
            }
            previousTimestamp = record.timestampUnixMicroseconds
            guard [record.rawAccelerationX, record.rawAccelerationY, record.rawAccelerationZ].allSatisfy(\.isFinite) else {
                throw BinaryMotionReaderError.invalidBinary("raw acceleration contains a non-finite value")
            }
            samples.append(RawAccelerationSample(
                id: index,
                timestamp: Double(record.timestampUnixMicroseconds) / 1_000_000,
                ax: record.rawAccelerationX,
                ay: record.rawAccelerationY,
                az: record.rawAccelerationZ
            ))
        }
        return samples
    }

    private nonisolated func decodeHeader(
        from data: Data,
        expectedStream: WatchMotionBinaryStream,
        expectedSessionID: String
    ) throws -> WatchMotionBinaryHeader {
        do {
            guard data.count >= WatchMotionBinaryContract.headerByteCount else {
                throw BinaryMotionReaderError.invalidBinary("binary header is truncated")
            }
            let header = try WatchMotionBinaryHeader.decode(
                from: Data(data.prefix(WatchMotionBinaryContract.headerByteCount)),
                expectedStream: expectedStream,
                expectedSessionID: expectedSessionID
            )
            try header.validateFileByteCount(data.count)
            return header
        } catch let error as BinaryMotionReaderError {
            throw error
        } catch WatchMotionBinaryError.unsupportedVersion(let version) {
            throw BinaryMotionReaderError.invalidBinary("unsupported binary version \(version)")
        } catch {
            throw BinaryMotionReaderError.invalidBinary(error.localizedDescription)
        }
    }

    private nonisolated func deviceRecord(at index: Int, in data: Data) throws -> WatchDeviceMotionBinaryRecord {
        let start = WatchMotionBinaryContract.headerByteCount + (index * WatchMotionBinaryContract.deviceMotionRecordByteCount)
        let end = start + WatchMotionBinaryContract.deviceMotionRecordByteCount
        guard start >= 0, end <= data.count else {
            throw BinaryMotionReaderError.invalidBinary("device-motion record is truncated")
        }
        do {
            return try WatchDeviceMotionBinaryRecord.decode(from: Data(data[start..<end]))
        } catch {
            throw BinaryMotionReaderError.invalidBinary(error.localizedDescription)
        }
    }

    private nonisolated func rawRecord(at index: Int, in data: Data) throws -> WatchRawAccelerometerBinaryRecord {
        let start = WatchMotionBinaryContract.headerByteCount + (index * WatchMotionBinaryContract.rawAccelerometerRecordByteCount)
        let end = start + WatchMotionBinaryContract.rawAccelerometerRecordByteCount
        guard start >= 0, end <= data.count else {
            throw BinaryMotionReaderError.invalidBinary("raw-acceleration record is truncated")
        }
        do {
            return try WatchRawAccelerometerBinaryRecord.decode(from: Data(data[start..<end]))
        } catch {
            throw BinaryMotionReaderError.invalidBinary(error.localizedDescription)
        }
    }

    private nonisolated func checkedCount(_ value: UInt64) throws -> Int {
        guard value <= UInt64(Int.max) else {
            throw BinaryMotionReaderError.invalidBinary("sample count is too large")
        }
        return Int(value)
    }

    private nonisolated func sessionIDsMatch(_ lhs: String, _ rhs: String) -> Bool {
        guard let lhs = UUID(uuidString: lhs), let rhs = UUID(uuidString: rhs) else { return lhs == rhs }
        return lhs == rhs
    }

    private nonisolated func magnitude(x: Double, y: Double, z: Double) -> Double {
        sqrt((x * x) + (y * y) + (z * z))
    }
}
