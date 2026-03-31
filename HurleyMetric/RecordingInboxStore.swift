import Foundation
import WatchConnectivity
import SwiftUI
import Combine

struct RecordingSession: Identifiable {
    let id: String
    let createdAt: Date
    let csvURL: URL?
    let audioURL: URL?
    let videoURL: URL?
    let phoneMetadataURL: URL?
    let watchMetadataURL: URL?

    var title: String {
        id
    }

    var totalSizeBytes: Int64 {
        [csvURL, audioURL, videoURL, phoneMetadataURL, watchMetadataURL]
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
        [csvURL, audioURL, videoURL, phoneMetadataURL, watchMetadataURL].compactMap { $0 }
    }

    var detailLabel: String {
        var parts: [String] = []

        if csvURL != nil {
            parts.append("CSV")
        }
        if audioURL != nil {
            parts.append("Audio")
        }
        if videoURL != nil {
            parts.append("Video")
        }
        if phoneMetadataURL != nil || watchMetadataURL != nil {
            parts.append("Metadata")
        }

        return parts.joined(separator: " + ")
    }
}

final class RecordingInboxStore: NSObject, ObservableObject {
    @Published private(set) var recordings: [RecordingSession] = []
    @Published private(set) var statusMessage = "Waiting for watch"
    private let videoRecorder: PhoneVideoRecorder

    init(videoRecorder: PhoneVideoRecorder) {
        self.videoRecorder = videoRecorder
        super.init()
        videoRecorder.onRecordingSaved = { [weak self] in
            self?.reloadRecordings()
        }
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

            var groupedFiles: [String: (csvURL: URL?, audioURL: URL?, videoURL: URL?, phoneMetadataURL: URL?, watchMetadataURL: URL?, createdAt: Date)] = [:]

            for url in files {
                let values = try? url.resourceValues(forKeys: [.creationDateKey, .isRegularFileKey])
                guard values?.isRegularFile == true else { continue }

                guard let parsedFile = Self.parseRecordingFileName(url.lastPathComponent) else { continue }

                var entry = groupedFiles[parsedFile.sessionID] ?? (nil, nil, nil, nil, nil, values?.creationDate ?? .distantPast)
                entry.createdAt = max(entry.createdAt, values?.creationDate ?? .distantPast)

                switch parsedFile.kind {
                case .csv:
                    entry.csvURL = url
                case .audio:
                    entry.audioURL = url
                case .video:
                    entry.videoURL = url
                case .phoneMetadata:
                    entry.phoneMetadataURL = url
                case .watchMetadata:
                    entry.watchMetadataURL = url
                }

                groupedFiles[parsedFile.sessionID] = entry
            }

            recordings = groupedFiles
                .map { key, value in
                    RecordingSession(
                        id: key,
                        createdAt: value.createdAt,
                        csvURL: value.csvURL,
                        audioURL: value.audioURL,
                        videoURL: value.videoURL,
                        phoneMetadataURL: value.phoneMetadataURL,
                        watchMetadataURL: value.watchMetadataURL
                    )
                }
                .sorted { $0.createdAt > $1.createdAt }
        } catch {
            statusMessage = "Load error: \(error.localizedDescription)"
        }
    }

    func deleteRecording(_ recording: RecordingSession) {
        let fileManager = FileManager.default
        let fileURLs = [
            recording.csvURL,
            recording.audioURL,
            recording.videoURL,
            recording.phoneMetadataURL,
            recording.watchMetadataURL,
        ].compactMap { $0 }

        do {
            for fileURL in fileURLs {
                if fileManager.fileExists(atPath: fileURL.path) {
                    try fileManager.removeItem(at: fileURL)
                }
            }

            statusMessage = "Deleted \(recording.title)"
            reloadRecordings()
        } catch {
            statusMessage = "Delete error: \(error.localizedDescription)"
        }
    }

    func deleteRecordings(at offsets: IndexSet) {
        let sessions = offsets.map { recordings[$0] }
        for session in sessions {
            deleteRecording(session)
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

    private enum ParsedRecordingFileKind {
        case csv
        case audio
        case video
        case phoneMetadata
        case watchMetadata
    }

    private struct ParsedRecordingFile {
        let sessionID: String
        let kind: ParsedRecordingFileKind
    }

    private static func parseRecordingFileName(_ fileName: String) -> ParsedRecordingFile? {
        if fileName.hasSuffix(".watch.json") {
            let sessionID = fileName.replacingOccurrences(of: ".watch.json", with: "")
            return ParsedRecordingFile(sessionID: sessionID, kind: .watchMetadata)
        }

        if fileName.hasSuffix(".phone.json") {
            let sessionID = fileName.replacingOccurrences(of: ".phone.json", with: "")
            return ParsedRecordingFile(sessionID: sessionID, kind: .phoneMetadata)
        }

        if fileName.hasSuffix(".csv") {
            let sessionID = fileName.replacingOccurrences(of: ".csv", with: "")
            return ParsedRecordingFile(sessionID: sessionID, kind: .csv)
        }

        if fileName.hasSuffix(".m4a") {
            let sessionID = fileName.replacingOccurrences(of: ".m4a", with: "")
            return ParsedRecordingFile(sessionID: sessionID, kind: .audio)
        }

        if fileName.hasSuffix(".mov") {
            let sessionID = fileName.replacingOccurrences(of: ".mov", with: "")
            return ParsedRecordingFile(sessionID: sessionID, kind: .video)
        }

        return nil
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

    func session(_ session: WCSession, didReceiveMessage message: [String : Any]) {
        guard
            let action = message["recordingControl"] as? String,
            let sessionID = message["sessionID"] as? String
        else {
            return
        }

        DispatchQueue.main.async {
            switch action {
            case "prepare":
                let leadTime = message["leadTime"] as? Double ?? 2.0
                let result = self.videoRecorder.prepareRemoteRecording(sessionID: sessionID, leadTime: leadTime)
                self.statusMessage = result.accepted ? "Video pre-roll armed" : "Video sync unavailable"
            case "start":
                self.videoRecorder.startRemoteRecording(sessionID: sessionID)
                self.statusMessage = "Watch started recording"
            case "stop":
                self.videoRecorder.stopRemoteRecording(sessionID: sessionID)
                self.statusMessage = "Watch stopped recording"
            default:
                break
            }
        }
    }

    func session(
        _ session: WCSession,
        didReceiveMessage message: [String : Any],
        replyHandler: @escaping ([String : Any]) -> Void
    ) {
        guard
            let action = message["recordingControl"] as? String,
            let sessionID = message["sessionID"] as? String
        else {
            replyHandler([:])
            return
        }

        guard action == "prepare" else {
            replyHandler([:])
            return
        }

        DispatchQueue.main.async {
            let leadTime = message["leadTime"] as? Double ?? 2.0
            let result = self.videoRecorder.prepareRemoteRecording(sessionID: sessionID, leadTime: leadTime)
            self.statusMessage = result.accepted ? "Video pre-roll armed" : "Video sync unavailable"
            replyHandler([
                "plannedStartUnix": result.plannedStartUnix,
                "accepted": result.accepted,
            ])
        }
    }
}
