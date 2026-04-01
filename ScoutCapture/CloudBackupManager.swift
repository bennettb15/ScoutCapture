import Foundation
import Combine
import CryptoKit

extension Notification.Name {
    static let scoutPersistentDataDidChange = Notification.Name("scout.persistentDataDidChange")
}

struct CloudBackupManifest: Codable {
    struct FileRecord: Codable {
        let relativePath: String
        let byteCount: Int
        let sha256: String
    }

    let backupID: UUID
    let createdAt: Date
    let schemaVersion: Int
    let appVersion: String
    let localRevision: String
    let selectedPropertyID: String?
    let files: [FileRecord]
}

struct CloudBackupStatus: Equatable {
    enum State: Equatable {
        case backedUp
        case pending
        case unavailable
    }

    var state: State
    var isRunning: Bool
    var lastSuccessfulBackupAt: Date?
    var lastFailureMessage: String?
    var iCloudAvailable: Bool
    var hasBackup: Bool
    var progressPhase: String?
    var progressCompleted: Int?
    var progressTotal: Int?
    var snapshotFileCount: Int?
    var snapshotByteCount: Int?
    var lastRunChangedCount: Int?
    var lastRunUnchangedCount: Int?
    var lastRunChangedByteCount: Int?
    var lastRunAddedCount: Int?
    var lastRunUpdatedCount: Int?
    var lastRunSourceFileCount: Int?
    var lastRunPrunedCount: Int?
    var lastRunChangedPathsSample: [String]?
    var lastRunPrunedPathsSample: [String]?
    var safetyPauseUntil: Date?
    var safetyPauseReason: String?
}

final class CloudBackupManager: ObservableObject {
    private enum Constants {
        static let schemaVersion = 1
        static let latestFolderName = "latest"
        static let inProgressFolderName = "in-progress"
        static let manifestFilename = "manifest.json"
        static let storageRootFolderName = "storage-root"
        static let userDefaultsFilename = "userdefaults.json"
        static let localRevisionKey = "scout.backup.localRevision"
        static let backedUpRevisionKey = "scout.backup.backedUpRevision"
        static let lastSuccessfulBackupAtKey = "scout.backup.lastSuccessfulBackupAt"
        static let lastFailureMessageKey = "scout.backup.lastFailureMessage"
        static let lastRunChangedCountKey = "scout.backup.lastRunChangedCount"
        static let lastRunUnchangedCountKey = "scout.backup.lastRunUnchangedCount"
        static let lastRunChangedByteCountKey = "scout.backup.lastRunChangedByteCount"
        static let lastRunAddedCountKey = "scout.backup.lastRunAddedCount"
        static let lastRunUpdatedCountKey = "scout.backup.lastRunUpdatedCount"
        static let lastRunSourceFileCountKey = "scout.backup.lastRunSourceFileCount"
        static let lastRunPrunedCountKey = "scout.backup.lastRunPrunedCount"
        static let lastRunChangedPathsSampleKey = "scout.backup.lastRunChangedPathsSample"
        static let lastRunPrunedPathsSampleKey = "scout.backup.lastRunPrunedPathsSample"
        static let automaticBackupsEnabledKey = "scout.backup.automaticEnabled"
        static let safetyPauseUntilKey = "scout.backup.safetyPauseUntil"
        static let safetyPauseReasonKey = "scout.backup.safetyPauseReason"
    }

    @Published private(set) var status: CloudBackupStatus

    private let fileManager: FileManager
    private let userDefaults: UserDefaults
    private let backupQueue = DispatchQueue(label: "scoutcapture.cloudbackup.queue", qos: .utility)
    private let backupQueueSpecificKey = DispatchSpecificKey<UInt8>()
    private let backupQueueSpecificValue: UInt8 = 1
    private let stateLock = NSLock()
    private var scheduledBackupWorkItem: DispatchWorkItem?
    private var isRunning = false
    private var isCaptureModeActive = false
    private var progressPhase: String?
    private var progressCompleted: Int?
    private var progressTotal: Int?

    init(
        fileManager: FileManager = .default,
        userDefaults: UserDefaults = .standard
    ) {
        self.fileManager = fileManager
        self.userDefaults = userDefaults
        self.backupQueue.setSpecific(key: backupQueueSpecificKey, value: backupQueueSpecificValue)
        if userDefaults.object(forKey: Constants.automaticBackupsEnabledKey) == nil {
            userDefaults.set(true, forKey: Constants.automaticBackupsEnabledKey)
        }
        self.status = CloudBackupStatus(
            state: .unavailable,
            isRunning: false,
            lastSuccessfulBackupAt: userDefaults.object(forKey: Constants.lastSuccessfulBackupAtKey) as? Date,
            lastFailureMessage: userDefaults.string(forKey: Constants.lastFailureMessageKey),
            iCloudAvailable: false,
            hasBackup: false,
            progressPhase: nil,
            progressCompleted: nil,
            progressTotal: nil,
            snapshotFileCount: nil,
            snapshotByteCount: nil,
            lastRunChangedCount: userDefaults.object(forKey: Constants.lastRunChangedCountKey) as? Int,
            lastRunUnchangedCount: userDefaults.object(forKey: Constants.lastRunUnchangedCountKey) as? Int,
            lastRunChangedByteCount: userDefaults.object(forKey: Constants.lastRunChangedByteCountKey) as? Int,
            lastRunAddedCount: userDefaults.object(forKey: Constants.lastRunAddedCountKey) as? Int,
            lastRunUpdatedCount: userDefaults.object(forKey: Constants.lastRunUpdatedCountKey) as? Int,
            lastRunSourceFileCount: userDefaults.object(forKey: Constants.lastRunSourceFileCountKey) as? Int,
            lastRunPrunedCount: userDefaults.object(forKey: Constants.lastRunPrunedCountKey) as? Int,
            lastRunChangedPathsSample: userDefaults.stringArray(forKey: Constants.lastRunChangedPathsSampleKey),
            lastRunPrunedPathsSample: userDefaults.stringArray(forKey: Constants.lastRunPrunedPathsSampleKey),
            safetyPauseUntil: nil,
            safetyPauseReason: nil
        )
        refreshStatus()
    }

