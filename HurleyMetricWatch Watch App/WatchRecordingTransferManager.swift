import Foundation
import WatchConnectivity

final class WatchRecordingTransferManager: NSObject, WCSessionDelegate {
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

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        // No-op. Transfers are queued by the system when counterpart is unavailable.
    }
}
