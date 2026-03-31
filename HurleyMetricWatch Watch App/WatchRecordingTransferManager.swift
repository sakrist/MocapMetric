import Foundation
import WatchConnectivity

final class WatchRecordingTransferManager: NSObject, WCSessionDelegate {
    enum RecordingControlAction: String {
        case prepare
        case start
        case stop
    }

    struct ScheduledStartResponse {
        let plannedStartUnix: Double
        let accepted: Bool
    }

    static let shared = WatchRecordingTransferManager()

    private override init() {
        super.init()
    }

    func activate() {
        guard WCSession.isSupported() else { return }

        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    func transferRecordingFiles(sessionID: String, fileURLs: [URL]) {
        guard WCSession.isSupported() else { return }

        let session = WCSession.default
        if session.activationState != .activated {
            session.delegate = self
            session.activate()
        }

        for fileURL in fileURLs {
            session.transferFile(fileURL, metadata: [
                "fileName": fileURL.lastPathComponent,
                "sessionID": sessionID,
            ])
        }
    }

    func sendRecordingControl(action: RecordingControlAction, sessionID: String) {
        guard WCSession.isSupported() else { return }

        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { return }

        session.sendMessage([
            "recordingControl": action.rawValue,
            "sessionID": sessionID,
        ], replyHandler: nil, errorHandler: nil)
    }

    func requestScheduledStart(sessionID: String, leadTime: TimeInterval) async -> ScheduledStartResponse? {
        guard WCSession.isSupported() else { return nil }

        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { return nil }

        return await withCheckedContinuation { continuation in
            session.sendMessage([
                "recordingControl": RecordingControlAction.prepare.rawValue,
                "sessionID": sessionID,
                "leadTime": leadTime,
            ], replyHandler: { reply in
                guard
                    let plannedStartUnix = reply["plannedStartUnix"] as? Double,
                    let accepted = reply["accepted"] as? Bool
                else {
                    continuation.resume(returning: nil)
                    return
                }

                continuation.resume(returning: ScheduledStartResponse(
                    plannedStartUnix: plannedStartUnix,
                    accepted: accepted
                ))
            }, errorHandler: { _ in
                continuation.resume(returning: nil)
            })
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        // No-op. Transfers are queued by the system when counterpart is unavailable.
    }
}