    var automaticBackupsEnabled: Bool {
        userDefaults.bool(forKey: Constants.automaticBackupsEnabledKey)
    }

    func refreshStatus() {
        let cloudAvailable = StorageRoot.cloudBackupRootURL() != nil
        let hasBackup = hasRestorableLatestBackup
        let localRevision = userDefaults.string(forKey: Constants.localRevisionKey)
        let backedUpRevision = userDefaults.string(forKey: Constants.backedUpRevisionKey)
        let lastSuccessfulBackupAt = userDefaults.object(forKey: Constants.lastSuccessfulBackupAtKey) as? Date
        let lastFailureMessage = userDefaults.string(forKey: Constants.lastFailureMessageKey)
        let lastRunChangedCount = userDefaults.object(forKey: Constants.lastRunChangedCountKey) as? Int
        let lastRunUnchangedCount = userDefaults.object(forKey: Constants.lastRunUnchangedCountKey) as? Int
        let lastRunChangedByteCount = userDefaults.object(forKey: Constants.lastRunChangedByteCountKey) as? Int
        let lastRunAddedCount = userDefaults.object(forKey: Constants.lastRunAddedCountKey) as? Int
        let lastRunUpdatedCount = userDefaults.object(forKey: Constants.lastRunUpdatedCountKey) as? Int
        let lastRunSourceFileCount = userDefaults.object(forKey: Constants.lastRunSourceFileCountKey) as? Int
        let lastRunPrunedCount = userDefaults.object(forKey: Constants.lastRunPrunedCountKey) as? Int
        let lastRunChangedPathsSample = userDefaults.stringArray(forKey: Constants.lastRunChangedPathsSampleKey)
        let lastRunPrunedPathsSample = userDefaults.stringArray(forKey: Constants.lastRunPrunedPathsSampleKey)
        let safetyPauseUntil = userDefaults.object(forKey: Constants.safetyPauseUntilKey) as? Date
        let safetyPauseReason = userDefaults.string(forKey: Constants.safetyPauseReasonKey)
        let snapshotMetrics = currentSnapshotMetrics()
        let runtime = withStateLock {
            (
                isRunning: isRunning,
                progressPhase: progressPhase,
                progressCompleted: progressCompleted,
                progressTotal: progressTotal
            )
        }

        let state: CloudBackupStatus.State
        if !cloudAvailable {
            state = .unavailable
        } else if runtime.isRunning || localRevision == nil || localRevision != backedUpRevision || !hasBackup {
            state = .pending
        } else {
            state = .backedUp
        }

        let apply = {
            self.status = CloudBackupStatus(
                state: state,
                isRunning: runtime.isRunning,
                lastSuccessfulBackupAt: lastSuccessfulBackupAt,
                lastFailureMessage: lastFailureMessage,
                iCloudAvailable: cloudAvailable,
                hasBackup: hasBackup,
                progressPhase: runtime.progressPhase,
                progressCompleted: runtime.progressCompleted,
                progressTotal: runtime.progressTotal,
                snapshotFileCount: snapshotMetrics?.fileCount,
                snapshotByteCount: snapshotMetrics?.byteCount,
                lastRunChangedCount: lastRunChangedCount,
                lastRunUnchangedCount: lastRunUnchangedCount,
                lastRunChangedByteCount: lastRunChangedByteCount,
                lastRunAddedCount: lastRunAddedCount,
                lastRunUpdatedCount: lastRunUpdatedCount,
                lastRunSourceFileCount: lastRunSourceFileCount,
                lastRunPrunedCount: lastRunPrunedCount,
                lastRunChangedPathsSample: lastRunChangedPathsSample,
                lastRunPrunedPathsSample: lastRunPrunedPathsSample,
                safetyPauseUntil: safetyPauseUntil,
                safetyPauseReason: safetyPauseReason
            )
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    func markDataChanged(scheduleBackupAfter delay: TimeInterval = 30) {
        bumpLocalRevision()
        refreshStatus()
        guard automaticBackupsEnabled else { return }
        scheduleAutomaticBackup(after: delay)
    }

    func scheduleAutomaticBackup(after delay: TimeInterval = 0) {
        guard automaticBackupsEnabled else { return }
        guard !isCaptureModeActive else { return }
        guard !isSafetyPauseActive else {
            refreshStatus()
            return
        }
        guard hasPendingBackup else {
            refreshStatus()
            return
        }
        scheduledBackupWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.performBackup(trigger: "automatic")
        }
        scheduledBackupWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    func backupNow() {
        scheduledBackupWorkItem?.cancel()
        clearSafetyPause()
        performBackup(trigger: "manual")
    }

    func setCaptureModeActive(_ active: Bool) {
        isCaptureModeActive = active
        if !active, automaticBackupsEnabled, hasPendingBackup {
            scheduleAutomaticBackup(after: 0)
        }
        refreshStatus()
    }

    func restoreLatestBackup() throws -> UUID? {
        scheduledBackupWorkItem?.cancel()
        return try executeOnBackupQueueSync {
            let selectedPropertyID = try restoreLatestBackupSync()
            refreshStatus()
            return selectedPropertyID
        }
    }

    func pauseAutomaticBackupsForSafetyWindow(minutes: Int = 15, reason: String = "after deletion") {
        let until = Date().addingTimeInterval(TimeInterval(max(minutes, 1) * 60))
        userDefaults.set(until, forKey: Constants.safetyPauseUntilKey)
        userDefaults.set(reason, forKey: Constants.safetyPauseReasonKey)
        scheduledBackupWorkItem?.cancel()
        refreshStatus()
    }

    private func performBackup(trigger: String) {
        if trigger == "automatic", isCaptureModeActive {
            return
        }
        if trigger == "automatic", isSafetyPauseActive {
            return
        }
        backupQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.performBackupSync(trigger: trigger)
            } catch {
                self.userDefaults.set(error.localizedDescription, forKey: Constants.lastFailureMessageKey)
                self.refreshStatus()
            }
        }
    }

