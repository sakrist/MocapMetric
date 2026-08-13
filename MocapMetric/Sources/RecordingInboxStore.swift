import Foundation
import WatchConnectivity
import SwiftUI
import Combine
import WatchMotionRecordingKit

struct RecordingSession: Identifiable {
    let id: String
    let createdAt: Date
    let packageURL: URL?
    let deviceMotionURL: URL?
    let rawAccelerometerURL: URL?
    let audioURL: URL?
    let videoURL: URL?
    let phoneMetadataURL: URL?
    let watchMetadataURL: URL?

    init(
        id: String,
        createdAt: Date,
        packageURL: URL? = nil,
        deviceMotionURL: URL?,
        rawAccelerometerURL: URL?,
        audioURL: URL?,
        videoURL: URL?,
        phoneMetadataURL: URL?,
        watchMetadataURL: URL?
    ) {
        self.id = id
        self.createdAt = createdAt
        self.packageURL = packageURL
        self.deviceMotionURL = deviceMotionURL
        self.rawAccelerometerURL = rawAccelerometerURL
        self.audioURL = audioURL
        self.videoURL = videoURL
        self.phoneMetadataURL = phoneMetadataURL
        self.watchMetadataURL = watchMetadataURL
    }

    var title: String {
        id
    }

    var totalSizeBytes: Int64 {
        [deviceMotionURL, rawAccelerometerURL, audioURL, videoURL, phoneMetadataURL, watchMetadataURL]
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
        if let packageURL {
            return [packageURL]
        }
        return [deviceMotionURL, rawAccelerometerURL, audioURL, videoURL, phoneMetadataURL, watchMetadataURL].compactMap { $0 }
    }

    var hasCompleteMotionSet: Bool {
        deviceMotionURL != nil && rawAccelerometerURL != nil && watchMetadataURL != nil
    }

    var hasPartialMotionSet: Bool {
        !hasCompleteMotionSet
            && (deviceMotionURL != nil || rawAccelerometerURL != nil || watchMetadataURL != nil)
    }

