import Foundation
import WatchConnectivity
import SwiftUI
import Combine

struct RecordingFile: Identifiable {
    let id: URL
    let url: URL
    let createdAt: Date
    let fileSizeBytes: Int64

    var fileName: String {
        url.lastPathComponent
    }

    var fileSizeLabel: String {
        ByteCountFormatter.string(fromByteCount: fileSizeBytes, countStyle: .file)
    }
}

final class RecordingInboxStore: NSObject, ObservableObject {
    @Published private(set) var recordings: [RecordingFile] = []
    @Published private(set) var statusMessage = "Waiting for watch"

    override init() {
        super.init()
        reloadRecordings()
        activateSession()
    }

    func reloadRecordings() {
        let directoryURL = Self.recordingsDirectoryURL()
        let fileManager = FileManager.default

        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let files = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.creationDateKey, .isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )

            let loadedRecordings = files.compactMap { url -> RecordingFile? in
                guard url.pathExtension.lowercased() == "csv" else { return nil }

                let values = try? url.resourceValues(forKeys: [.creationDateKey, .isRegularFileKey, .fileSizeKey])
                guard values?.isRegularFile == true else { return nil }

                return RecordingFile(
                    id: url,
                    url: url,
                    createdAt: values?.creationDate ?? .distantPast,
                    fileSizeBytes: Int64(values?.fileSize ?? 0)
                )
            }
            .sorted { $0.createdAt > $1.createdAt }

            recordings = loadedRecordings
        } catch {
            statusMessage = "Load error: \(error.localizedDescription)"
        }
    }

    private func activateSession() {
        guard WCSession.isSupported() else {
            statusMessage = "WatchConnectivity unavailable"
            return
        }

        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    private func handleReceivedFile(_ file: WCSessionFile) {
        let fileManager = FileManager.default
        let directoryURL = Self.recordingsDirectoryURL()

        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

            let requestedName = (file.metadata?["fileName"] as? String) ?? file.fileURL.lastPathComponent
            let destinationURL = Self.uniqueDestinationURL(in: directoryURL, preferredName: requestedName)

            try fileManager.copyItem(at: file.fileURL, to: destinationURL)

            DispatchQueue.main.async {
                self.statusMessage = "Received \(destinationURL.lastPathComponent)"
                self.reloadRecordings()
            }
        } catch {
            DispatchQueue.main.async {
                self.statusMessage = "Import error: \(error.localizedDescription)"
            }
        }
    }

    private static func recordingsDirectoryURL() -> URL {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documentsURL.appendingPathComponent("WatchRecordings", isDirectory: true)
    }

    private static func uniqueDestinationURL(in directoryURL: URL, preferredName: String) -> URL {
        let baseName = (preferredName as NSString).deletingPathExtension
        let pathExtension = (preferredName as NSString).pathExtension

        var candidateURL = directoryURL.appendingPathComponent(preferredName)
        var suffix = 1

        while FileManager.default.fileExists(atPath: candidateURL.path) {
            let candidateName: String
            if pathExtension.isEmpty {
                candidateName = "\(baseName)_\(suffix)"
            } else {
                candidateName = "\(baseName)_\(suffix).\(pathExtension)"
            }

            candidateURL = directoryURL.appendingPathComponent(candidateName)
            suffix += 1
        }

        return candidateURL
    }
}

extension RecordingInboxStore: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async {
            if let error {
                self.statusMessage = "Session error: \(error.localizedDescription)"
            } else {
                self.statusMessage = "Waiting for watch"
            }
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {
        // Required on iOS.
    }

    func sessionDidDeactivate(_ session: WCSession) {
        // Required on iOS. Re-activate after watch switch.
        session.activate()
    }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        handleReceivedFile(file)
    }
}
