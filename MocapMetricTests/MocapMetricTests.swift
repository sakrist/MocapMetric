import XCTest
import WatchMotionRecordingKit
@testable import MocapMetric

final class MocapMetricTests: XCTestCase {
    func testRecordingSessionDistinguishesPartialAndCompleteMotionSets() {
        let sessionID = "00112233-4455-4677-8899-aabbccddeeff"
        let deviceMotionURL = URL(fileURLWithPath: "/tmp/\(sessionID).device-motion.bin")
        let rawAccelerometerURL = URL(fileURLWithPath: "/tmp/\(sessionID).raw-accelerometer.bin")
        let watchMetadataURL = URL(fileURLWithPath: "/tmp/\(sessionID).watch.json")

        let partial = RecordingSession(
            id: sessionID,
            createdAt: .now,
            deviceMotionURL: deviceMotionURL,
            rawAccelerometerURL: nil,
            audioURL: nil,
            videoURL: nil,
            phoneMetadataURL: nil,
            watchMetadataURL: nil
        )
        let complete = RecordingSession(
            id: sessionID,
            createdAt: .now,
            deviceMotionURL: deviceMotionURL,
            rawAccelerometerURL: rawAccelerometerURL,
            audioURL: nil,
            videoURL: nil,
            phoneMetadataURL: nil,
            watchMetadataURL: watchMetadataURL
        )

        XCTAssertTrue(partial.hasPartialMotionSet)
        XCTAssertFalse(partial.hasCompleteMotionSet)
        XCTAssertFalse(complete.hasPartialMotionSet)
        XCTAssertTrue(complete.hasCompleteMotionSet)
    }

    @MainActor
    func testWatchStateUsesZeroPendingSessionsAsCompletedTransfer() {
        let store = RecordingInboxStore(
            videoRecorder: PhoneVideoRecorder(),
            shouldActivateSession: false
        )

        store.applyWatchState(WatchRecordingStateContext(
            isRecording: true,
            isSyncing: true,
            pendingSyncSessionCount: 2
        ))
        XCTAssertTrue(store.isWatchRecording)
        XCTAssertTrue(store.isWatchTransferring)
        XCTAssertEqual(store.pendingWatchSessionCount, 2)

        store.applyWatchState(WatchRecordingStateContext(
            isRecording: false,
            isSyncing: true,
            pendingSyncSessionCount: 0
        ))
        XCTAssertFalse(store.isWatchRecording)
        XCTAssertFalse(store.isWatchTransferring)
        XCTAssertEqual(store.pendingWatchSessionCount, 0)
    }

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

        let packageURL = RecordingPackageLayout.packageURL(in: directory, sessionID: sessionID)
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        for kind in [RecordingPackageAssetKind.deviceMotion, .rawAccelerometer, .watchMetadata] {
            let sourceURL: URL
            switch kind {
            case .deviceMotion:
                sourceURL = deviceURL
            case .rawAccelerometer:
                sourceURL = rawURL
            case .watchMetadata:
                sourceURL = metadataURL
            default:
                continue
            }
            try FileManager.default.moveItem(
                at: sourceURL,
                to: RecordingPackageLayout.assetURL(kind, in: packageURL, sessionID: sessionID)
            )
        }
        let package = try RecordingPackageDescriptor(packageURL: packageURL, expectedProfile: .core)

        let recording = RecordingSession(
            id: sessionID,
            createdAt: Date(),
            packageURL: packageURL,
            deviceMotionURL: package.deviceMotionURL,
            rawAccelerometerURL: package.rawAccelerometerURL,
            audioURL: package.audioURL,
            videoURL: package.videoURL,
            phoneMetadataURL: package.phoneMetadataURL,
            watchMetadataURL: package.watchMetadataURL
        )
        let decoded = try BinaryMotionReader().read(recording: recording)

        XCTAssertEqual(decoded.deviceMotion.count, 3)
        XCTAssertEqual(decoded.rawAcceleration.count, 9)
        XCTAssertEqual(decoded.deviceMotion[1].ax, 1, accuracy: 0.000_001)
        XCTAssertEqual(decoded.rawAcceleration[8].timestamp - decoded.rawAcceleration[0].timestamp, 0.01, accuracy: 0.000_001)
    }

    func testLateAudioDeliveryIsMergedIntoExistingRecordingPackage() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sessionID = "00112233-4455-4677-8899-aabbccddeeff"
        let coreAssets: [RecordingPackageAssetKind] = [.deviceMotion, .rawAccelerometer, .watchMetadata]
        for kind in coreAssets {
            let url = directory.appendingPathComponent(
                RecordingPackageLayout.assetFileName(kind, sessionID: sessionID)
            )
            try Data("core".utf8).write(to: url)
        }

        try RecordingInboxStore.assembleRecordingPackages(in: directory)
        let packageURL = RecordingPackageLayout.packageURL(in: directory, sessionID: sessionID)
        XCTAssertNil(try RecordingPackageDescriptor(packageURL: packageURL).audioURL)

        let audioURL = directory.appendingPathComponent(
            RecordingPackageLayout.assetFileName(.audio, sessionID: sessionID)
        )
        let audioData = Data("audio".utf8)
        try audioData.write(to: audioURL)

        try RecordingInboxStore.assembleRecordingPackages(in: directory)

        let package = try RecordingPackageDescriptor(packageURL: packageURL)
        let packagedAudioURL = try XCTUnwrap(package.audioURL)
        XCTAssertEqual(try Data(contentsOf: packagedAudioURL), audioData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MocapMetricTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