    var detailLabel: String {
        var parts: [String] = []

        if deviceMotionURL != nil {
            parts.append("Motion 200 Hz")
        }
        if rawAccelerometerURL != nil {
            parts.append("Raw acceleration 800 Hz")
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
    @Published private(set) var isWatchConnected = false
    @Published private(set) var isWatchRecording = false
    @Published private(set) var isWatchTransferring = false
    @Published private(set) var pendingWatchSessionCount = 0
    @Published private(set) var isReceivingFile = false
    private let videoRecorder: PhoneVideoRecorder
    private var fileReceiptActivityTask: Task<Void, Never>?

    init(videoRecorder: PhoneVideoRecorder, shouldActivateSession: Bool = true) {
        self.videoRecorder = videoRecorder
        super.init()
        videoRecorder.onRecordingSaved = { [weak self] in
            self?.reloadRecordings()
        }
        if shouldActivateSession {
            syncWithWatch()
        } else {
            reloadRecordings()
        }
    }

    deinit {
        fileReceiptActivityTask?.cancel()
    }

    var isSyncActive: Bool {
        isWatchTransferring || isReceivingFile
    }

    func syncWithWatch() {
        reloadRecordings()
        activateSession()
        requestPendingRecordingRetryIfNeeded()
    }

    func reloadRecordings() {
        let directoryURL = Self.recordingsDirectoryURL()
        let fileManager = FileManager.default

        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try Self.assembleRecordingPackages(in: directoryURL)
            let files = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )

            var groupedFiles: [String: (packageURL: URL?, deviceMotionURL: URL?, rawAccelerometerURL: URL?, audioURL: URL?, videoURL: URL?, phoneMetadataURL: URL?, watchMetadataURL: URL?, createdAt: Date)] = [:]

            for url in files {
                let values = try? url.resourceValues(forKeys: [.creationDateKey, .isDirectoryKey, .isRegularFileKey])
                if values?.isDirectory == true,
                   let sessionID = RecordingPackageLayout.sessionID(fromPackageDirectoryName: url.lastPathComponent),
                   let descriptor = try? RecordingPackageDescriptor(packageURL: url) {
                    var entry = groupedFiles[sessionID] ?? (nil, nil, nil, nil, nil, nil, nil, .distantPast)
                    entry.packageURL = url
                    entry.deviceMotionURL = descriptor.deviceMotionURL
                    entry.rawAccelerometerURL = descriptor.rawAccelerometerURL
                    entry.audioURL = descriptor.audioURL
                    entry.videoURL = descriptor.videoURL
                    entry.phoneMetadataURL = descriptor.phoneMetadataURL
                    entry.watchMetadataURL = descriptor.watchMetadataURL
                    entry.createdAt = max(entry.createdAt, values?.creationDate ?? .distantPast)
                    groupedFiles[sessionID] = entry
                    continue
                }
                guard values?.isRegularFile == true else { continue }

                guard let parsedFile = Self.parseRecordingFileName(url.lastPathComponent) else { continue }

                var entry = groupedFiles[parsedFile.sessionID] ?? (nil, nil, nil, nil, nil, nil, nil, values?.creationDate ?? .distantPast)
                entry.createdAt = max(entry.createdAt, values?.creationDate ?? .distantPast)

                switch parsedFile.kind {
                case .deviceMotion:
                    entry.deviceMotionURL = url
                case .rawAccelerometer:
                    entry.rawAccelerometerURL = url
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
                        packageURL: value.packageURL,
                        deviceMotionURL: value.deviceMotionURL,
                        rawAccelerometerURL: value.rawAccelerometerURL,
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
        if let packageURL = recording.packageURL {
            try? fileManager.removeItem(at: packageURL)
        }
        let fileURLs = [
            recording.deviceMotionURL,
            recording.rawAccelerometerURL,
            recording.audioURL,
            recording.videoURL,
            recording.phoneMetadataURL,
            recording.watchMetadataURL,
        ].compactMap { $0 }

        do {
            let directoryURL = Self.recordingsDirectoryURL()
            let stagedFiles = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            for fileURL in stagedFiles where Self.parseRecordingFileName(fileURL.lastPathComponent)?.sessionID == recording.id {
                try? fileManager.removeItem(at: fileURL)
            }
            for fileURL in fileURLs {
                if fileManager.fileExists(atPath: fileURL.path), fileURL != recording.packageURL {
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

    /// Combines WatchConnectivity's individual retryable files into one
    /// package. A package is only replaced after its complete visible contents
    /// pass the shared filesystem validation.
    static func assembleRecordingPackages(in directoryURL: URL) throws {
        let fileManager = FileManager.default
        let files = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        var staged: [String: [ParsedRecordingFileKind: URL]] = [:]

        for fileURL in files {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true,
                  let parsed = parseRecordingFileName(fileURL.lastPathComponent) else { continue }
            staged[parsed.sessionID, default: [:]][parsed.kind] = fileURL
        }

        for (sessionID, assets) in staged {
            let packageURL = RecordingPackageLayout.packageURL(in: directoryURL, sessionID: sessionID)
            let existingDescriptor = try? RecordingPackageDescriptor(packageURL: packageURL)
            let hasCoreAssets = assets[.deviceMotion] != nil
                && assets[.rawAccelerometer] != nil
                && assets[.watchMetadata] != nil

            // Optional WatchConnectivity files can arrive after the core files
            // have already been assembled. Reopen the existing package so a
            // late audio file is merged instead of being left beside it.
            guard existingDescriptor != nil || hasCoreAssets else { continue }

            let hasVideo = assets[.video] != nil || existingDescriptor?.videoURL != nil
            let hasPhoneMetadata = assets[.phoneMetadata] != nil || existingDescriptor?.phoneMetadataURL != nil
            if hasVideo, !hasPhoneMetadata {
                continue
            }
            let temporaryContainerURL = directoryURL.appendingPathComponent(
                ".incoming-\(sessionID)-\(UUID().uuidString)",
                isDirectory: true
            )
            let temporaryPackageURL = temporaryContainerURL.appendingPathComponent(
                RecordingPackageLayout.packageDirectoryName(sessionID: sessionID),
                isDirectory: true
            )
            let backupURL = directoryURL.appendingPathComponent(
                ".backup-\(sessionID)-\(UUID().uuidString)",
                isDirectory: true
            )
            let stagedAssets: [(RecordingPackageAssetKind, URL)] = [
                (.deviceMotion, assets[.deviceMotion]),
                (.rawAccelerometer, assets[.rawAccelerometer]),
                (.watchMetadata, assets[.watchMetadata]),
                (.audio, assets[.audio]),
                (.video, assets[.video]),
                (.phoneMetadata, assets[.phoneMetadata]),
            ].compactMap { kind, url in url.map { (kind, $0) } }

            var movedExistingPackage = false
            var movedNewPackage = false
            do {
                try fileManager.createDirectory(at: temporaryContainerURL, withIntermediateDirectories: true)
                if fileManager.fileExists(atPath: packageURL.path) {
                    try fileManager.copyItem(at: packageURL, to: temporaryPackageURL)
                } else {
                    try fileManager.createDirectory(at: temporaryPackageURL, withIntermediateDirectories: true)
                }
                for (kind, sourceURL) in stagedAssets {
                    let destinationURL = RecordingPackageLayout.assetURL(kind, in: temporaryPackageURL, sessionID: sessionID)
                    if fileManager.fileExists(atPath: destinationURL.path) {
                        try fileManager.removeItem(at: destinationURL)
                    }
                    try fileManager.copyItem(at: sourceURL, to: destinationURL)
                }
                _ = try RecordingPackageDescriptor(packageURL: temporaryPackageURL)
                if fileManager.fileExists(atPath: packageURL.path) {
                    try fileManager.moveItem(at: packageURL, to: backupURL)
                    movedExistingPackage = true
                }
                try fileManager.moveItem(at: temporaryPackageURL, to: packageURL)
                movedNewPackage = true
                if movedExistingPackage {
                    try fileManager.removeItem(at: backupURL)
                }
                for (_, sourceURL) in stagedAssets {
                    try? fileManager.removeItem(at: sourceURL)
                }
            } catch {
                try? fileManager.removeItem(at: temporaryContainerURL)
                if movedNewPackage {
                    try? fileManager.removeItem(at: packageURL)
                }
                if movedExistingPackage,
                   !fileManager.fileExists(atPath: packageURL.path) {
                    try? fileManager.moveItem(at: backupURL, to: packageURL)
                }
                throw error
            }
            try? fileManager.removeItem(at: temporaryContainerURL)
            try? fileManager.removeItem(at: backupURL)
        }
    }

    private func activateSession() {
        guard WCSession.isSupported() else {
            statusMessage = "WatchConnectivity unavailable"
            isWatchConnected = false
            return
        }

        let session = WCSession.default
        if session.activationState == .activated {
            if session.delegate !== self {
                session.delegate = self
            }
            updateConnectionState(from: session)
            applyWatchContext(session.receivedApplicationContext, from: session)
            return
        }
        session.delegate = self
        session.activate()
    }

    private func updateConnectionState(from session: WCSession) {
        isWatchConnected = session.activationState == .activated
            && session.isPaired
            && session.isWatchAppInstalled
    }

    private func applyWatchContext(_ context: [String: Any], from session: WCSession) {
        guard let state = WatchRecordingStateContext(dictionary: context) else { return }
        applyWatchState(state)
        updateConnectionState(from: session)
    }

    func applyWatchState(_ state: WatchRecordingStateContext) {
        isWatchRecording = state.isRecording
        pendingWatchSessionCount = state.pendingSyncSessionCount
        // Zero pending sessions is the explicit completed state, even if an
        // older application context still carries a coarse syncing flag.
        isWatchTransferring = state.isSyncing && state.pendingSyncSessionCount > 0
    }

    private func requestPendingRecordingRetryIfNeeded() {
        let needsRetry = pendingWatchSessionCount > 0
            || recordings.contains(where: \.hasPartialMotionSet)
        guard needsRetry, !isWatchTransferring, WCSession.isSupported() else {
            return
        }

        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { return }
        session.sendMessage(
            [WatchRecordingCommand.commandKey: WatchRecordingCommand.retryPendingTransfers],
            replyHandler: nil,
            errorHandler: nil
        )
    }

    private func noteFileReceiptActivity() {
        fileReceiptActivityTask?.cancel()
        isReceivingFile = true
        fileReceiptActivityTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.isReceivingFile = false
        }
    }

    private func handleReceivedFile(_ file: WCSessionFile) {
        let fileManager = FileManager.default
        let directoryURL = Self.recordingsDirectoryURL()
        var temporaryURL: URL?

        defer {
            if let temporaryURL {
                try? fileManager.removeItem(at: temporaryURL)
            }
        }

        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

            let requestedName = (file.metadata?["fileName"] as? String) ?? file.fileURL.lastPathComponent
            guard let parsedFile = Self.parseRecordingFileName(requestedName) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            if let transferredSessionID = file.metadata?["sessionID"] as? String,
               !Self.sessionIDsMatch(transferredSessionID, parsedFile.sessionID) {
                throw CocoaError(.fileReadCorruptFile)
            }

            let destinationName = Self.canonicalFileName(for: parsedFile.kind, sessionID: parsedFile.sessionID)
            let destinationURL = directoryURL.appendingPathComponent(destinationName)
            let incomingURL = directoryURL.appendingPathComponent(".incoming-\(UUID().uuidString)")
            temporaryURL = incomingURL
            try fileManager.copyItem(at: file.fileURL, to: incomingURL)
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.moveItem(at: incomingURL, to: destinationURL)

            DispatchQueue.main.async {
                self.noteFileReceiptActivity()
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

    private enum ParsedRecordingFileKind {
        case deviceMotion
        case rawAccelerometer
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
        guard let sessionID = WatchRecordingAssetNaming.sessionID(from: fileName) else { return nil }
        if fileName.hasSuffix(WatchMotionBinaryStream.deviceMotion.fileSuffix) {
            return ParsedRecordingFile(sessionID: sessionID, kind: .deviceMotion)
        }
        if fileName.hasSuffix(WatchMotionBinaryStream.rawAccelerometer.fileSuffix) {
            return ParsedRecordingFile(sessionID: sessionID, kind: .rawAccelerometer)
        }
        if fileName.hasSuffix(".watch.json") {
            return ParsedRecordingFile(sessionID: sessionID, kind: .watchMetadata)
        }
        if fileName.hasSuffix(".phone.json") {
            return ParsedRecordingFile(sessionID: sessionID, kind: .phoneMetadata)
        }
        if fileName.hasSuffix(".m4a") {
            return ParsedRecordingFile(sessionID: sessionID, kind: .audio)
        }
        if fileName.hasSuffix(".mov") {
            return ParsedRecordingFile(sessionID: sessionID, kind: .video)
        }
        return nil
    }

    private static func canonicalFileName(for kind: ParsedRecordingFileKind, sessionID: String) -> String {
        switch kind {
        case .deviceMotion:
            return WatchRecordingAssetNaming.deviceMotionFileName(sessionID: sessionID)
        case .rawAccelerometer:
            return WatchRecordingAssetNaming.rawAccelerometerFileName(sessionID: sessionID)
        case .watchMetadata:
            return WatchRecordingAssetNaming.metadataFileName(sessionID: sessionID)
        case .phoneMetadata:
            return WatchRecordingAssetNaming.phoneMetadataFileName(sessionID: sessionID)
        case .audio:
            return WatchRecordingAssetNaming.audioFileName(sessionID: sessionID)
        case .video:
            return WatchRecordingAssetNaming.videoFileName(sessionID: sessionID)
        }
    }

    private static func sessionIDsMatch(_ lhs: String, _ rhs: String) -> Bool {
        guard let lhs = UUID(uuidString: lhs), let rhs = UUID(uuidString: rhs) else { return lhs == rhs }
        return lhs == rhs
    }
}

extension RecordingInboxStore: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async {
            self.updateConnectionState(from: session)
            if let error {
                self.statusMessage = "Session error: \(error.localizedDescription)"
            } else {
                self.statusMessage = "Waiting for watch"
                self.applyWatchContext(session.receivedApplicationContext, from: session)
                self.requestPendingRecordingRetryIfNeeded()
            }
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            self.updateConnectionState(from: session)
            self.requestPendingRecordingRetryIfNeeded()
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

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        DispatchQueue.main.async {
            self.applyWatchContext(applicationContext, from: session)
        }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String : Any]) {
        if let state = WatchRecordingStateContext(dictionary: message) {
            DispatchQueue.main.async {
                self.applyWatchState(state)
                self.updateConnectionState(from: session)
            }
            return
        }

        guard let controlMessage = RecordingControlMessage(dictionary: message) else {
            return
        }

        DispatchQueue.main.async {
            switch controlMessage.action {
            case .prepare:
                let result = self.videoRecorder.prepareRemoteRecording(
                    sessionID: controlMessage.sessionID,
                    leadTime: controlMessage.leadTime ?? 2.0
                )
                self.statusMessage = result.accepted ? "Video ready for Watch" : "Video sync unavailable"
            case .start:
                self.videoRecorder.startRemoteRecording(sessionID: controlMessage.sessionID)
                self.statusMessage = "Watch started recording"
            case .stop:
                self.videoRecorder.stopRemoteRecording(sessionID: controlMessage.sessionID)
                self.statusMessage = "Watch stopped recording"
            }
        }
    }

    func session(
        _ session: WCSession,
        didReceiveMessage message: [String : Any],
        replyHandler: @escaping ([String : Any]) -> Void
    ) {
        guard let controlMessage = RecordingControlMessage(dictionary: message) else {
            replyHandler([:])
            return
        }

        guard controlMessage.action == .prepare else {
            replyHandler([:])
            return
        }

        DispatchQueue.main.async {
            let result = self.videoRecorder.prepareRemoteRecording(
                sessionID: controlMessage.sessionID,
                leadTime: controlMessage.leadTime ?? 2.0
            )
            self.statusMessage = result.accepted ? "Video ready for Watch" : "Video sync unavailable"
            replyHandler(
                ScheduledStartResponse(
                    plannedStartUnix: result.plannedStartUnix,
                    accepted: result.accepted
                ).dictionaryRepresentation
            )
        }
    }
}
