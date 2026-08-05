import XCTest
import WatchMotionRecordingKit
@testable import HurleyMetric

final class HurleyMetricTests: XCTestCase {
    func testAlignmentUsesPhoneFirstVideoFrameAndValidatesWatchSidecar() throws {
        let sessionID = "00112233-4455-4677-8899-aabbccddeeff"
        let phoneMetadata = PhoneRecordingMetadata(
            sessionID: sessionID,
            plannedStartUnix: 100.0,
            preRollStartUnix: 98.0,
            actualVideoStartUnix: 98.5,
            syncFlashUnix: 100.0,
            createdUnix: 98.0
        )
        let watchMetadata = WatchRecordingMetadata(
            sessionID: sessionID,
            plannedStartUnix: 100.0,
            actualWatchStartUnix: 100.2,
            createdUnix: 100.2
        )

        let solution = try VideoOverlayAlignment.solve(
            phoneMetadata: phoneMetadata,
            watchMetadata: watchMetadata
        )
        let videoTimes = try VideoOverlayAlignment.sampleVideoTimes(
            sampleTimestamps: [100.2, 100.7, 101.2],
            phoneMetadata: phoneMetadata,
            watchMetadata: watchMetadata
        )

        XCTAssertEqual(solution.watchToPhoneClockOffset, 0, accuracy: 0.000_001)
        XCTAssertEqual(solution.actualVideoStartUnix, 98.5, accuracy: 0.000_001)
        XCTAssertEqual(videoTimes[0], 1.7, accuracy: 0.000_001)
        XCTAssertEqual(videoTimes[1], 2.2, accuracy: 0.000_001)
        XCTAssertEqual(videoTimes[2], 2.7, accuracy: 0.000_001)
    }

    func testAlignmentRejectsMismatchedSessionIDs() {
        let phoneMetadata = PhoneRecordingMetadata(
            sessionID: "00112233-4455-4677-8899-aabbccddeeff",
            plannedStartUnix: 100,
            preRollStartUnix: 98,
            actualVideoStartUnix: 98.5,
            syncFlashUnix: 100,
            createdUnix: 98
        )
        let watchMetadata = WatchRecordingMetadata(
            sessionID: "10112233-4455-4677-8899-aabbccddeeff",
            plannedStartUnix: 100,
            actualWatchStartUnix: 100.1,
            createdUnix: 100.1
        )

        XCTAssertThrowsError(
            try VideoOverlayAlignment.solve(
                phoneMetadata: phoneMetadata,
                watchMetadata: watchMetadata
            )
        ) { error in
            XCTAssertEqual(error as? VideoOverlayExporterError, .mismatchedSessionID)
        }
    }

    func testAlignmentRejectsMismatchedPlannedStart() {
        let sessionID = "00112233-4455-4677-8899-aabbccddeeff"
        let phoneMetadata = PhoneRecordingMetadata(
            sessionID: sessionID,
            plannedStartUnix: 100,
            preRollStartUnix: 98,
            actualVideoStartUnix: 98.5,
            syncFlashUnix: 100,
            createdUnix: 98
        )
        let watchMetadata = WatchRecordingMetadata(
            sessionID: sessionID,
            plannedStartUnix: 100.2,
            actualWatchStartUnix: 100.1,
            createdUnix: 100.1
        )

        XCTAssertThrowsError(
            try VideoOverlayAlignment.solve(
                phoneMetadata: phoneMetadata,
                watchMetadata: watchMetadata
            )
        ) { error in
            XCTAssertEqual(error as? VideoOverlayExporterError, .mismatchedPlannedStart)
        }
    }

    func testBinaryReaderLoadsBothNativeStreamsAndPreserves800HzSamples() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sessionID = "00112233-4455-4677-8899-aabbccddeeff"
        let deviceURL = directory.appendingPathComponent(
            WatchRecordingAssetNaming.deviceMotionFileName(sessionID: sessionID)
        )
        let rawURL = directory.appendingPathComponent(
            WatchRecordingAssetNaming.rawAccelerometerFileName(sessionID: sessionID)
        )
        let metadataURL = directory.appendingPathComponent(
            WatchRecordingAssetNaming.metadataFileName(sessionID: sessionID)
        )

        let deviceWriter = try WatchMotionBinaryFileWriter(
            stream: .deviceMotion,
            fileURL: deviceURL,
            sessionID: sessionID
        )
        let rawWriter = try WatchMotionBinaryFileWriter(
            stream: .rawAccelerometer,
            fileURL: rawURL,
            sessionID: sessionID
        )

        for index in 0..<3 {
            try deviceWriter.append(WatchDeviceMotionBinaryRecord(
                timestampUnixMicroseconds: 1_700_000_000_000_000 + Int64(index * 5_000),
                userAccelerationX: Double(index),
                userAccelerationY: 0,
                userAccelerationZ: 0,
                rotationRateX: 0,
                rotationRateY: 0,
                rotationRateZ: 0,
                gravityX: 0,
                gravityY: 0,
                gravityZ: 1,
                quaternionW: 1,
                quaternionX: 0,
                quaternionY: 0,
                quaternionZ: 0
            ))
        }
        for index in 0..<9 {
            try rawWriter.append(WatchRawAccelerometerBinaryRecord(
                timestampUnixMicroseconds: 1_700_000_000_000_000 + Int64(index * 1_250),
                rawAccelerationX: Double(index),
                rawAccelerationY: 0,
                rawAccelerationZ: 1
            ))
        }

        let deviceSummary = try deviceWriter.finalize(actualFrequencyHz: 200)
        let rawSummary = try rawWriter.finalize(actualFrequencyHz: 800)
        let metadata = WatchRecordingMetadata(
            sessionID: sessionID,
            plannedStartUnix: 1_700_000_000,
            actualWatchStartUnix: 1_700_000_000,
            createdUnix: 1_700_000_000
        ).finalized(deviceMotion: deviceSummary, rawAccelerometer: rawSummary)
        try JSONEncoder().encode(metadata).write(to: metadataURL)

        let recording = RecordingSession(
            id: sessionID,
            createdAt: Date(),
            deviceMotionURL: deviceURL,
            rawAccelerometerURL: rawURL,
            audioURL: nil,
            videoURL: nil,
            phoneMetadataURL: nil,
            watchMetadataURL: metadataURL
        )
        let decoded = try BinaryMotionReader().read(recording: recording)

        XCTAssertEqual(decoded.deviceMotion.count, 3)
        XCTAssertEqual(decoded.rawAcceleration.count, 9)
        XCTAssertEqual(decoded.deviceMotion[1].ax, 1, accuracy: 0.000_001)
        XCTAssertEqual(decoded.rawAcceleration[8].timestamp - decoded.rawAcceleration[0].timestamp, 0.01, accuracy: 0.000_001)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("HurleyMetricTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
