import Foundation
import WatchConnectivity
import SwiftUI
import Combine

struct RecordingSession: Identifiable {
    let id: String
    let createdAt: Date
    let csvURL: URL?
    let audioURL: URL?

    var title: String {
        id
    }

    var totalSizeBytes: Int64 {
        [csvURL, audioURL]
            .compactMap { $0 }
            .reduce(into: Int64(0)) { total, url in
                let values = try? url.resourceValues(forKeys: [.fileSizeKey])
                total += Int64(values?.fileSize ?? 0)
            }
    }

    var totalSizeLabel: String {
        ByteCountFormatter.string(fromByteCount: totalSizeBytes, countStyle: .file)
    }

    var shareItems: [URL] {
        [csvURL, audioURL].compactMap { $0 }
    }

    var detailLabel: String {
        var parts: [String] = []

        if csvURL != nil {
            parts.append("CSV")
        }
        if audioURL != nil {
            parts.append("Audio")
        }

        return parts.joined(separator: " + ")
    }
}

final class RecordingInboxStore: NSObject, ObservableObject {
    @Published private(set) var recordings: [RecordingSession] = []
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
                includingPropertiesForKeys: [.creationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )

            var groupedFiles: [String: (csvURL: URL?, audioURL: URL?, createdAt: Date)] = [:]

            for url in files {
                let values = try? url.resourceValues(forKeys: [.creationDateKey, .isRegularFileKey])
                guard values?.isRegularFile == true else { continue }

                let fileExtension = url.pathExtension.lowercased()
                guard fileExtension == "csv" || fileExtension == "m4a" else { continue }

                let sessionID = url.deletingPathExtension().lastPathComponent
                var entry = groupedFiles[sessionID] ?? (nil, nil, values?.creationDate ?? .distantPast)
                entry.createdAt = max(entry.createdAt, values?.creationDate ?? .distantPast)

                if fileExtension == "csv" {
                    entry.csvURL = url
                } else if fileExtension == "m4a" {
                    entry.audioURL = url
                }

                groupedFiles[sessionID] = entry
            }

            recordings = groupedFiles
                .map { key, value in
                    RecordingSession(
                        id: key,
                        createdAt: value.createdAt,
                        csvURL: value.csvURL,
                        audioURL: value.audioURL
                    )
                }
                .sorted { $0.createdAt > $1.createdAt }
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