    private var hasPendingBackup: Bool {
        let localRevision = userDefaults.string(forKey: Constants.localRevisionKey)
        let backedUpRevision = userDefaults.string(forKey: Constants.backedUpRevisionKey)
        return localRevision == nil || localRevision != backedUpRevision
    }

    private var isSafetyPauseActive: Bool {
        guard let until = userDefaults.object(forKey: Constants.safetyPauseUntilKey) as? Date else {
            return false
        }
        if until > Date() {
            return true
        }
        clearSafetyPause()
        return false
    }

    private func clearSafetyPause() {
        userDefaults.removeObject(forKey: Constants.safetyPauseUntilKey)
        userDefaults.removeObject(forKey: Constants.safetyPauseReasonKey)
    }

    private func performBackupSync(trigger: String) throws {
        guard let backupRoot = StorageRoot.cloudBackupRootURL() else {
            refreshStatus()
            return
        }
        guard !withStateLock({ isRunning }) else { return }

        withStateLock {
            isRunning = true
            progressPhase = "Preparing backup"
            progressCompleted = 0
            progressTotal = nil
        }
        refreshStatus()
        defer {
            withStateLock {
                isRunning = false
                progressPhase = nil
                progressCompleted = nil
                progressTotal = nil
            }
            refreshStatus()
        }

        let localRevision = userDefaults.string(forKey: Constants.localRevisionKey) ?? bumpLocalRevision()
        let sourceRoot = StorageRoot.prepareStorage()
        guard hasAnyProperties(in: sourceRoot) else {
            if let backedUpRevision = userDefaults.string(forKey: Constants.backedUpRevisionKey) {
                userDefaults.set(backedUpRevision, forKey: Constants.localRevisionKey)
            } else {
                userDefaults.removeObject(forKey: Constants.localRevisionKey)
            }
            userDefaults.set("Backup skipped: no properties found to back up.", forKey: Constants.lastFailureMessageKey)
            print("[CloudBackup] trigger=\(trigger) result=skipped reason=noProperties")
            refreshStatus()
            return
        }
        try fileManager.createDirectory(at: backupRoot, withIntermediateDirectories: true)
        let inProgressURL = backupRoot.appendingPathComponent(Constants.inProgressFolderName, isDirectory: true)
        let latestURL = backupRoot.appendingPathComponent(Constants.latestFolderName, isDirectory: true)
        let inProgressStorage = inProgressURL.appendingPathComponent(Constants.storageRootFolderName, isDirectory: true)
        let hadLatestSnapshot = fileManager.fileExists(atPath: latestURL.path)

        if fileManager.fileExists(atPath: inProgressURL.path) {
            try fileManager.removeItem(at: inProgressURL)
        }
        if hadLatestSnapshot {
            try fileManager.moveItem(at: latestURL, to: inProgressURL)
        } else {
            try fileManager.createDirectory(at: inProgressStorage, withIntermediateDirectories: true)
        }
        try fileManager.createDirectory(at: inProgressStorage, withIntermediateDirectories: true)

        var backupCommitted = false
        defer {
            if backupCommitted == false, fileManager.fileExists(atPath: inProgressURL.path) {
                if hadLatestSnapshot, !fileManager.fileExists(atPath: latestURL.path) {
                    try? fileManager.moveItem(at: inProgressURL, to: latestURL)
                } else {
                    try? fileManager.removeItem(at: inProgressURL)
                }
            }
        }

        var previousRecordsByPath: [String: CloudBackupManifest.FileRecord] = [:]
        if hadLatestSnapshot, let priorManifest = try? loadManifest(at: inProgressURL) {
            previousRecordsByPath = Dictionary(
                uniqueKeysWithValues: priorManifest.files.map { ($0.relativePath, $0) }
            )
        }

        let sourceFiles = try recursiveFileURLs(in: sourceRoot).filter { fileURL in
            !isWithinBackupsFolder(fileURL, storageRoot: sourceRoot)
        }
        let totalProgressSteps = sourceFiles.count + 3
        var completedProgressSteps = 0
        updateProgress(phase: "Scanning files", completed: completedProgressSteps, total: totalProgressSteps)
        var sourceRelativePaths = Set<String>()
        var fileRecords: [CloudBackupManifest.FileRecord] = []
        var changedFilesCount = 0
        var unchangedFilesCount = 0
        var changedFilesByteCount = 0
        var addedFilesCount = 0
        var updatedFilesCount = 0
        var changedRelativePaths: [String] = []
        for sourceFileURL in sourceFiles {
            let relativePath = sourceFileURL.path.replacingOccurrences(of: "\(sourceRoot.path)/", with: "")
            sourceRelativePaths.insert(relativePath)
            let targetURL = inProgressStorage.appendingPathComponent(relativePath, isDirectory: false)
            let sourceData = try Data(contentsOf: sourceFileURL)
            let digest = SHA256.hash(data: sourceData)
            let sha256 = digest.map { String(format: "%02x", $0) }.joined()
            let fileRecord = CloudBackupManifest.FileRecord(
                relativePath: "storage-root/\(relativePath)",
                byteCount: sourceData.count,
                sha256: sha256
            )
            fileRecords.append(fileRecord)

            let baselineRecord = previousRecordsByPath[fileRecord.relativePath]
            let isUnchanged = baselineRecord?.byteCount == fileRecord.byteCount &&
                baselineRecord?.sha256 == fileRecord.sha256 &&
                fileManager.fileExists(atPath: targetURL.path)
            if isUnchanged {
                unchangedFilesCount += 1
            } else {
                try writeFileData(sourceData, to: targetURL)
                changedFilesCount += 1
                changedFilesByteCount += sourceData.count
                if baselineRecord == nil {
                    addedFilesCount += 1
                } else {
                    updatedFilesCount += 1
                }
                changedRelativePaths.append(relativePath)
            }
            completedProgressSteps += 1
            updateProgress(phase: "Scanning files", completed: completedProgressSteps, total: totalProgressSteps)
        }
        let prunedRelativePaths = try removeStaleStorageFiles(in: inProgressStorage, keepingRelativePaths: sourceRelativePaths)
        completedProgressSteps += 1
        updateProgress(phase: "Pruning stale files", completed: completedProgressSteps, total: totalProgressSteps)

        let defaultsURL = inProgressURL.appendingPathComponent(Constants.userDefaultsFilename)
        let defaultsData = try makeUserDefaultsExportData()
        try defaultsData.write(to: defaultsURL, options: [.atomic])
        let defaultsDigest = SHA256.hash(data: defaultsData).map { String(format: "%02x", $0) }.joined()
        fileRecords.append(
            CloudBackupManifest.FileRecord(
                relativePath: Constants.userDefaultsFilename,
                byteCount: defaultsData.count,
                sha256: defaultsDigest
            )
        )
        completedProgressSteps += 1
        updateProgress(phase: "Writing preferences", completed: completedProgressSteps, total: totalProgressSteps)

        let manifest = CloudBackupManifest(
            backupID: UUID(),
            createdAt: Date(),
            schemaVersion: Constants.schemaVersion,
            appVersion: appVersionString(),
            localRevision: localRevision,
            selectedPropertyID: userDefaults.string(forKey: "scoutcapture.selectedPropertyID"),
            files: fileRecords.sorted(by: { $0.relativePath < $1.relativePath })
        )
        let manifestURL = inProgressURL.appendingPathComponent(Constants.manifestFilename)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: manifestURL, options: [.atomic])
        completedProgressSteps += 1
        updateProgress(phase: "Validating backup", completed: completedProgressSteps, total: totalProgressSteps)

