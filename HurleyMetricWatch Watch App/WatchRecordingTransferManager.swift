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

    func transferRecording(at fileURL: URL) {
        guard WCSession.isSupported() else { return }

        let session = WCSession.default
        if session.activationState != .activated {
            session.delegate = self
            session.activate()
        }

        session.transferFile(fileURL, metadata: ["fileName": fileURL.lastPathComponent])
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        // No-op. Transfers are queued by the system when counterpart is unavailable.
    }
}
