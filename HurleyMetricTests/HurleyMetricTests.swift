import XCTest
@testable import HurleyMetric

final class HurleyMetricTests: XCTestCase {
    func testFixtureAlignmentUsesBothPhoneAndWatchSidecars() throws {
        let phoneMetadata = try VideoOverlayAlignment.loadPhoneMetadata(from: fixtureURL(named: "recording_20260329_172110.phone", ext: "json"))
        let watchMetadata = try VideoOverlayAlignment.loadWatchMetadata(from: fixtureURL(named: "recording_20260329_172110.watch", ext: "json"))
        let timestamps = try loadFixtureTimestamps(from: fixtureURL(named: "recording_20260329_172110", ext: "csv"), limit: 3)

        let solution = try VideoOverlayAlignment.solve(
            phoneMetadata: phoneMetadata,
            watchMetadata: watchMetadata
        )
        let videoTimes = try VideoOverlayAlignment.sampleVideoTimes(
            sampleTimestamps: timestamps,
            phoneMetadata: phoneMetadata,
            watchMetadata: watchMetadata
        )

        XCTAssertEqual(phoneMetadata.sessionID, "20260329_172110")
        XCTAssertEqual(watchMetadata.sessionID, "20260329_172110")
        XCTAssertEqual(solution.watchToPhoneClockOffset, -0.09527182579040527, accuracy: 0.000_001)
        XCTAssertEqual(solution.actualVideoStartUnix, 1774801270.938487, accuracy: 0.000_001)

        XCTAssertEqual(videoTimes[0], 2.0896012783050537, accuracy: 0.000_001)
        XCTAssertEqual(videoTimes[1], 2.098419189453125, accuracy: 0.000_001)
        XCTAssertEqual(videoTimes[2], 2.1085212230682373, accuracy: 0.000_001)

        let phoneOnlyFirstVideoTime = timestamps[0] - phoneMetadata.actualVideoStartUnix!
        XCTAssertEqual(phoneOnlyFirstVideoTime, 2.184873104095459, accuracy: 0.000_001)
        XCTAssertEqual(phoneOnlyFirstVideoTime - videoTimes[0], 0.09527182579040527, accuracy: 0.000_001)
    }

    func testAlignmentUsesPhoneAndWatchMetadataForVideoTime() throws {
        let phoneMetadata = VideoOverlayAlignment.PhoneRecordingMetadata(
            sessionID: "recording_20260329_172110",
            plannedStartUnix: 100.0,
            preRollStartUnix: 98.0,
            actualVideoStartUnix: 98.5,
            syncFlashUnix: 100.0,
            createdUnix: 98.0
        )
        let watchMetadata = VideoOverlayAlignment.WatchRecordingMetadata(
            sessionID: "recording_20260329_172110",
            plannedStartUnix: 100.0,
            actualWatchStartUnix: 100.2,
            requestedDeviceMotionInterval: 0.005,
            createdUnix: 100.2
        )

        let solution = try VideoOverlayAlignment.solve(
            phoneMetadata: phoneMetadata,
            watchMetadata: watchMetadata
        )

        XCTAssertEqual(solution.watchToPhoneClockOffset, -0.2, accuracy: 0.000_001)
        XCTAssertEqual(solution.actualVideoStartUnix, 98.5, accuracy: 0.000_001)

        let videoTimes = try VideoOverlayAlignment.sampleVideoTimes(
            sampleTimestamps: [100.2, 100.7, 101.2],
            phoneMetadata: phoneMetadata,
            watchMetadata: watchMetadata
        )

        XCTAssertEqual(videoTimes[0], 1.5, accuracy: 0.000_001)
        XCTAssertEqual(videoTimes[1], 2.0, accuracy: 0.000_001)
        XCTAssertEqual(videoTimes[2], 2.5, accuracy: 0.000_001)
    }

    func testAlignmentRejectsMismatchedSessionIDs() {
        let phoneMetadata = VideoOverlayAlignment.PhoneRecordingMetadata(
            sessionID: "recording_phone",
            plannedStartUnix: 100.0,
            preRollStartUnix: 98.0,
            actualVideoStartUnix: 98.5,
            syncFlashUnix: 100.0,
            createdUnix: 98.0
        )
        let watchMetadata = VideoOverlayAlignment.WatchRecordingMetadata(
            sessionID: "recording_watch",
            plannedStartUnix: 100.0,
            actualWatchStartUnix: 100.1,
            requestedDeviceMotionInterval: 0.005,
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
        let phoneMetadata = VideoOverlayAlignment.PhoneRecordingMetadata(
            sessionID: "recording_20260329_172110",
            plannedStartUnix: 100.0,
            preRollStartUnix: 98.0,
            actualVideoStartUnix: 98.5,
            syncFlashUnix: 100.0,
            createdUnix: 98.0
        )
        let watchMetadata = VideoOverlayAlignment.WatchRecordingMetadata(
            sessionID: "recording_20260329_172110",
            plannedStartUnix: 100.2,
            actualWatchStartUnix: 100.1,
            requestedDeviceMotionInterval: 0.005,
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

    func testMetadataCanBeLoadedFromJSONFiles() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let phoneURL = directoryURL.appendingPathComponent("recording_20260329_172110.phone.json")
        let watchURL = directoryURL.appendingPathComponent("recording_20260329_172110.watch.json")

        try """
        {
          "sessionID": "recording_20260329_172110",
          "plannedStartUnix": 100.0,
          "preRollStartUnix": 98.0,
          "actualVideoStartUnix": 98.5,
          "syncFlashUnix": 100.0,
          "createdUnix": 98.0
        }
        """.write(to: phoneURL, atomically: true, encoding: .utf8)

        try """
        {
          "sessionID": "recording_20260329_172110",
          "plannedStartUnix": 100.0,
          "actualWatchStartUnix": 100.2,
          "requestedDeviceMotionInterval": 0.005,
          "createdUnix": 100.2
        }
        """.write(to: watchURL, atomically: true, encoding: .utf8)

        let phoneMetadata = try VideoOverlayAlignment.loadPhoneMetadata(from: phoneURL)
        let watchMetadata = try VideoOverlayAlignment.loadWatchMetadata(from: watchURL)
        let videoTimes = try VideoOverlayAlignment.sampleVideoTimes(
            sampleTimestamps: [100.7],
            phoneMetadata: phoneMetadata,
            watchMetadata: watchMetadata
        )

        XCTAssertEqual(phoneMetadata.sessionID, "recording_20260329_172110")
        XCTAssertEqual(watchMetadata.sessionID, "recording_20260329_172110")
        XCTAssertEqual(videoTimes.count, 1)
        XCTAssertEqual(videoTimes[0], 2.0, accuracy: 0.000_001)
    }

    private func fixtureURL(named name: String, ext: String) throws -> URL {
        let directoryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        let fileURL = directoryURL.appendingPathComponent(name).appendingPathExtension(ext)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path), "Missing fixture: \(fileURL.lastPathComponent)")
        return fileURL
    }

    private func loadFixtureTimestamps(from url: URL, limit: Int) throws -> [Double] {
        let contents = try String(contentsOf: url, encoding: .utf8)
        return contents
            .split(whereSeparator: \.isNewline)
            .dropFirst()
            .prefix(limit)
            .compactMap { row in
                row.split(separator: ",", omittingEmptySubsequences: false).first.flatMap { Double($0) }
            }
    }
}