        if hadLatestSnapshot, !previousRecordsByPath.isEmpty {
            let changedPaths = Set(
                fileRecords
                    .filter { record in
                        guard let baselineRecord = previousRecordsByPath[record.relativePath] else { return true }
                        return baselineRecord.byteCount != record.byteCount || baselineRecord.sha256 != record.sha256
                    }
                    .map(\.relativePath)
            )
            try validateBackup(
                at: inProgressURL,
                onlyRelativePaths: changedPaths.union([Constants.userDefaultsFilename])
            )
        } else {
            try validateBackup(at: inProgressURL)
        }

        if fileManager.fileExists(atPath: latestURL.path) {
            try fileManager.removeItem(at: latestURL)
        }
        try fileManager.moveItem(at: inProgressURL, to: latestURL)
        let finalManifestURL = latestURL.appendingPathComponent(Constants.manifestFilename, isDirectory: false)
        guard fileManager.fileExists(atPath: finalManifestURL.path) else {
            throw NSError(domain: "ScoutCapture.CloudBackup", code: 6, userInfo: [
                NSLocalizedDescriptionKey: "Backup validation failed: manifest missing after write."
            ])
        }

        userDefaults.set(localRevision, forKey: Constants.backedUpRevisionKey)
        userDefaults.set(Date(), forKey: Constants.lastSuccessfulBackupAtKey)
        userDefaults.set(changedFilesCount, forKey: Constants.lastRunChangedCountKey)
        userDefaults.set(unchangedFilesCount, forKey: Constants.lastRunUnchangedCountKey)
        userDefaults.set(changedFilesByteCount, forKey: Constants.lastRunChangedByteCountKey)
        userDefaults.set(addedFilesCount, forKey: Constants.lastRunAddedCountKey)
        userDefaults.set(updatedFilesCount, forKey: Constants.lastRunUpdatedCountKey)
        userDefaults.set(sourceFiles.count, forKey: Constants.lastRunSourceFileCountKey)
        userDefaults.set(prunedRelativePaths.count, forKey: Constants.lastRunPrunedCountKey)
        userDefaults.set(Array(changedRelativePaths.prefix(8)), forKey: Constants.lastRunChangedPathsSampleKey)
        userDefaults.set(Array(prunedRelativePaths.prefix(8)), forKey: Constants.lastRunPrunedPathsSampleKey)
        userDefaults.removeObject(forKey: Constants.lastFailureMessageKey)
        backupCommitted = true
        print(
            "[CloudBackup] trigger=\(trigger) result=success revision=\(localRevision) changed=\(changedFilesCount) unchanged=\(unchangedFilesCount)"
        )
    }

    private func updateProgress(phase: String, completed: Int, total: Int) {
        withStateLock {
            progressPhase = phase
            progressCompleted = completed
            progressTotal = max(total, 1)
        }
        refreshStatus()
    }

    private func withStateLock<T>(_ operation: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return operation()
    }

    private func restoreLatestBackupSync() throws -> UUID? {
        let restoreDeadline = Date().addingTimeInterval(20)
        var selectedBackupURL: URL?
        var selectedBackupValidatedWithManifest = false
        var lastTransientError: Error?

        while Date() < restoreDeadline {
            guard let latestURL = restorableBackupFolderURL() else {
                Thread.sleep(forTimeInterval: 0.2)
                continue
            }
            do {
                try validateBackup(at: latestURL)
                selectedBackupURL = latestURL
                selectedBackupValidatedWithManifest = true
                break
            } catch {
                let nsError = error as NSError
                if (nsError.domain == "ScoutCapture.CloudBackup" && [3, 7].contains(nsError.code)) ||
                    (nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileNoSuchFileError) {
                    if hasMinimalRestorablePayload(in: latestURL) {
                        selectedBackupURL = latestURL
                        selectedBackupValidatedWithManifest = false
                        break
                    }
                    lastTransientError = error
                    Thread.sleep(forTimeInterval: 0.2)
                    continue
                }
                throw error
            }
        }

        guard let latestURL = selectedBackupURL else {
            if let lastTransientError {
                throw lastTransientError
            }
            throw NSError(domain: "ScoutCapture.CloudBackup", code: 404, userInfo: [
                NSLocalizedDescriptionKey: "No completed iCloud backup is available yet."
            ])
        }

        let tempRestoreRoot = fileManager.temporaryDirectory
            .appendingPathComponent("ScoutCaptureCloudRestore-\(UUID().uuidString)", isDirectory: true)
        let tempStorageRoot = tempRestoreRoot.appendingPathComponent(Constants.storageRootFolderName, isDirectory: true)
        try fileManager.createDirectory(at: tempRestoreRoot, withIntermediateDirectories: true)
        try copyDirectoryContents(
            from: latestURL.appendingPathComponent(Constants.storageRootFolderName, isDirectory: true),
            to: tempStorageRoot
        )

        let activeRoot = StorageRoot.prepareStorage()
        let rollbackRoot = fileManager.temporaryDirectory
            .appendingPathComponent("ScoutCaptureCloudRollback-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: rollbackRoot, withIntermediateDirectories: true)
        try copyDirectoryContents(from: activeRoot, to: rollbackRoot)

        let defaultsData = try Data(contentsOf: latestURL.appendingPathComponent(Constants.userDefaultsFilename))
        let restoredSelectedPropertyID = try restoreUserDefaults(from: defaultsData)

        do {
            try clearDirectoryContentsIfPresent(
                at: activeRoot,
                preservingTopLevelNames: ["Backups"]
            )
            try copyDirectoryContents(from: tempStorageRoot, to: activeRoot)
            if selectedBackupValidatedWithManifest, let manifest = try? loadManifest(at: latestURL) {
                userDefaults.set(manifest.localRevision, forKey: Constants.localRevisionKey)
                userDefaults.set(manifest.localRevision, forKey: Constants.backedUpRevisionKey)
            } else {
                let revision = bumpLocalRevision()
                userDefaults.set(revision, forKey: Constants.backedUpRevisionKey)
            }
            userDefaults.set(Date(), forKey: Constants.lastSuccessfulBackupAtKey)
            userDefaults.removeObject(forKey: Constants.lastFailureMessageKey)
            try? fileManager.removeItem(at: rollbackRoot)
            try? fileManager.removeItem(at: tempRestoreRoot)
            return restoredSelectedPropertyID
        } catch {
            try? clearDirectoryContentsIfPresent(
                at: activeRoot,
                preservingTopLevelNames: ["Backups"]
            )
            try? copyDirectoryContents(from: rollbackRoot, to: activeRoot)
            try? fileManager.removeItem(at: rollbackRoot)
            try? fileManager.removeItem(at: tempRestoreRoot)
            throw error
        }
    }

    private func latestBackupFolderURL() -> URL? {
        StorageRoot.cloudBackupRootURL()?.appendingPathComponent(Constants.latestFolderName, isDirectory: true)
    }

    private var hasRestorableLatestBackup: Bool {
        restorableBackupFolderURL() != nil
    }

    private func restorableBackupFolderURL() -> URL? {
        guard let backupRoot = StorageRoot.cloudBackupRootURL() else { return nil }
        let candidates = [
            backupRoot.appendingPathComponent(Constants.latestFolderName, isDirectory: true)
        ]
        for candidate in candidates {
            guard fileManager.fileExists(atPath: candidate.path) else { continue }
            let manifestURL = candidate.appendingPathComponent(Constants.manifestFilename, isDirectory: false)
            guard ensureUbiquitousItemAvailable(at: manifestURL) else { continue }
            guard let data = try? Data(contentsOf: manifestURL) else { continue }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let manifest = try? decoder.decode(CloudBackupManifest.self, from: data),
                  manifest.schemaVersion == Constants.schemaVersion else {
                continue
            }
            return candidate
        }
        return nil
    }

    private func ensureUbiquitousItemAvailable(at url: URL, timeout: TimeInterval = 8.0) -> Bool {
        if fileManager.fileExists(atPath: url.path) {
            return true
        }
        guard fileManager.isUbiquitousItem(at: url) else {
            return fileManager.fileExists(atPath: url.path)
        }
        try? fileManager.startDownloadingUbiquitousItem(at: url)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if fileManager.fileExists(atPath: url.path) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return fileManager.fileExists(atPath: url.path)
    }

    private func hasMinimalRestorablePayload(in backupFolder: URL) -> Bool {
        let storageRoot = backupFolder.appendingPathComponent(Constants.storageRootFolderName, isDirectory: true)
        let defaults = backupFolder.appendingPathComponent(Constants.userDefaultsFilename, isDirectory: false)
        return fileManager.fileExists(atPath: storageRoot.path) && ensureUbiquitousItemAvailable(at: defaults)
    }

    private func currentSnapshotMetrics() -> (fileCount: Int, byteCount: Int)? {
        guard let backupFolder = restorableBackupFolderURL(),
              let manifest = try? loadManifest(at: backupFolder) else {
            return nil
        }
        let byteCount = manifest.files.reduce(0) { partialResult, file in
            partialResult + max(file.byteCount, 0)
        }
        return (manifest.files.count, byteCount)
    }

    private func executeOnBackupQueueSync<T>(_ operation: () throws -> T) throws -> T {
        if DispatchQueue.getSpecific(key: backupQueueSpecificKey) == backupQueueSpecificValue {
            return try operation()
        }
        return try backupQueue.sync {
            try operation()
        }
    }

    @discardableResult
    private func bumpLocalRevision() -> String {
        let revision = ISO8601DateFormatter().string(from: Date())
        userDefaults.set(revision, forKey: Constants.localRevisionKey)
        return revision
    }

    private func makeManifest(for backupFolder: URL, localRevision: String) throws -> CloudBackupManifest {
        let files = try collectFiles(in: backupFolder)
        let selectedPropertyID = userDefaults.string(forKey: "scoutcapture.selectedPropertyID")
        return CloudBackupManifest(
            backupID: UUID(),
            createdAt: Date(),
            schemaVersion: Constants.schemaVersion,
            appVersion: appVersionString(),
            localRevision: localRevision,
            selectedPropertyID: selectedPropertyID,
            files: files
        )
    }

    private func collectFiles(in backupFolder: URL) throws -> [CloudBackupManifest.FileRecord] {
        let files = try recursiveFileURLs(in: backupFolder)
        return try files
            .filter { $0.lastPathComponent != Constants.manifestFilename }
            .sorted(by: { $0.path < $1.path })
            .map { url in
                let data = try Data(contentsOf: url)
                let digest = SHA256.hash(data: data)
                let sha256 = digest.map { String(format: "%02x", $0) }.joined()
                let relativePath = url.path.replacingOccurrences(of: "\(backupFolder.path)/", with: "")
                return CloudBackupManifest.FileRecord(
                    relativePath: relativePath,
                    byteCount: data.count,
                    sha256: sha256
                )
            }
    }

    private func recursiveFileURLs(in directory: URL) throws -> [URL] {
        let children = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        var output: [URL] = []
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let values = try child.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == true {
                output.append(contentsOf: try recursiveFileURLs(in: child))
            } else {
                output.append(child)
            }
        }
        return output
    }

    private func validateBackup(at backupFolder: URL) throws {
        let manifest = try loadManifest(at: backupFolder)
        guard manifest.schemaVersion == Constants.schemaVersion else {
            throw NSError(domain: "ScoutCapture.CloudBackup", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "The backup schema is not supported by this app version."
            ])
        }

        for file in manifest.files {
            let url = backupFolder.appendingPathComponent(file.relativePath)
            guard ensureUbiquitousItemAvailable(at: url) else {
                throw NSError(domain: "ScoutCapture.CloudBackup", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "Backup file missing: \(file.relativePath)"
                ])
            }
            let data = try Data(contentsOf: url)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard data.count == file.byteCount, digest == file.sha256 else {
                throw NSError(domain: "ScoutCapture.CloudBackup", code: 4, userInfo: [
                    NSLocalizedDescriptionKey: "Backup validation failed for \(file.relativePath)."
                ])
            }
        }
    }

    private func validateBackup(at backupFolder: URL, onlyRelativePaths: Set<String>) throws {
        let manifest = try loadManifest(at: backupFolder)
        guard manifest.schemaVersion == Constants.schemaVersion else {
            throw NSError(domain: "ScoutCapture.CloudBackup", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "The backup schema is not supported by this app version."
            ])
        }
        let recordsByPath = Dictionary(uniqueKeysWithValues: manifest.files.map { ($0.relativePath, $0) })
        for relativePath in onlyRelativePaths {
            guard let file = recordsByPath[relativePath] else {
                throw NSError(domain: "ScoutCapture.CloudBackup", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "Backup file missing: \(relativePath)"
                ])
            }
            let url = backupFolder.appendingPathComponent(file.relativePath)
            guard ensureUbiquitousItemAvailable(at: url) else {
                throw NSError(domain: "ScoutCapture.CloudBackup", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "Backup file missing: \(file.relativePath)"
                ])
            }
            let data = try Data(contentsOf: url)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard data.count == file.byteCount, digest == file.sha256 else {
                throw NSError(domain: "ScoutCapture.CloudBackup", code: 4, userInfo: [
                    NSLocalizedDescriptionKey: "Backup validation failed for \(file.relativePath)."
                ])
            }
        }
    }

    private func loadManifest(at backupFolder: URL) throws -> CloudBackupManifest {
        let manifestURL = backupFolder.appendingPathComponent(Constants.manifestFilename, isDirectory: false)
        guard ensureUbiquitousItemAvailable(at: manifestURL) else {
            throw NSError(domain: "ScoutCapture.CloudBackup", code: 7, userInfo: [
                NSLocalizedDescriptionKey: "The backup manifest is not available yet. Please try again in a moment."
            ])
        }
        let data: Data
        do {
            data = try Data(contentsOf: manifestURL)
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileNoSuchFileError {
                throw NSError(domain: "ScoutCapture.CloudBackup", code: 7, userInfo: [
                    NSLocalizedDescriptionKey: "The backup manifest is not available yet. Please try again in a moment."
                ])
            }
            throw error
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CloudBackupManifest.self, from: data)
    }

    private func clearDirectoryContentsIfPresent(
        at url: URL,
        preservingTopLevelNames: Set<String> = []
    ) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        let children = try fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for child in children {
            if preservingTopLevelNames.contains(child.lastPathComponent) {
                continue
            }
            try fileManager.removeItem(at: child)
        }
    }

    private func copyDirectoryContents(from sourceURL: URL, to destinationURL: URL) throws {
        guard fileManager.fileExists(atPath: sourceURL.path) else { return }
        try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        let children = try fileManager.contentsOfDirectory(
            at: sourceURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        for childURL in children {
            let values = try childURL.resourceValues(forKeys: [.isDirectoryKey])
            let targetURL = destinationURL.appendingPathComponent(childURL.lastPathComponent, isDirectory: values.isDirectory == true)
            if values.isDirectory == true {
                try copyDirectoryContents(from: childURL, to: targetURL)
            } else {
                let parent = targetURL.deletingLastPathComponent()
                try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
                if fileManager.fileExists(atPath: targetURL.path) {
                    try fileManager.removeItem(at: targetURL)
                }
                try fileManager.copyItem(at: childURL, to: targetURL)
            }
        }
    }

    private func copyFile(from sourceURL: URL, to destinationURL: URL) throws {
        let parent = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
    }

    private func writeFileData(_ data: Data, to destinationURL: URL) throws {
        let parent = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try data.write(to: destinationURL, options: [.atomic])
    }

    private func moveReplacingItem(at source: URL, to destination: URL) throws {
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: source, to: destination)
    }

    private func isWithinBackupsFolder(_ fileURL: URL, storageRoot: URL) -> Bool {
        let backupsRoot = storageRoot.appendingPathComponent("Backups", isDirectory: true).standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        return filePath == backupsRoot || filePath.hasPrefix(backupsRoot + "/")
    }

    private func removeStaleStorageFiles(in storageRoot: URL, keepingRelativePaths: Set<String>) throws -> [String] {
        guard fileManager.fileExists(atPath: storageRoot.path) else { return [] }
        let existingFiles = try recursiveFileURLs(in: storageRoot)
        var prunedRelativePaths: [String] = []
        for fileURL in existingFiles {
            let relativePath = fileURL.path.replacingOccurrences(of: "\(storageRoot.path)/", with: "")
            if !keepingRelativePaths.contains(relativePath) {
                try fileManager.removeItem(at: fileURL)
                prunedRelativePaths.append(relativePath)
            }
        }
        try removeEmptyDirectoriesRecursively(in: storageRoot)
        return prunedRelativePaths.sorted()
    }

    private func removeEmptyDirectoriesRecursively(in directory: URL) throws {
        guard fileManager.fileExists(atPath: directory.path) else { return }
        let children = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for child in children {
            let values = try child.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == true {
                try removeEmptyDirectoriesRecursively(in: child)
            }
        }
        let refreshedChildren = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        if refreshedChildren.isEmpty && directory.lastPathComponent != Constants.storageRootFolderName {
            try fileManager.removeItem(at: directory)
        }
    }

    private func makeUserDefaultsExportData() throws -> Data {
        let rawDefaults = userDefaults.dictionaryRepresentation()
        let filtered = rawDefaults.filter { shouldRestoreUserDefaultsKey($0.key) }
        let payload: [String: Any] = [
            "exportedAt": ISO8601DateFormatter().string(from: Date()),
            "values": normalizeJSONValue(filtered)
        ]
        return try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    }

    private func restoreUserDefaults(from data: Data) throws -> UUID? {
        guard let rootObject = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let values = rootObject["values"] as? [String: Any] else {
            throw NSError(domain: "ScoutCapture.CloudBackup", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "The backup preferences payload is invalid."
            ])
        }

        for key in userDefaults.dictionaryRepresentation().keys where shouldRestoreUserDefaultsKey(key) {
            userDefaults.removeObject(forKey: key)
        }

        for (key, value) in values where shouldRestoreUserDefaultsKey(key) {
            userDefaults.set(decodedUserDefaultsValue(value), forKey: key)
        }
        userDefaults.synchronize()
        return (values["scoutcapture.selectedPropertyID"] as? String).flatMap(UUID.init(uuidString:))
    }

    private func shouldRestoreUserDefaultsKey(_ key: String) -> Bool {
        key.hasPrefix("scout.") ||
        key.hasPrefix("scoutcapture.") ||
        key.hasPrefix("scout.captureProfile.property.")
    }

    private func normalizeJSONValue(_ value: Any) -> Any {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number
        case let bool as Bool:
            return bool
        case let int as Int:
            return int
        case let double as Double:
            return double
        case let float as Float:
            return float
        case let url as URL:
            return url.absoluteString
        case let data as Data:
            return [
                "type": "data",
                "base64": data.base64EncodedString()
            ]
        case let date as Date:
            return ISO8601DateFormatter().string(from: date)
        case let array as [Any]:
            return array.map { normalizeJSONValue($0) }
        case let dictionary as [String: Any]:
            return dictionary.mapValues { normalizeJSONValue($0) }
        default:
            return String(describing: value)
        }
    }

    private func decodedUserDefaultsValue(_ value: Any) -> Any? {
        if let dictionary = value as? [String: Any],
           let type = dictionary["type"] as? String,
           type == "data",
           let base64 = dictionary["base64"] as? String,
           let data = Data(base64Encoded: base64) {
            return data
        }

        if let array = value as? [Any] {
            return array.compactMap { decodedUserDefaultsValue($0) }
        }

        if let dictionary = value as? [String: Any] {
            return dictionary.mapValues { decodedUserDefaultsValue($0) as Any }
        }

        return value
    }

    private func appVersionString() -> String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        switch (short, build) {
        case let (s?, b?) where !s.isEmpty && !b.isEmpty:
            return "\(s) (\(b))"
        case let (s?, _):
            return s
        case let (_, b?):
            return b
        default:
            return "unknown"
        }
    }

    private func hasAnyProperties(in sourceRoot: URL) -> Bool {
        let candidates = [
            sourceRoot
                .appendingPathComponent("SCOUT", isDirectory: true)
                .appendingPathComponent("properties.json", isDirectory: false),
            sourceRoot.appendingPathComponent("properties.json", isDirectory: false)
        ]
        for propertiesJSONURL in candidates {
            guard fileManager.fileExists(atPath: propertiesJSONURL.path) else { continue }
            guard let data = try? Data(contentsOf: propertiesJSONURL) else { continue }
            guard let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { continue }
            if !raw.isEmpty {
                return true
            }
        }
        return false
    }
}
