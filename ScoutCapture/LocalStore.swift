import Foundation
import UIKit
import CryptoKit

private let isVerboseConsoleLoggingEnabled = false

@inline(__always)
private func verboseLog(_ message: @autoclosure () -> String) {
    guard isVerboseConsoleLoggingEnabled else { return }
    print(message())
}

struct LegacyMigrationPreflightLedger: Codable {
    static let currentSchemaVersion = 3

    enum MutationState: String, Codable {
        case pending
        case rowUpsertStarted = "row_upsert_started"
        case rowUpsertSucceeded = "row_upsert_succeeded"
        case mediaUploadStarted = "media_upload_started"
        case mediaUploadSucceeded = "media_upload_succeeded"
        case verified
        case failedRetryable = "failed_retryable"
        case failedTerminal = "failed_terminal"
    }

    struct MutationStatus: Codable {
        var state: MutationState
        var attemptCount: Int
        var lastAttemptedAt: Date?
        var lastVerifiedAt: Date?
        var lastErrorCategory: String?
        var lastErrorMessage: String?
        var lastRunID: UUID?
        var isReadyForFinalize: Bool

        private enum CodingKeys: String, CodingKey {
            case state
            case attemptCount
            case lastAttemptedAt
            case lastVerifiedAt
            case lastErrorCategory
            case lastErrorMessage
            case lastRunID
            case isReadyForFinalize
        }

        init(
            state: MutationState = .pending,
            attemptCount: Int = 0,
            lastAttemptedAt: Date? = nil,
            lastVerifiedAt: Date? = nil,
            lastErrorCategory: String? = nil,
            lastErrorMessage: String? = nil,
            lastRunID: UUID? = nil,
            isReadyForFinalize: Bool = false
        ) {
            self.state = state
            self.attemptCount = attemptCount
            self.lastAttemptedAt = lastAttemptedAt
            self.lastVerifiedAt = lastVerifiedAt
            self.lastErrorCategory = lastErrorCategory
            self.lastErrorMessage = lastErrorMessage
            self.lastRunID = lastRunID
            self.isReadyForFinalize = isReadyForFinalize
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            state = try container.decodeIfPresent(MutationState.self, forKey: .state) ?? .pending
            attemptCount = try container.decodeIfPresent(Int.self, forKey: .attemptCount) ?? 0
            lastAttemptedAt = try container.decodeIfPresent(Date.self, forKey: .lastAttemptedAt)
            lastVerifiedAt = try container.decodeIfPresent(Date.self, forKey: .lastVerifiedAt)
            lastErrorCategory = try container.decodeIfPresent(String.self, forKey: .lastErrorCategory)
            lastErrorMessage = try container.decodeIfPresent(String.self, forKey: .lastErrorMessage)
            lastRunID = try container.decodeIfPresent(UUID.self, forKey: .lastRunID)
            isReadyForFinalize = try container.decodeIfPresent(Bool.self, forKey: .isReadyForFinalize) ?? false
        }
    }

    struct MutationRunStatus: Codable {
        var currentRunID: UUID?
        var state: String
        var startedAt: Date?
        var completedAt: Date?
        var lastErrorCategory: String?
        var lastErrorMessage: String?

        init(
            currentRunID: UUID? = nil,
            state: String = "idle",
            startedAt: Date? = nil,
            completedAt: Date? = nil,
            lastErrorCategory: String? = nil,
            lastErrorMessage: String? = nil
        ) {
            self.currentRunID = currentRunID
            self.state = state
            self.startedAt = startedAt
            self.completedAt = completedAt
            self.lastErrorCategory = lastErrorCategory
            self.lastErrorMessage = lastErrorMessage
        }
    }

    struct Summary: Codable {
        let propertyCount: Int
        let sessionCount: Int
        let shotCount: Int
        let mediaCount: Int
        let eligiblePropertyCount: Int
        let eligibleSessionCount: Int
        let eligibleShotCount: Int
        let eligibleMediaCount: Int
        let b1PropertyCount: Int
        let b1SessionCount: Int
        let b1ShotCount: Int
        let b2WarningPropertyCount: Int
        let b2WarningSessionCount: Int
        let b2WarningShotCount: Int
        let missingMediaCount: Int
    }

    struct EntityEntry: Codable {
        let entityType: String
        let localID: UUID
        let parentLocalID: UUID?
        let propertyID: UUID?
        let sessionID: UUID?
        let activeOrganizationID: UUID
        let eligible: Bool
        let b1RemoteExists: Bool
        let b2WarningRemoteIDs: [UUID]
        let reasons: [String]
        let attributes: [String: String]
        var mutation: MutationStatus

        private enum CodingKeys: String, CodingKey {
            case entityType
            case localID
            case parentLocalID
            case propertyID
            case sessionID
            case activeOrganizationID
            case eligible
            case b1RemoteExists
            case b2WarningRemoteIDs
            case reasons
            case attributes
            case mutation
        }

        init(
            entityType: String,
            localID: UUID,
            parentLocalID: UUID?,
            propertyID: UUID?,
            sessionID: UUID?,
            activeOrganizationID: UUID,
            eligible: Bool,
            b1RemoteExists: Bool,
            b2WarningRemoteIDs: [UUID],
            reasons: [String],
            attributes: [String: String],
            mutation: MutationStatus = MutationStatus()
        ) {
            self.entityType = entityType
            self.localID = localID
            self.parentLocalID = parentLocalID
            self.propertyID = propertyID
            self.sessionID = sessionID
            self.activeOrganizationID = activeOrganizationID
            self.eligible = eligible
            self.b1RemoteExists = b1RemoteExists
            self.b2WarningRemoteIDs = b2WarningRemoteIDs
            self.reasons = reasons
            self.attributes = attributes
            self.mutation = mutation
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            entityType = try container.decode(String.self, forKey: .entityType)
            localID = try container.decode(UUID.self, forKey: .localID)
            parentLocalID = try container.decodeIfPresent(UUID.self, forKey: .parentLocalID)
            propertyID = try container.decodeIfPresent(UUID.self, forKey: .propertyID)
            sessionID = try container.decodeIfPresent(UUID.self, forKey: .sessionID)
            activeOrganizationID = try container.decode(UUID.self, forKey: .activeOrganizationID)
            eligible = try container.decode(Bool.self, forKey: .eligible)
            b1RemoteExists = try container.decode(Bool.self, forKey: .b1RemoteExists)
            b2WarningRemoteIDs = try container.decodeIfPresent([UUID].self, forKey: .b2WarningRemoteIDs) ?? []
            reasons = try container.decodeIfPresent([String].self, forKey: .reasons) ?? []
            attributes = try container.decodeIfPresent([String: String].self, forKey: .attributes) ?? [:]
            mutation = try container.decodeIfPresent(MutationStatus.self, forKey: .mutation) ?? MutationStatus()
        }
    }

    struct MediaEntry: Codable {
        let shotID: UUID
        let propertyID: UUID
        let sessionID: UUID
        let activeOrganizationID: UUID
        let originalRelativePath: String
        let resolvedFilePath: String?
        let fileExists: Bool
        let fileSizeBytes: Int64?
        let checksumSHA256: String?
        let b1RemoteExists: Bool
        let b2WarningRemoteIDs: [UUID]
        let eligible: Bool
        let reasons: [String]
        let attributes: [String: String]
        var mutation: MutationStatus

        private enum CodingKeys: String, CodingKey {
            case shotID
            case propertyID
            case sessionID
            case activeOrganizationID
            case originalRelativePath
            case resolvedFilePath
            case fileExists
            case fileSizeBytes
            case checksumSHA256
            case b1RemoteExists
            case b2WarningRemoteIDs
            case eligible
            case reasons
            case attributes
            case mutation
        }

        init(
            shotID: UUID,
            propertyID: UUID,
            sessionID: UUID,
            activeOrganizationID: UUID,
            originalRelativePath: String,
            resolvedFilePath: String?,
            fileExists: Bool,
            fileSizeBytes: Int64?,
            checksumSHA256: String?,
            b1RemoteExists: Bool,
            b2WarningRemoteIDs: [UUID],
            eligible: Bool,
            reasons: [String],
            attributes: [String: String],
            mutation: MutationStatus = MutationStatus()
        ) {
            self.shotID = shotID
            self.propertyID = propertyID
            self.sessionID = sessionID
            self.activeOrganizationID = activeOrganizationID
            self.originalRelativePath = originalRelativePath
            self.resolvedFilePath = resolvedFilePath
            self.fileExists = fileExists
            self.fileSizeBytes = fileSizeBytes
            self.checksumSHA256 = checksumSHA256
            self.b1RemoteExists = b1RemoteExists
            self.b2WarningRemoteIDs = b2WarningRemoteIDs
            self.eligible = eligible
            self.reasons = reasons
            self.attributes = attributes
            self.mutation = mutation
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            shotID = try container.decode(UUID.self, forKey: .shotID)
            propertyID = try container.decode(UUID.self, forKey: .propertyID)
            sessionID = try container.decode(UUID.self, forKey: .sessionID)
            activeOrganizationID = try container.decode(UUID.self, forKey: .activeOrganizationID)
            originalRelativePath = try container.decode(String.self, forKey: .originalRelativePath)
            resolvedFilePath = try container.decodeIfPresent(String.self, forKey: .resolvedFilePath)
            fileExists = try container.decode(Bool.self, forKey: .fileExists)
            fileSizeBytes = try container.decodeIfPresent(Int64.self, forKey: .fileSizeBytes)
            checksumSHA256 = try container.decodeIfPresent(String.self, forKey: .checksumSHA256)
            b1RemoteExists = try container.decode(Bool.self, forKey: .b1RemoteExists)
            b2WarningRemoteIDs = try container.decodeIfPresent([UUID].self, forKey: .b2WarningRemoteIDs) ?? []
            eligible = try container.decode(Bool.self, forKey: .eligible)
            reasons = try container.decodeIfPresent([String].self, forKey: .reasons) ?? []
            attributes = try container.decodeIfPresent([String: String].self, forKey: .attributes) ?? [:]
            mutation = try container.decodeIfPresent(MutationStatus.self, forKey: .mutation) ?? MutationStatus()
        }
    }

    var schemaVersion: Int
    let generatedAt: Date
    let activeOrganizationID: UUID
    let authenticatedUserID: UUID?
    let summary: Summary
    var properties: [EntityEntry]
    var sessions: [EntityEntry]
    var shots: [EntityEntry]
    var media: [MediaEntry]
    var mutationRun: MutationRunStatus

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case generatedAt
        case activeOrganizationID
        case authenticatedUserID
        case summary
        case properties
        case sessions
        case shots
        case media
        case mutationRun
    }

    init(
        schemaVersion: Int = LegacyMigrationPreflightLedger.currentSchemaVersion,
        generatedAt: Date,
        activeOrganizationID: UUID,
        authenticatedUserID: UUID?,
        summary: Summary,
        properties: [EntityEntry],
        sessions: [EntityEntry],
        shots: [EntityEntry],
        media: [MediaEntry],
        mutationRun: MutationRunStatus = MutationRunStatus()
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.activeOrganizationID = activeOrganizationID
        self.authenticatedUserID = authenticatedUserID
        self.summary = summary
        self.properties = properties
        self.sessions = sessions
        self.shots = shots
        self.media = media
        self.mutationRun = mutationRun
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        activeOrganizationID = try container.decode(UUID.self, forKey: .activeOrganizationID)
        authenticatedUserID = try container.decodeIfPresent(UUID.self, forKey: .authenticatedUserID)
        summary = try container.decode(Summary.self, forKey: .summary)
        properties = try container.decodeIfPresent([EntityEntry].self, forKey: .properties) ?? []
        sessions = try container.decodeIfPresent([EntityEntry].self, forKey: .sessions) ?? []
        shots = try container.decodeIfPresent([EntityEntry].self, forKey: .shots) ?? []
        media = try container.decodeIfPresent([MediaEntry].self, forKey: .media) ?? []
        mutationRun = try container.decodeIfPresent(MutationRunStatus.self, forKey: .mutationRun) ?? MutationRunStatus()
    }
}

struct LegacyMigrationPreflightArtifacts {
    let directoryURL: URL
    let ledgerURL: URL
    let reportURL: URL
}

final class LocalStore {
    struct QueuedMutation: Codable, Equatable, Identifiable {
        enum Status: String, Codable {
            case pending
            case inFlight = "in_flight"
            case failed
            case completed
        }

        let id: UUID
        var entityType: String
        var entityID: UUID
        var organizationID: UUID
        var propertyID: UUID?
        var sessionID: UUID?
        var operation: String
        var payloadData: Data
        var idempotencyKey: String
        var createdAt: Date
        var updatedAt: Date
        var attemptCount: Int
        var lastAttemptAt: Date?
        var nextAttemptAt: Date?
        var lastError: String?
        var status: Status
        var acknowledgedAt: Date?
        var acknowledgedReason: String?
        var acknowledgedClassification: String?
        var acknowledgementSource: String?

        init(
            id: UUID = UUID(),
            entityType: String,
            entityID: UUID,
            organizationID: UUID,
            propertyID: UUID? = nil,
            sessionID: UUID? = nil,
            operation: String,
            payloadData: Data,
            idempotencyKey: String,
            createdAt: Date = Date(),
            updatedAt: Date = Date(),
            attemptCount: Int = 0,
            lastAttemptAt: Date? = nil,
            nextAttemptAt: Date? = nil,
            lastError: String? = nil,
            status: Status = .pending,
            acknowledgedAt: Date? = nil,
            acknowledgedReason: String? = nil,
            acknowledgedClassification: String? = nil,
            acknowledgementSource: String? = nil
        ) {
            self.id = id
            self.entityType = entityType
            self.entityID = entityID
            self.organizationID = organizationID
            self.propertyID = propertyID
            self.sessionID = sessionID
            self.operation = operation
            self.payloadData = payloadData
            self.idempotencyKey = idempotencyKey
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.attemptCount = attemptCount
            self.lastAttemptAt = lastAttemptAt
            self.nextAttemptAt = nextAttemptAt
            self.lastError = lastError
            self.status = status
            self.acknowledgedAt = acknowledgedAt
            self.acknowledgedReason = acknowledgedReason
            self.acknowledgedClassification = acknowledgedClassification
            self.acknowledgementSource = acknowledgementSource
        }

        var isAcknowledgedHistoricalDebt: Bool {
            acknowledgedAt != nil
        }
    }

    private let currentSessionSchemaVersion = 12
    private let fileIOQueue = DispatchQueue(label: "ScoutCapture.LocalStore.fileIO")
    private let fileIOQueueKey = DispatchSpecificKey<UInt8>()
    private let fileIOQueueValue: UInt8 = 1
    private var isShuttingDown = false

    deinit {}

    enum ShotUpsertMatchMode {
        case append
        case replaceGuidedKey
    }

    enum HubFetchSource: String {
        case iCloudSmallManifest = "icloud-small"
        case localSnapshot = "local-snapshot"
        case fullFallback = "full-fallback"
    }

    struct HubFetchResult {
        let properties: [Property]
        let organizations: [Organization]
        let source: HubFetchSource
    }

    private struct PropertyListCacheArtifactSnapshot {
        let url: URL
        let data: Data?
    }

    private struct PropertySyncEventArtifactSnapshot {
        let filename: String
        let data: Data
    }

    private struct PropertySyncEventDirectorySnapshot {
        let directoryExisted: Bool
        let files: [PropertySyncEventArtifactSnapshot]
    }
 
    enum StoreError: Error {
        case shuttingDown
        case propertyNotFound(UUID)
        case organizationNotFound(UUID)
        case observationNotFound(UUID)
        case sessionNotFound(UUID)
        case shotNotFound(UUID)
        case guidedShotNotFound(UUID)
        case guidedShotLifecycleInvalidState(UUID)
        case shotLifecycleBlockedForSealedSession(UUID)
        case shotLifecycleBlankReason
        case shotLifecycleInvalidState(UUID, expected: ShotLifecycleState, actual: ShotLifecycleState)
        case noAvailableFolderID
        case deleteVerificationFailed(URL)
    }

    struct ExportValidationReport {
        let phase: String
        let passed: Bool
        let failureCount: Int
        let reportText: String
    }

    struct ValidatedSessionExportArtifacts {
        let metadata: SessionMetadata
        let sessionData: Data
        let validationData: Data
        let originalFiles: [ExportOriginalFile]
        let prewritePassed: Bool
        let postwritePassed: Bool
    }

    struct ExportOriginalFile {
        let filename: String
        let sourceURL: URL
    }

    struct SessionArchiveSummary: Identifiable {
        let id: String
        let propertyID: UUID
        let sessionID: UUID
        let snapshotName: String
        let createdAt: Date
        let trigger: String
        let clientNameAtCapture: String?
        let orgNameAtCapture: String?
        let propertyNameAtCapture: String?
        let propertyAddressAtCapture: String?
        let isSealedCheckpoint: Bool
        let isDeliveredCheckpoint: Bool
        let fileCount: Int
        let totalBytes: Int64
    }

    struct MissingOriginalArchiveProvenance {
        let snapshotExists: Bool
        let snapshotCount: Int
        let latestSnapshotDate: Date?
        let payloadOriginalsCandidateHit: Bool
    }

    private struct SessionArchiveManifest: Codable {
        struct FileRecord: Codable {
            let relativePath: String
            let size: Int64
            let sha256: String
        }

        let schemaVersion: Int
        let createdAt: Date
        let trigger: String
        let propertyID: UUID
        let sessionID: UUID
        let clientNameAtCapture: String?
        let orgNameAtCapture: String?
        let propertyNameAtCapture: String?
        let propertyAddressAtCapture: String?
        let sessionStatus: String
        let isSealed: Bool
        let firstDeliveredAt: Date?
        let reExportExpiresAt: Date?
        let exportedAt: Date?
        let fileCount: Int
        let totalBytes: Int64
        let files: [FileRecord]
    }

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private let activeRootURL: URL
    private let scoutRootURL: URL
    private let propertiesURL: URL
    private let organizationsURL: URL
    private let hubIndexURL: URL
    private let localHubIndexCacheURL: URL
    private let queuedMutationsURL: URL
    private let propertyTombstonesURL: URL
    private let propertySyncEventsDirectoryURL: URL
    private let propertyFoldersURL: URL
    private let observationsDirectoryURL: URL
    private let guidedShotsDirectoryURL: URL
    private let sessionsDirectoryURL: URL

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        let appRoot = StorageRoot.prepareStorage()
        let scoutRoot = appRoot.appendingPathComponent("SCOUT", isDirectory: true)
        self.activeRootURL = appRoot
        self.scoutRootURL = scoutRoot
        self.propertiesURL = scoutRoot.appendingPathComponent("properties.json")
        self.organizationsURL = scoutRoot.appendingPathComponent("organizations.json")
        self.hubIndexURL = scoutRoot.appendingPathComponent("hub-index.json")
        let localAppSupportRoot = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScoutCapture", isDirectory: true)
        self.localHubIndexCacheURL = localAppSupportRoot.appendingPathComponent("local-hub-index.json")
        self.queuedMutationsURL = scoutRoot.appendingPathComponent("queued_mutations.json")
        self.propertyTombstonesURL = scoutRoot.appendingPathComponent("property-tombstones.json")
        self.propertySyncEventsDirectoryURL = scoutRoot
            .appendingPathComponent("sync-events", isDirectory: true)
            .appendingPathComponent("properties", isDirectory: true)
        self.propertyFoldersURL = scoutRoot.appendingPathComponent("Properties", isDirectory: true)
        self.observationsDirectoryURL = scoutRoot.appendingPathComponent("observations", isDirectory: true)
        self.guidedShotsDirectoryURL = scoutRoot.appendingPathComponent("guided-shots", isDirectory: true)
        self.sessionsDirectoryURL = scoutRoot.appendingPathComponent("sessions", isDirectory: true)
        self.fileIOQueue.setSpecific(key: fileIOQueueKey, value: fileIOQueueValue)

        try? createStorageDirectories(baseDirectoryURL: scoutRoot)

        // Pre-fire the iCloud download request as early as possible so the daemon
        // starts fetching hub-index.json before any polling loop begins.
        let hubURL = hubIndexURL
        DispatchQueue.global(qos: .userInitiated).async {
            if !fileManager.fileExists(atPath: hubURL.path) {
                try? fileManager.startDownloadingUbiquitousItem(at: hubURL)
            }
        }
    }

    init(testStorageRootURL: URL, fileManager: FileManager = .default) {
        self.fileManager = fileManager

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        let appRoot = testStorageRootURL
        let scoutRoot = appRoot.appendingPathComponent("SCOUT", isDirectory: true)
        self.activeRootURL = appRoot
        self.scoutRootURL = scoutRoot
        self.propertiesURL = scoutRoot.appendingPathComponent("properties.json")
        self.organizationsURL = scoutRoot.appendingPathComponent("organizations.json")
        self.hubIndexURL = scoutRoot.appendingPathComponent("hub-index.json")
        self.localHubIndexCacheURL = appRoot.appendingPathComponent("local-hub-index.json")
        self.queuedMutationsURL = scoutRoot.appendingPathComponent("queued_mutations.json")
        self.propertyTombstonesURL = scoutRoot.appendingPathComponent("property-tombstones.json")
        self.propertySyncEventsDirectoryURL = scoutRoot
            .appendingPathComponent("sync-events", isDirectory: true)
            .appendingPathComponent("properties", isDirectory: true)
        self.propertyFoldersURL = scoutRoot.appendingPathComponent("Properties", isDirectory: true)
        self.observationsDirectoryURL = scoutRoot.appendingPathComponent("observations", isDirectory: true)
        self.guidedShotsDirectoryURL = scoutRoot.appendingPathComponent("guided-shots", isDirectory: true)
        self.sessionsDirectoryURL = scoutRoot.appendingPathComponent("sessions", isDirectory: true)
        self.fileIOQueue.setSpecific(key: fileIOQueueKey, value: fileIOQueueValue)

        try? createStorageDirectories(baseDirectoryURL: scoutRoot)
    }

    func validateExport(_ metadata: SessionMetadata, phase: String) -> ExportValidationReport {
        var failures: [String] = []
        let canonicalIssues = metadata.issues
        let canonicalIssueIDs = Set(canonicalIssues.map(\.issueID))
        let activeIssues = canonicalIssues.filter {
            SessionMetadata.trimmedNonEmpty($0.issueStatus)?.lowercased() == "active"
        }
        let resolvedIssues = canonicalIssues.filter {
            SessionMetadata.trimmedNonEmpty($0.issueStatus)?.lowercased() == "resolved"
        }
        let derivedFlaggedIssues = metadata.flaggedIssues
        let reasonUpdatedEventsCount = canonicalIssues.reduce(into: 0) { count, issue in
            count += issue.historyEvents.filter { $0.type == "reason_updated" }.count
        }
        let shotsCount = metadata.shots.count
        let flaggedShotsCount = metadata.shots.filter(\.isFlagged).count
        let guidedShotsCount = metadata.shots.filter(\.isGuided).count
        let retakeShotsCount = metadata.shots.filter {
            SessionMetadata.trimmedNonEmpty($0.captureKind) == "retake"
        }.count
        let capturedShotsCount = metadata.shots.filter {
            SessionMetadata.trimmedNonEmpty($0.captureKind) == "captured"
        }.count
        let guidedRowsCount = metadata.guidedShots.count
        let guidedSkippedCount = metadata.guidedShots.filter { $0.skipReason != nil }.count
        let guidedRetiredCount = metadata.guidedShots.filter { $0.status == .retired }.count
        let sessionIDs = Set([metadata.sessionID])
        let shotIDs = Set(metadata.shots.map(\.shotID))
        let issueHistoryRowsCount = canonicalIssues.reduce(into: 0) { count, issue in
            count += issue.historyEvents.filter { event in
                event.sessionId == metadata.sessionID
            }.count
        }
        var orphanIssueHistoryIssueRefs = 0
        var orphanIssueHistorySessionRefs = 0
        var orphanIssueHistoryShotRefs = 0

        if derivedFlaggedIssues.count != activeIssues.count {
            failures.append("flaggedIssues count \(derivedFlaggedIssues.count) does not match active issues count \(activeIssues.count)")
        }

        let canonicalByID = Dictionary(uniqueKeysWithValues: canonicalIssues.map { ($0.issueID, $0) })
        for flaggedIssue in derivedFlaggedIssues {
            guard let canonical = canonicalByID[flaggedIssue.issueID] else {
                failures.append("flaggedIssues contains issueID \(flaggedIssue.issueID.uuidString) missing from issues[]")
                continue
            }

            if SessionMetadata.trimmedNonEmpty(canonical.issueStatus)?.lowercased() != "active" {
                failures.append("flaggedIssues issueID \(flaggedIssue.issueID.uuidString) is not active in issues[]")
            }

            if canonical.currentReason != flaggedIssue.currentReason ||
                canonical.previousReason != flaggedIssue.previousReason ||
                canonical.historyEvents != flaggedIssue.historyEvents {
                failures.append("flaggedIssues issueID \(flaggedIssue.issueID.uuidString) does not match canonical issues[] record")
            }
        }

        for issue in canonicalIssues {
            let reasonEvents = issue.historyEvents.filter { $0.type == "reason_updated" }
            if !reasonEvents.isEmpty {
                if SessionMetadata.trimmedNonEmpty(issue.previousReason) == nil {
                    failures.append("issueID \(issue.issueID.uuidString) has reason_updated history but missing previousReason")
                } else if let latestOldReason = reasonEvents.last?.details["oldReason"],
                          SessionMetadata.trimmedNonEmpty(issue.previousReason) != SessionMetadata.trimmedNonEmpty(latestOldReason) {
                    failures.append("issueID \(issue.issueID.uuidString) previousReason does not match latest reason_updated.oldReason")
                }
            }

            if SessionMetadata.trimmedNonEmpty(issue.currentReason) == nil {
                failures.append("issueID \(issue.issueID.uuidString) missing currentReason")
            }
        }

        for shot in metadata.shots where shot.isFlagged {
            if SessionMetadata.trimmedNonEmpty(shot.firstCaptureKind) == nil {
                failures.append("flagged shotID \(shot.shotID.uuidString) missing firstCaptureKind")
            }
            if SessionMetadata.trimmedNonEmpty(shot.captureKind) == "retake",
               SessionMetadata.trimmedNonEmpty(shot.firstCaptureKind) != "captured" {
                failures.append("flagged shotID \(shot.shotID.uuidString) has captureKind retake but firstCaptureKind is not captured")
            }
            if SessionMetadata.trimmedNonEmpty(shot.priority) == nil {
                failures.append("flagged shotID \(shot.shotID.uuidString) missing priority")
            }
        }
        var logicalShotKeys = Set<String>()
        var duplicateLogicalShotIdentityCount = 0
        for shot in metadata.shots {
            let key = logicalShotIdentity(for: shot)
            if !logicalShotKeys.insert(key).inserted {
                failures.append("duplicate logical shot identity \(key)")
                duplicateLogicalShotIdentityCount += 1
            }
        }

        for issue in canonicalIssues {
            if !canonicalIssueIDs.contains(issue.issueID) {
                orphanIssueHistoryIssueRefs += issue.historyEvents.filter { event in
                    event.sessionId == metadata.sessionID
                }.count
                failures.append("issue_history references missing issueID \(issue.issueID.uuidString)")
                continue
            }
            for event in issue.historyEvents where event.sessionId == metadata.sessionID {
                if let eventSessionID = event.sessionId, !sessionIDs.contains(eventSessionID) {
                    orphanIssueHistorySessionRefs += 1
                    failures.append("issue_history eventID \(event.id.uuidString) references sessionID \(eventSessionID.uuidString) not in sessions.csv")
                }

                let rawShotID = (event.details["shotId"] ?? event.details["shotID"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !rawShotID.isEmpty {
                    if let eventShotID = UUID(uuidString: rawShotID) {
                        if !shotIDs.contains(eventShotID) {
                            orphanIssueHistoryShotRefs += 1
                            failures.append("issue_history eventID \(event.id.uuidString) references shotID \(eventShotID.uuidString) not in shots.csv")
                        }
                    } else {
                        orphanIssueHistoryShotRefs += 1
                        failures.append("issue_history eventID \(event.id.uuidString) has invalid shotID \(rawShotID)")
                    }
                }
            }
        }

        let statusLine = failures.isEmpty ? "PASS" : "FAIL"
        var lines: [String] = []
        lines.append("EXPORT VALIDATION SUMMARY (\(phase))")
        lines.append("Counts:")
        lines.append("  shots: \(shotsCount)")
        lines.append("  flaggedShots: \(flaggedShotsCount)")
        lines.append("  guidedShots: \(guidedShotsCount)")
        lines.append("  retakeShots: \(retakeShotsCount)")
        lines.append("  capturedShots: \(capturedShotsCount)")
        lines.append("")
        lines.append("  issues: \(canonicalIssues.count)")
        lines.append("  activeIssues: \(activeIssues.count)")
        lines.append("  resolvedIssues: \(resolvedIssues.count)")
        lines.append("  flaggedIssues: \(derivedFlaggedIssues.count)")
        lines.append("  reasonUpdatedEvents: \(reasonUpdatedEventsCount)")
        lines.append("")
        lines.append("  guidedRows: \(guidedRowsCount)")
        lines.append("  guidedSkipped: \(guidedSkippedCount)")
        lines.append("  guidedRetired: \(guidedRetiredCount)")
        lines.append("")
        lines.append("  issueHistoryRows: \(issueHistoryRowsCount)")
        lines.append("  orphanIssueHistoryIssueRefs: \(orphanIssueHistoryIssueRefs)")
        lines.append("  orphanIssueHistorySessionRefs: \(orphanIssueHistorySessionRefs)")
        lines.append("  orphanIssueHistoryShotRefs: \(orphanIssueHistoryShotRefs)")
        lines.append("  duplicateLogicalShotIdentity: \(duplicateLogicalShotIdentityCount)")
        lines.append("Result: \(statusLine)")
        if !failures.isEmpty {
            lines.append("Failures:")
            lines.append(contentsOf: failures.map { "- \($0)" })
        }

        return ExportValidationReport(
            phase: phase,
            passed: failures.isEmpty,
            failureCount: failures.count,
            reportText: lines.joined(separator: "\n")
        )
    }

    func validationText(
        for metadata: SessionMetadata,
        prewrite: ExportValidationReport,
        postwrite: ExportValidationReport,
        createdAt: Date = Date()
    ) -> String {
        let formatter = ISO8601DateFormatter()
        let headerLines: [String] = [
            "SCOUT Export Validation",
            "schemaVersion: \(metadata.schemaVersion)",
            "appVersion: \(metadata.appVersion)",
            "sessionID: \(metadata.sessionID.uuidString)",
            "propertyID: \(metadata.propertyID.uuidString)",
            "isBaselineSession: \(metadata.isBaselineSession ? "true" : "false")",
            "createdAt: \(formatter.string(from: createdAt))"
        ]

        let finalResult = (prewrite.passed && postwrite.passed) ? "PASS" : "FAIL"
        return [
            headerLines.joined(separator: "\n"),
            prewrite.reportText,
            postwrite.reportText,
            "FINAL RESULT: \(finalResult)"
        ].joined(separator: "\n\n")
    }

    func validatedSessionExportArtifacts(for session: Session) throws -> ValidatedSessionExportArtifacts {
        try ensureSessionMetadata(for: session)
        let exportObject = try loadSessionMetadata(propertyID: session.propertyID, sessionID: session.id)
        let validationReportPre = validateExport(exportObject, phase: "prewrite")
        try saveSessionMetadataAtomically(
            propertyID: session.propertyID,
            sessionID: session.id,
            metadata: exportObject
        )
        let sessionURL = sessionJSONURL(propertyID: session.propertyID, sessionID: session.id)
        let sessionData = try Data(contentsOf: sessionURL)
        let exportObjectPost = try decoder.decode(SessionMetadata.self, from: sessionData)
        let exportReadyMetadata = sanitizedExportMetadata(exportObjectPost)
        let validationReportPost = validateExport(exportReadyMetadata, phase: "postwrite")
        let validationData = Data(
            validationText(
                for: exportReadyMetadata,
                prewrite: validationReportPre,
                postwrite: validationReportPost
            ).utf8
        )
        let exportSessionData = try encoder.encode(exportReadyMetadata)
        let originalFiles = exportOriginalFiles(for: exportReadyMetadata)

        return ValidatedSessionExportArtifacts(
            metadata: exportReadyMetadata,
            sessionData: exportSessionData,
            validationData: validationData,
            originalFiles: originalFiles,
            prewritePassed: validationReportPre.passed,
            postwritePassed: validationReportPost.passed
        )
    }

    func exportOriginalFiles(for metadata: SessionMetadata) -> [ExportOriginalFile] {
        let originalsRoot = originalsFolderURL(propertyID: metadata.propertyID, sessionID: metadata.sessionID)
        var seen = Set<String>()

        return clientExportShots(in: metadata).compactMap { shot in
            let filename = exportOriginalFilename(for: shot)
            guard !filename.isEmpty else { return nil }
            guard seen.insert(filename).inserted else { return nil }

            let directURL = originalsRoot.appendingPathComponent(filename)
            if fileManager.fileExists(atPath: directURL.path) {
                return ExportOriginalFile(filename: filename, sourceURL: directURL)
            }

            let relativeName = URL(fileURLWithPath: shot.originalRelativePath).lastPathComponent
            guard !relativeName.isEmpty else { return nil }
            let relativeURL = originalsRoot.appendingPathComponent(relativeName)
            guard fileManager.fileExists(atPath: relativeURL.path) else { return nil }
            return ExportOriginalFile(filename: filename, sourceURL: relativeURL)
        }
    }

    private func sanitizedExportMetadata(_ metadata: SessionMetadata) -> SessionMetadata {
        var sanitized = metadata
        let shotRelativePathByID = Dictionary(uniqueKeysWithValues: metadata.shots.map { ($0.shotID, $0.originalRelativePath) })
        sanitized.guidedShots = metadata.guidedShots.map { guided in
            sanitizeGuidedShotForExport(guided, shotRelativePathByID: shotRelativePathByID)
        }
        return sanitized
    }

    private func sanitizeGuidedShotForExport(
        _ guidedShot: GuidedShot,
        shotRelativePathByID: [UUID: String]
    ) -> GuidedShot {
        var sanitized = guidedShot
        let mappedShotPath = guidedShot.shot.flatMap { shotRelativePathByID[$0.id] }

        if var shot = sanitized.shot {
            shot.imageLocalIdentifier = sanitizeExportPath(
                shot.imageLocalIdentifier,
                preferredRelativePath: mappedShotPath,
                defaultFolder: "Originals"
            )
            sanitized.shot = shot
        }

        sanitized.referenceImageLocalIdentifier = sanitizeExportPath(
            guidedShot.referenceImageLocalIdentifier,
            preferredRelativePath: mappedShotPath,
            defaultFolder: "Originals"
        )
        sanitized.referenceImagePath = sanitizeExportPath(
            guidedShot.referenceImagePath,
            preferredRelativePath: mappedShotPath,
            defaultFolder: "Originals"
        )

        return sanitized
    }

    private func sanitizeExportPath(
        _ rawValue: String?,
        preferredRelativePath: String?,
        defaultFolder: String
    ) -> String? {
        let trimmed = trimmedNonEmpty(rawValue)
        if let preferred = trimmedNonEmpty(preferredRelativePath) {
            return preferred
        }
        guard let trimmed else { return nil }
        let filename = URL(fileURLWithPath: trimmed).lastPathComponent
        guard !filename.isEmpty else { return nil }
        return "\(defaultFolder)/\(filename)"
    }

    private func exportOriginalFilename(for shot: ShotMetadata) -> String {
        let directName = URL(fileURLWithPath: shot.originalFilename).lastPathComponent
        if !directName.isEmpty {
            return directName
        }
        return URL(fileURLWithPath: shot.originalRelativePath).lastPathComponent
    }

    private func clientExportShots(in metadata: SessionMetadata) -> [ShotMetadata] {
        metadata.shots.filter { $0.shouldAppearInDefaultExports }
    }

    private func clientExportGuidedRows(in metadata: SessionMetadata) -> [GuidedShot] {
        metadata.guidedShots.filter { !$0.isRetired && $0.status != .retired }
    }

    func exportCSVFiles(for metadata: SessionMetadata) -> [(filename: String, data: Data)] {
        [
            ("sessions.csv", Data(buildSessionsCSV(metadata: metadata).utf8)),
            ("shots.csv", Data(buildShotsCSV(metadata: metadata).utf8)),
            ("issues.csv", Data(buildIssuesCSV(metadata: metadata).utf8)),
            ("issue_history.csv", Data(buildIssueHistoryCSV(metadata: metadata).utf8)),
            ("guided_rows.csv", Data(buildGuidedRowsCSV(metadata: metadata).utf8))
        ]
    }

    private func buildSessionsCSV(metadata: SessionMetadata) -> String {
        let headers = [
            "session_id",
            "property_id",
            "org_id",
            "org_name",
            "folder_id",
            "property_name",
            "property_address",
            "propertyStreet",
            "propertyCity",
            "propertyState",
            "propertyZip",
            "primary_contact_name",
            "primary_contact_phone",
            "primary_contact_email",
            "started_at_utc",
            "ended_at_utc",
            "is_baseline",
            "status",
            "schema_version",
            "app_version",
            "time_zone",
            "capture_profile"
        ]

        let property = currentProperty(for: metadata.propertyID)
        let propertyName = metadata.propertyNameAtExport ?? metadata.propertyNameAtCapture ?? ""
        let propertyAddress = metadata.propertyAddressAtCapture ?? ""
        let orgID = metadata.orgID?.uuidString ?? property?.orgId?.uuidString ?? ""
        let orgName = metadata.orgNameAtCapture ?? property?.orgId.flatMap { organization(withID: $0)?.name } ?? ""
        let folderID = metadata.folderIDAtCapture ?? property?.folderId ?? ""
        let primaryContactName = metadata.primaryContactNameAtCapture ?? property?.clientName ?? ""
        let primaryContactPhone = metadata.propertyPhoneAtCapture ?? property?.clientPhone ?? ""
        let primaryContactEmail = metadata.primaryContactEmailAtCapture ?? property?.clientEmail ?? ""
        let propertyStreet = metadata.propertyStreetAtCapture ?? property?.street ?? ""
        let propertyCity = metadata.propertyCityAtCapture ?? property?.city ?? ""
        let propertyState = metadata.propertyStateAtCapture ?? property?.state ?? ""
        let propertyZip = metadata.propertyZipAtCapture ?? property?.zip ?? ""
        let row: [String] = [
            metadata.sessionID.uuidString,
            metadata.propertyID.uuidString,
            orgID,
            orgName,
            folderID,
            propertyName,
            propertyAddress,
            propertyStreet,
            propertyCity,
            propertyState,
            propertyZip,
            primaryContactName,
            primaryContactPhone,
            primaryContactEmail,
            iso8601String(metadata.startedAt),
            iso8601String(metadata.endedAt),
            boolString(metadata.isBaselineSession),
            metadata.status.rawValue,
            String(metadata.schemaVersion),
            metadata.appVersion,
            metadata.timeZoneIdentifierAtCapture,
            metadata.captureProfile ?? ""
        ]
        return csvString(headers: headers, rows: [row])
    }

    private func buildShotsCSV(metadata: SessionMetadata) -> String {
        let headers = [
            "shot_id",
            "session_id",
            "property_id",
            "propertyStreet",
            "propertyCity",
            "propertyState",
            "propertyZip",
            "building",
            "elevation",
            "detail_type",
            "angle_index",
            "shot_key",
            "logical_shot_identity",
            "capture_kind",
            "is_flagged",
            "is_guided",
            "issue_id",
            "captured_at_utc",
            "latitude",
            "longitude",
            "lens",
            "original_filename",
            "original_byte_size",
            "trade",
            "priority",
            "capture_profile"
        ]

        let property = currentProperty(for: metadata.propertyID)
        let propertyStreet = metadata.propertyStreetAtCapture ?? property?.street ?? ""
        let propertyCity = metadata.propertyCityAtCapture ?? property?.city ?? ""
        let propertyState = metadata.propertyStateAtCapture ?? property?.state ?? ""
        let propertyZip = metadata.propertyZipAtCapture ?? property?.zip ?? ""
        let rows = clientExportShots(in: metadata).map { shot in
            [
                shot.shotID.uuidString,
                metadata.sessionID.uuidString,
                metadata.propertyID.uuidString,
                propertyStreet,
                propertyCity,
                propertyState,
                propertyZip,
                shot.building,
                shot.elevation,
                shot.detailType,
                String(max(1, shot.angleIndex)),
                shot.shotKey,
                shot.logicalShotIdentity,
                normalizedCaptureKind(for: shot),
                boolString(shot.isFlagged),
                boolString(shot.isGuided),
                shot.issueID?.uuidString ?? "",
                iso8601String(shot.createdAt),
                decimalString(shot.latitude),
                decimalString(shot.longitude),
                shot.lens ?? "",
                shot.originalFilename,
                intString(shot.originalByteSize),
                shot.trade ?? "",
                shot.isFlagged ? (shot.priority ?? "") : "",
                metadata.captureProfile ?? ""
            ]
        }

        return csvString(headers: headers, rows: rows)
    }

    private func buildIssuesCSV(metadata: SessionMetadata) -> String {
        let headers = [
            "issue_id",
            "property_id",
            "propertyStreet",
            "propertyCity",
            "propertyState",
            "propertyZip",
            "first_seen_session_id",
            "last_capture_session_id",
            "current_status",
            "current_reason",
            "previous_reason",
            "first_seen_at_utc",
            "last_seen_at_utc",
            "resolved_at_utc",
            "shot_key",
            "logical_shot_identity"
        ]

        let property = currentProperty(for: metadata.propertyID)
        let propertyStreet = metadata.propertyStreetAtCapture ?? property?.street ?? ""
        let propertyCity = metadata.propertyCityAtCapture ?? property?.city ?? ""
        let propertyState = metadata.propertyStateAtCapture ?? property?.state ?? ""
        let propertyZip = metadata.propertyZipAtCapture ?? property?.zip ?? ""
        let exportShots = clientExportShots(in: metadata)
        let shotsByIssueID = Dictionary(grouping: exportShots.compactMap { shot -> (UUID, ShotMetadata)? in
            guard let issueID = shot.issueID else { return nil }
            return (issueID, shot)
        }, by: \.0).mapValues { pairs in
            pairs.map(\.1).sorted { $0.createdAt > $1.createdAt }
        }
        let rows = metadata.issues.map { issue in
            let firstSeenSessionId = issue.historyEvents.sorted { $0.timestamp < $1.timestamp }.first?.sessionId?.uuidString ?? ""
            let linkedShot = shotsByIssueID[issue.issueID]?.first
            return [
                issue.issueID.uuidString,
                metadata.propertyID.uuidString,
                propertyStreet,
                propertyCity,
                propertyState,
                propertyZip,
                firstSeenSessionId,
                issue.lastCaptureSessionId?.uuidString ?? "",
                issue.issueStatus,
                issue.currentReason ?? "",
                issue.previousReason ?? "",
                iso8601String(issue.firstSeenAt),
                iso8601String(issue.lastSeenAt),
                iso8601String(issue.resolvedAt),
                issue.shotKey ?? linkedShot?.shotKey ?? "",
                logicalShotIdentity(for: issue, linkedShot: linkedShot, sessionID: metadata.sessionID)
            ]
        }

        return csvString(headers: headers, rows: rows)
    }

    private func buildIssueHistoryCSV(metadata: SessionMetadata) -> String {
        let headers = [
            "event_id",
            "issue_id",
            "session_id",
            "event_type",
            "timestamp_utc",
            "field_changed",
            "old_value",
            "new_value",
            "shot_id",
            "logical_shot_identity"
        ]

        let exportShots = clientExportShots(in: metadata)
        let shotsByID = Dictionary(uniqueKeysWithValues: exportShots.map { ($0.shotID.uuidString.lowercased(), $0) })
        let shotsByIssueID = Dictionary(grouping: exportShots.compactMap { shot -> (UUID, ShotMetadata)? in
            guard let issueID = shot.issueID else { return nil }
            return (issueID, shot)
        }, by: \.0).mapValues { pairs in
            pairs.map(\.1).sorted { $0.createdAt > $1.createdAt }
        }
        let rows = metadata.issues.flatMap { issue in
            issue.historyEvents
                .filter { $0.sessionId == metadata.sessionID }
                .sorted { $0.timestamp < $1.timestamp }
                .map { event in
                let fieldChanged = event.details["field"] ?? ""
                let oldValue = event.details["oldValue"] ?? event.details["oldReason"] ?? ""
                let newValue = event.details["newValue"] ?? event.details["newReason"] ?? ""
                let shotId = event.details["shotId"] ?? event.details["shotID"] ?? ""
                let linkedShot = shotsByID[shotId.lowercased()] ?? shotsByIssueID[issue.issueID]?.first
                return [
                    event.id.uuidString,
                    issue.issueID.uuidString,
                    event.sessionId?.uuidString ?? "",
                    event.type,
                    iso8601String(event.timestamp),
                    fieldChanged,
                    oldValue,
                    newValue,
                    shotId,
                    logicalShotIdentity(for: issue, linkedShot: linkedShot, sessionID: metadata.sessionID)
                ]
            }
        }

        return csvString(headers: headers, rows: rows)
    }

    private func buildGuidedRowsCSV(metadata: SessionMetadata) -> String {
        let headers = [
            "guided_row_id",
            "session_id",
            "property_id",
            "propertyStreet",
            "propertyCity",
            "propertyState",
            "propertyZip",
            "building",
            "elevation",
            "detail_type",
            "angle_index",
            "status",
            "is_retired",
            "retired_at",
            "skip_reason",
            "skip_session_id",
            "trade",
            "priority"
        ]

        let property = currentProperty(for: metadata.propertyID)
        let propertyStreet = metadata.propertyStreetAtCapture ?? property?.street ?? ""
        let propertyCity = metadata.propertyCityAtCapture ?? property?.city ?? ""
        let propertyState = metadata.propertyStateAtCapture ?? property?.state ?? ""
        let propertyZip = metadata.propertyZipAtCapture ?? property?.zip ?? ""
        let exportShots = clientExportShots(in: metadata)
        let tradeByShotID = Dictionary(uniqueKeysWithValues: exportShots.map { ($0.shotID, $0.trade ?? "") })
        let priorityByShotID = Dictionary(
            uniqueKeysWithValues: exportShots.map { shot in
                (shot.shotID, shot.isFlagged ? (shot.priority ?? "") : "")
            }
        )
        let rows = clientExportGuidedRows(in: metadata).map { row in
            [
                row.id.uuidString,
                metadata.sessionID.uuidString,
                metadata.propertyID.uuidString,
                propertyStreet,
                propertyCity,
                propertyState,
                propertyZip,
                row.building ?? "",
                row.targetElevation ?? "",
                row.detailType ?? "",
                intString(row.angleIndex.map { max(1, $0) }),
                row.status.rawValue,
                boolString(row.isRetired),
                iso8601String(row.retiredAt),
                row.skipReason?.rawValue ?? "",
                row.skipSessionID?.uuidString ?? "",
                row.shot.flatMap { tradeByShotID[$0.id] } ?? "",
                row.shot.flatMap { priorityByShotID[$0.id] } ?? ""
            ]
        }

        return csvString(headers: headers, rows: rows)
    }

    private func normalizedCaptureKind(for shot: ShotMetadata) -> String {
        if let captureKind = SessionMetadata.trimmedNonEmpty(shot.captureKind) {
            return captureKind
        }
        if shot.isFlagged, let firstCaptureKind = SessionMetadata.trimmedNonEmpty(shot.firstCaptureKind) {
            return firstCaptureKind
        }
        return "captured"
    }

    private func csvString(headers: [String], rows: [[String]]) -> String {
        ([headers] + rows)
            .map { $0.map(csvEscape).joined(separator: ",") }
            .joined(separator: "\n") + "\n"
    }

    private func csvEscape(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        if escaped.contains(",") || escaped.contains("\"") || escaped.contains("\n") || escaped.contains("\r") {
            return "\"\(escaped)\""
        }
        return escaped
    }

    private func iso8601String(_ date: Date?) -> String {
        guard let date else { return "" }
        return ISO8601DateFormatter().string(from: date)
    }

    private func boolString(_ value: Bool) -> String {
        value ? "true" : "false"
    }

    private func intString(_ value: Int?) -> String {
        guard let value else { return "" }
        return String(value)
    }

    private func decimalString(_ value: Double?) -> String {
        guard let value else { return "" }
        return String(value)
    }

    func performFileIOSync(_ work: () throws -> Void) rethrows {
        if isShuttingDown {
            return
        }
        if DispatchQueue.getSpecific(key: fileIOQueueKey) == fileIOQueueValue {
            try work()
            return
        }
        try fileIOQueue.sync {
            if self.isShuttingDown {
                return
            }
            try work()
        }
    }

    func performFileIOSync<T>(_ work: () throws -> T) throws -> T {
        if DispatchQueue.getSpecific(key: fileIOQueueKey) == fileIOQueueValue {
            if isShuttingDown {
                throw StoreError.shuttingDown
            }
            return try work()
        }
        if isShuttingDown {
            throw StoreError.shuttingDown
        }
        return try fileIOQueue.sync {
            return try work()
        }
    }

    func shutdown() {
        isShuttingDown = true
        if DispatchQueue.getSpecific(key: fileIOQueueKey) == fileIOQueueValue {
            return
        }
        fileIOQueue.sync { }
    }

    func fetchQueuedMutations() throws -> [QueuedMutation] {
        try performFileIOSync {
            try readQueuedMutations()
        }
    }

    @discardableResult
    func appendQueuedMutation(_ mutation: QueuedMutation) throws -> QueuedMutation {
        try performFileIOSync {
            var queued = try readQueuedMutations()
            if let index = queued.firstIndex(where: {
                $0.idempotencyKey == mutation.idempotencyKey && $0.status != .completed
            }) {
                let existing = queued[index]
                queued[index] = QueuedMutation(
                    id: existing.id,
                    entityType: mutation.entityType,
                    entityID: mutation.entityID,
                    organizationID: mutation.organizationID,
                    propertyID: mutation.propertyID,
                    sessionID: mutation.sessionID,
                    operation: mutation.operation,
                    payloadData: mutation.payloadData,
                    idempotencyKey: mutation.idempotencyKey,
                    createdAt: existing.createdAt,
                    updatedAt: mutation.updatedAt,
                    attemptCount: existing.attemptCount,
                    lastAttemptAt: existing.lastAttemptAt,
                    nextAttemptAt: nil,
                    lastError: nil,
                    status: .pending
                )
                try writeQueuedMutations(queued)
                NotificationCenter.default.post(name: .scoutPersistentDataDidChange, object: nil)
                return queued[index]
            }

            queued.append(mutation)
            try writeQueuedMutations(queued)
            NotificationCenter.default.post(name: .scoutPersistentDataDidChange, object: nil)
            return mutation
        }
    }

    @discardableResult
    func updateQueuedMutation(_ mutation: QueuedMutation) throws -> QueuedMutation {
        try performFileIOSync {
            var queued = try readQueuedMutations()
            guard let index = queued.firstIndex(where: { $0.id == mutation.id }) else {
                throw NSError(
                    domain: "LocalStore.QueuedMutations",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Queued mutation not found: \(mutation.id.uuidString)"]
                )
            }
            queued[index] = mutation
            try writeQueuedMutations(queued)
            NotificationCenter.default.post(name: .scoutPersistentDataDidChange, object: nil)
            return mutation
        }
    }

    func removeQueuedMutation(id: UUID) throws {
        try performFileIOSync {
            var queued = try readQueuedMutations()
            queued.removeAll { $0.id == id }
            try writeQueuedMutations(queued)
            NotificationCenter.default.post(name: .scoutPersistentDataDidChange, object: nil)
        }
    }

    private func readQueuedMutations() throws -> [QueuedMutation] {
        guard fileManager.fileExists(atPath: queuedMutationsURL.path) else { return [] }
        let data = try Data(contentsOf: queuedMutationsURL)
        return try decoder.decode([QueuedMutation].self, from: data)
    }

    private func writeQueuedMutations(_ queuedMutations: [QueuedMutation]) throws {
        if queuedMutations.isEmpty {
            if fileManager.fileExists(atPath: queuedMutationsURL.path) {
                try fileManager.removeItem(at: queuedMutationsURL)
            }
            return
        }

        let data = try encoder.encode(queuedMutations)
        try atomicWriteFileData(data, to: queuedMutationsURL)
    }

    // MARK: - Properties CRUD

    func fetchProperties() throws -> [Property] {
        try performFileIOSync {
            try migratedPropertyAndOrganizationState().properties
        }
    }

    func fetchOrganizations() throws -> [Organization] {
        try performFileIOSync {
            try migratedPropertyAndOrganizationState().organizations
        }
    }

    func fetchPropertyAndOrganizationStateForHub(downloadTimeout: TimeInterval) throws -> HubFetchResult {
        try performFileIOSync {
            if let hubIndex = try readHubIndexRaw(downloadTimeout: downloadTimeout),
               !hubIndex.properties.isEmpty {
                let properties = hubIndex.properties.map { $0.asProperty() }
                let organizations = hubIndex.organizations.map { $0.asOrganization() }
                return HubFetchResult(
                    properties: properties,
                    organizations: organizations,
                    source: .iCloudSmallManifest
                )
            }

            let state = try migratedPropertyAndOrganizationState(downloadTimeout: downloadTimeout)
            return HubFetchResult(
                properties: state.properties,
                organizations: state.organizations,
                source: .fullFallback
            )
        }
    }

    func fetchPropertyAndOrganizationStateFromHubIndex(downloadTimeout: TimeInterval) throws -> HubFetchResult? {
        try performFileIOSync {
            guard let hubIndex = try readHubIndexRaw(downloadTimeout: downloadTimeout),
                  !hubIndex.properties.isEmpty else {
                return nil
            }
            let properties = hubIndex.properties.map { $0.asProperty() }
            let organizations = hubIndex.organizations.map { $0.asOrganization() }
            return HubFetchResult(
                properties: properties,
                organizations: organizations,
                source: .iCloudSmallManifest
            )
        }
    }

    func fetchPropertyAndOrganizationStateFromLocalHubIndexCache() throws -> HubFetchResult? {
        try performFileIOSync {
            guard let hubIndex = try readLocalHubIndexCacheRaw(),
                  !hubIndex.properties.isEmpty else {
                return nil
            }
            let properties = hubIndex.properties.map { $0.asProperty() }
            let organizations = hubIndex.organizations.map { $0.asOrganization() }
            return HubFetchResult(
                properties: properties,
                organizations: organizations,
                source: .localSnapshot
            )
        }
    }

    func replacePropertyListCacheAtomically(
        properties: [Property],
        organizations: [Organization]
    ) throws {
        try performFileIOSync {
            let artifactURLs = [
                propertiesURL,
                organizationsURL,
                hubIndexURL,
                localHubIndexCacheURL
            ]
            let snapshots = try snapshotPropertyListCacheArtifacts(at: artifactURLs)
            let propertySyncEventSnapshot = try snapshotPropertySyncEventArtifacts()

            do {
                try writeOrganizations(organizations)
                try writeProperties(properties)
                try writeHubIndexForAtomicReplacement(
                    properties: properties,
                    organizations: organizations
                )
                try overwritePropertySyncEvents(with: properties)
            } catch {
                try restorePropertyListCacheArtifacts(from: snapshots)
                try restorePropertySyncEventArtifacts(from: propertySyncEventSnapshot)
                throw error
            }
        }
    }

    @discardableResult
    func createOrganization(_ organization: Organization) throws -> Organization {
        try performFileIOSync {
            var state = try migratedPropertyAndOrganizationState()
            let normalizedName = organization.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedName.isEmpty else { return state.organizations.first ?? organization }
            if let existing = state.organizations.first(where: { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(normalizedName) == .orderedSame }) {
                return existing
            }
            let created = Organization(id: organization.id, name: normalizedName)
            state.organizations.append(created)
            state.organizations = normalizedOrganizations(state.organizations)
            try writeOrganizations(state.organizations)
            NotificationCenter.default.post(name: .scoutPersistentDataDidChange, object: nil)
            return created
        }
    }

    @discardableResult
    func updateOrganizationContact(organizationID: UUID, contact: OrganizationContact) throws -> Organization {
        try performFileIOSync {
            var state = try migratedPropertyAndOrganizationState()
            guard let index = state.organizations.firstIndex(where: { $0.id == organizationID }) else {
                throw StoreError.organizationNotFound(organizationID)
            }

            var organization = state.organizations[index]
            var contacts = organization.contacts
            if let contactIndex = contacts.firstIndex(where: { $0.id == contact.id }) {
                contacts[contactIndex] = contact
            } else {
                contacts.append(contact)
            }
            organization.contacts = normalizedOrganizationContacts(contacts)
            state.organizations[index] = organization
            state.organizations = normalizedOrganizations(state.organizations)
            try writeOrganizations(state.organizations)
            NotificationCenter.default.post(name: .scoutPersistentDataDidChange, object: nil)
            return state.organizations.first(where: { $0.id == organizationID }) ?? organization
        }
    }

    @discardableResult
    func deleteOrganizationContact(organizationID: UUID, contactID: UUID) throws -> Organization {
        try performFileIOSync {
            var state = try migratedPropertyAndOrganizationState()
            guard let index = state.organizations.firstIndex(where: { $0.id == organizationID }) else {
                throw StoreError.organizationNotFound(organizationID)
            }

            var organization = state.organizations[index]
            organization.contacts.removeAll { $0.id == contactID }
            organization.contacts = normalizedOrganizationContacts(organization.contacts)
            state.organizations[index] = organization
            state.organizations = normalizedOrganizations(state.organizations)
            try writeOrganizations(state.organizations)
            NotificationCenter.default.post(name: .scoutPersistentDataDidChange, object: nil)
            return state.organizations.first(where: { $0.id == organizationID }) ?? organization
        }
    }

    func exportPropertyFolderName(propertyID: UUID) throws -> String {
        let properties = try fetchProperties()
        guard let property = properties.first(where: { $0.id == propertyID }) else {
            throw StoreError.propertyNotFound(propertyID)
        }
        guard let folderNumber = parseFolderNumber(property.folderId) else {
            throw StoreError.noAvailableFolderID
        }
        let folderID = formatFolderID(folderNumber)
        let safePropertyName = Self.sanitizedExportFolderComponent(property.name)
        return [folderID, safePropertyName]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    func createProperty(_ property: Property) throws -> Property {
        try performFileIOSync {
            var state = try migratedPropertyAndOrganizationState()
            var created = property
            let validOrgIDs = Set(state.organizations.map(\.id))
            if created.orgId == nil || (created.orgId.map { !validOrgIDs.contains($0) } ?? false) {
                created.orgId = defaultOrganization(in: &state.organizations).id
            }
            if trimmedNonEmpty(created.folderId) == nil {
                created.folderId = try nextAvailableFolderID(in: state.properties)
            }
            state.properties.append(created)
            syncOrganizationContacts(in: &state.organizations, with: created)
            try writeOrganizations(state.organizations)
            try writeProperties(state.properties)
            try removePropertyDeletionTombstone(propertyID: created.id)
            try appendPropertySyncEvent(
                propertyID: created.id,
                operation: .upsert,
                property: created,
                occurredAt: created.updatedAt
            )
            NotificationCenter.default.post(name: .scoutPersistentDataDidChange, object: nil)
            return created
        }
    }

    @discardableResult
    func updateProperty(_ property: Property) throws -> Property {
        try performFileIOSync {
            var state = try migratedPropertyAndOrganizationState()
            guard let index = state.properties.firstIndex(where: { $0.id == property.id }) else {
                throw StoreError.propertyNotFound(property.id)
            }

            var updated = property
            let validOrgIDs = Set(state.organizations.map(\.id))
            if updated.orgId == nil || (updated.orgId.map { !validOrgIDs.contains($0) } ?? false) {
                updated.orgId = defaultOrganization(in: &state.organizations).id
            }
            if trimmedNonEmpty(updated.folderId) == nil {
                let otherProperties = state.properties.enumerated().compactMap { offset, value in
                    offset == index ? nil : value
                }
                updated.folderId = try nextAvailableFolderID(in: otherProperties)
            }
            updated.updatedAt = Date()
            state.properties[index] = updated
            syncOrganizationContacts(in: &state.organizations, with: updated)
            try writeOrganizations(state.organizations)
            try writeProperties(state.properties)
            try removePropertyDeletionTombstone(propertyID: updated.id)
            try appendPropertySyncEvent(
                propertyID: updated.id,
                operation: .upsert,
                property: updated,
                occurredAt: updated.updatedAt
            )
            NotificationCenter.default.post(name: .scoutPersistentDataDidChange, object: nil)
            return updated
        }
    }

    func deleteProperty(id: UUID) throws {
        try performFileIOSync {
            let originalProperties = try readProperties()
            guard originalProperties.contains(where: { $0.id == id }) else {
                throw StoreError.propertyNotFound(id)
            }

            let deletePlan = try makePropertyDeletePlan(propertyID: id, allProperties: originalProperties)
            let transactionRoot = activeRootURL
                .appendingPathComponent(".delete-transactions", isDirectory: true)
                .appendingPathComponent(id.uuidString, isDirectory: true)

            if fileManager.fileExists(atPath: transactionRoot.path) {
                try fileManager.removeItem(at: transactionRoot)
            }
            try fileManager.createDirectory(at: transactionRoot, withIntermediateDirectories: true)

            var movedArtifacts: [(source: URL, trash: URL)] = []
            var didWriteUpdatedProperties = false
            let originalTombstones = try readPropertyDeletionTombstones()
            var didWriteTombstones = false

            do {
                for (index, sourceURL) in deletePlan.urls.enumerated() where fileManager.fileExists(atPath: sourceURL.path) {
                    let trashURL = transactionRoot
                        .appendingPathComponent(String(format: "%03d", index), isDirectory: false)
                        .appendingPathExtension(sourceURL.pathExtension.isEmpty ? "artifact" : sourceURL.pathExtension)
                    try fileManager.moveItem(at: sourceURL, to: trashURL)
                    movedArtifacts.append((source: sourceURL, trash: trashURL))
                }

                for sourceURL in deletePlan.urls where fileManager.fileExists(atPath: sourceURL.path) {
                    throw StoreError.deleteVerificationFailed(sourceURL)
                }

                let updatedProperties = originalProperties.filter { $0.id != id }
                try writeProperties(updatedProperties)
                if updatedProperties.isEmpty, fileManager.fileExists(atPath: propertiesURL.path) {
                    try fileManager.removeItem(at: propertiesURL)
                }
                try purgeUnreferencedGuidedReferenceFiles(allProperties: updatedProperties)
                didWriteUpdatedProperties = true
                try appendPropertyDeletionTombstone(propertyID: id, deletedAt: Date())
                didWriteTombstones = true
                try appendPropertySyncEvent(
                    propertyID: id,
                    operation: .delete,
                    property: nil,
                    occurredAt: Date()
                )

                try fileManager.removeItem(at: transactionRoot)
                NotificationCenter.default.post(name: .scoutPersistentDataDidChange, object: nil)
            } catch {
                if didWriteUpdatedProperties {
                    try? writeProperties(originalProperties)
                }
                if didWriteTombstones {
                    try? writePropertyDeletionTombstones(originalTombstones)
                }

                for moved in movedArtifacts.reversed() {
                    do {
                        let parent = moved.source.deletingLastPathComponent()
                        if !fileManager.fileExists(atPath: parent.path) {
                            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
                        }
                        if fileManager.fileExists(atPath: moved.trash.path) {
                            try fileManager.moveItem(at: moved.trash, to: moved.source)
                        }
                    } catch {
                        print("[DeleteProperty] rollback failed source=\(moved.source.path) trash=\(moved.trash.path) error=\(error)")
                    }
                }

                if fileManager.fileExists(atPath: transactionRoot.path) {
                    try? fileManager.removeItem(at: transactionRoot)
                }

                throw error
            }
        }
    }

    // MARK: - Observations CRUD (per-property)

    func fetchObservations(propertyID: UUID) throws -> [Observation] {
        try ensurePropertyExists(propertyID)
        let observations = try readObservations(propertyID: propertyID)
        if try hasLegacyElevationValues(in: observationsFileURL(for: propertyID)) {
            try writeObservations(observations, propertyID: propertyID)
        }
        return observations
    }

    @discardableResult
    func createObservation(_ observation: Observation) throws -> Observation {
        try ensurePropertyExists(observation.propertyID)
        var observations = try readObservations(propertyID: observation.propertyID)
        observations.append(observation)
        try writeObservations(observations, propertyID: observation.propertyID)
        NotificationCenter.default.post(name: .scoutPersistentDataDidChange, object: nil)
        return observation
    }

    @discardableResult
    func updateObservation(_ observation: Observation) throws -> Observation {
        try ensurePropertyExists(observation.propertyID)
        var observations = try readObservations(propertyID: observation.propertyID)
        guard let index = observations.firstIndex(where: { $0.id == observation.id }) else {
            throw StoreError.observationNotFound(observation.id)
        }

        var incoming = observation
        incoming.updatedAt = Date()
        let updated = LocalConflictRules.reconcileObservationStatus(
            current: observations[index],
            incoming: incoming
        )
        observations[index] = updated
        try writeObservations(observations, propertyID: observation.propertyID)
        NotificationCenter.default.post(name: .scoutPersistentDataDidChange, object: nil)
        return updated
    }

    func deleteObservation(id: UUID, propertyID: UUID) throws {
        try ensurePropertyExists(propertyID)
        var observations = try readObservations(propertyID: propertyID)
        observations.removeAll { $0.id == id }
        try writeObservations(observations, propertyID: propertyID)
        NotificationCenter.default.post(name: .scoutPersistentDataDidChange, object: nil)
    }

    // MARK: - Guided Shots CRUD (per-property)

    func fetchGuidedShots(propertyID: UUID) throws -> [GuidedShot] {
        try ensurePropertyExists(propertyID)
        let guidedShots = try readGuidedShots(propertyID: propertyID)
        if try hasLegacyElevationValues(in: guidedShotsFileURL(for: propertyID)) {
            try writeGuidedShots(guidedShots, propertyID: propertyID)
        }
        return guidedShots
    }

    func saveGuidedShots(_ guidedShots: [GuidedShot], propertyID: UUID) throws {
        try ensurePropertyExists(propertyID)
        let normalized = LocalConflictRules.normalizeGuidedCompletionStates(guidedShots)
        try writeGuidedShots(normalized, propertyID: propertyID)
        NotificationCenter.default.post(name: .scoutPersistentDataDidChange, object: nil)
    }
    
    // MARK: - Sessions CRUD (per-property)
    
    func fetchSessions(propertyID: UUID) throws -> [Session] {
        try ensurePropertyExists(propertyID)
        return try readSessions(propertyID: propertyID)
            .filter { $0.deletedAt == nil }
    }

    func fetchSessionsForCacheBuild(propertyID: UUID) throws -> [Session] {
        try performFileIOSync {
            try readSessions(propertyID: propertyID)
        }
    }
    
    @discardableResult
    func upsertSession(_ session: Session) throws -> Session {
        try ensurePropertyExists(session.propertyID)
        var sessions = try readSessions(propertyID: session.propertyID)
        sessions.removeAll { $0.id == session.id }
        sessions.append(session)
        sessions.sort { $0.startedAt < $1.startedAt }
        try writeSessions(sessions, propertyID: session.propertyID)
        try upsertSessionMetadataLifecycle(for: session)
        NotificationCenter.default.post(name: .scoutPersistentDataDidChange, object: nil)
        return session
    }

    func ensureSessionMetadata(for session: Session) throws {
        try upsertSessionMetadataLifecycle(for: session)
    }

    func upsertShotMetadata(_ shot: ShotMetadata) throws {
        try upsertShot(
            propertyID: shot.propertyID,
            sessionID: shot.sessionID,
            shot: shot,
            matchMode: .replaceGuidedKey
        )
    }

    func loadSessionMetadata(propertyID: UUID, sessionID: UUID) throws -> SessionMetadata {
        try readOrRecoverSessionMetadata(propertyID: propertyID, sessionID: sessionID)
    }

    func saveSessionMetadataAtomically(propertyID: UUID, sessionID: UUID, metadata: SessionMetadata) throws {
        var updated = metadata
        updated.schemaVersion = max(updated.schemaVersion, currentSessionSchemaVersion)
        updated.propertyID = propertyID
        updated.sessionID = sessionID
        updated.appVersion = appVersionString()
        updated.deviceModel = deviceModelString()
        updated.osVersion = osVersionString()
        updated = normalizeSessionMetadata(updated, propertyID: propertyID, sessionID: sessionID)
        try writeSessionMetadata(updated)
        NotificationCenter.default.post(name: .scoutPersistentDataDidChange, object: nil)
    }

    func syncGuidedShotsToSessionMetadata(
        propertyID: UUID,
        sessionID: UUID,
        guidedShots: [GuidedShot]
    ) throws {
        var metadata = try loadSessionMetadata(propertyID: propertyID, sessionID: sessionID)
        metadata.guidedShots = LocalConflictRules.normalizeGuidedCompletionStates(guidedShots)
        try saveSessionMetadataAtomically(propertyID: propertyID, sessionID: sessionID, metadata: metadata)
    }

    func upsertShot(
        propertyID: UUID,
        sessionID: UUID,
        shot: ShotMetadata,
        matchMode: ShotUpsertMatchMode
    ) throws {
        var metadata = try loadSessionMetadata(propertyID: propertyID, sessionID: sessionID)
        metadata.schemaVersion = max(metadata.schemaVersion, currentSessionSchemaVersion)
        metadata.propertyID = propertyID
        metadata.sessionID = sessionID

        if let index = metadata.shots.firstIndex(where: { $0.shotID == shot.shotID }) {
            let existing = metadata.shots[index]
            var replacement = shot
            replacement = ShotMetadata(
                shotID: existing.shotID,
                propertyID: shot.propertyID,
                sessionID: shot.sessionID,
                createdAt: existing.createdAt,
                capturedAtLocal: existing.capturedAtLocal ?? shot.capturedAtLocal,
                updatedAt: shot.updatedAt,
                building: shot.building,
                elevation: shot.elevation,
                detailType: shot.detailType,
                angleIndex: shot.angleIndex,
                trade: shot.trade,
                priority: shot.priority,
                shotKey: shot.shotKey,
                isGuided: shot.isGuided,
                isFlagged: shot.isFlagged,
                issueID: shot.issueID,
                issueStatus: shot.issueStatus,
                captureKind: shot.captureKind,
                firstCaptureKind: existing.firstCaptureKind ?? shot.firstCaptureKind,
                noteText: shot.noteText,
                noteCategory: shot.noteCategory,
                originalFilename: shot.originalFilename,
                originalRelativePath: shot.originalRelativePath,
                originalByteSize: shot.originalByteSize,
                storageBucket: shot.storageBucket,
                storagePath: shot.storagePath,
                checksumSHA256: shot.checksumSHA256,
                byteSize: shot.byteSize,
                uploadState: shot.uploadState,
                uploadAttempts: shot.uploadAttempts,
                lastUploadError: shot.lastUploadError,
                stampedFilename: shot.stampedFilename,
                stampedRelativePath: shot.stampedRelativePath,
                captureMode: shot.captureMode,
                lens: shot.lens,
                exifOrientation: shot.exifOrientation,
                orientation: shot.orientation,
                latitude: shot.latitude,
                longitude: shot.longitude,
                accuracyMeters: shot.accuracyMeters,
                imageWidth: shot.imageWidth,
                imageHeight: shot.imageHeight,
                lifecycleState: shot.lifecycleState,
                retiredAt: shot.retiredAt,
                retiredReason: shot.retiredReason,
                retiredByUserID: shot.retiredByUserID,
                supersededByShotID: shot.supersededByShotID,
                supersedesShotID: shot.supersedesShotID,
                replacementReason: shot.replacementReason,
                hiddenFromReports: shot.hiddenFromReports,
                hiddenFromGallery: shot.hiddenFromGallery,
                lifecycleUpdatedAt: shot.lifecycleUpdatedAt
            )
            metadata.shots = LocalConflictRules.applyAppendOnlyMediaRef(
                current: metadata.shots,
                incoming: replacement
            )
        } else if matchMode == .replaceGuidedKey,
                  shot.isGuided,
                  let index = metadata.shots.firstIndex(where: {
                      $0.isGuided &&
                      $0.propertyID == shot.propertyID &&
                      $0.sessionID == shot.sessionID &&
                      (
                        $0.shotKey.caseInsensitiveCompare(shot.shotKey) == .orderedSame ||
                        (
                            $0.building.caseInsensitiveCompare(shot.building) == .orderedSame &&
                            CanonicalElevation.normalize($0.elevation) == CanonicalElevation.normalize(shot.elevation) &&
                            $0.detailType.caseInsensitiveCompare(shot.detailType) == .orderedSame &&
                            $0.angleIndex == shot.angleIndex
                        )
                      )
                  }) {
            let existing = metadata.shots[index]
            let replacement = ShotMetadata(
                shotID: existing.shotID,
                propertyID: shot.propertyID,
                sessionID: shot.sessionID,
                createdAt: existing.createdAt,
                capturedAtLocal: existing.capturedAtLocal ?? shot.capturedAtLocal,
                updatedAt: shot.updatedAt,
                building: shot.building,
                elevation: shot.elevation,
                detailType: shot.detailType,
                angleIndex: shot.angleIndex,
                trade: shot.trade,
                priority: shot.priority,
                shotKey: shot.shotKey,
                isGuided: shot.isGuided,
                isFlagged: shot.isFlagged,
                issueID: shot.issueID,
                issueStatus: shot.issueStatus,
                captureKind: shot.captureKind,
                firstCaptureKind: existing.firstCaptureKind ?? shot.firstCaptureKind,
                noteText: shot.noteText,
                noteCategory: shot.noteCategory,
                originalFilename: shot.originalFilename,
                originalRelativePath: shot.originalRelativePath,
                originalByteSize: shot.originalByteSize,
                storageBucket: shot.storageBucket,
                storagePath: shot.storagePath,
                checksumSHA256: shot.checksumSHA256,
                byteSize: shot.byteSize,
                uploadState: shot.uploadState,
                uploadAttempts: shot.uploadAttempts,
                lastUploadError: shot.lastUploadError,
                stampedFilename: shot.stampedFilename,
                stampedRelativePath: shot.stampedRelativePath,
                captureMode: shot.captureMode,
                lens: shot.lens,
                exifOrientation: shot.exifOrientation,
                orientation: shot.orientation,
                latitude: shot.latitude,
                longitude: shot.longitude,
                accuracyMeters: shot.accuracyMeters,
                imageWidth: shot.imageWidth,
                imageHeight: shot.imageHeight,
                lifecycleState: shot.lifecycleState,
                retiredAt: shot.retiredAt,
                retiredReason: shot.retiredReason,
                retiredByUserID: shot.retiredByUserID,
                supersededByShotID: shot.supersededByShotID,
                supersedesShotID: shot.supersedesShotID,
                replacementReason: shot.replacementReason,
                hiddenFromReports: shot.hiddenFromReports,
                hiddenFromGallery: shot.hiddenFromGallery,
                lifecycleUpdatedAt: shot.lifecycleUpdatedAt
            )
            metadata.shots.remove(at: index)
            metadata.shots = LocalConflictRules.applyAppendOnlyMediaRef(
                current: metadata.shots,
                incoming: replacement
            )
        } else {
            if matchMode == .replaceGuidedKey {
                print("Retake upsert fallback append: guided key match not found for session \(sessionID)")
            }
            metadata.shots = LocalConflictRules.applyAppendOnlyMediaRef(
                current: metadata.shots,
                incoming: shot
            )
        }

        try saveSessionMetadataAtomically(propertyID: propertyID, sessionID: sessionID, metadata: metadata)
    }

    func updateShotStorageMetadata(
        propertyID: UUID,
        sessionID: UUID,
        shotID: UUID,
        update: (inout ShotMetadata) -> Void
    ) throws {
        var metadata = try loadSessionMetadata(propertyID: propertyID, sessionID: sessionID)
        guard let index = metadata.shots.firstIndex(where: { $0.shotID == shotID }) else {
            return
        }
        update(&metadata.shots[index])
        try saveSessionMetadataAtomically(propertyID: propertyID, sessionID: sessionID, metadata: metadata)
    }

    @discardableResult
    func retireShot(
        propertyID: UUID,
        sessionID: UUID,
        shotID: UUID,
        reason: String,
        retiredByUserID: UUID? = nil,
        retiredAt: Date = Date()
    ) throws -> ShotMetadata {
        try validateSessionAllowsShotLifecycleChange(propertyID: propertyID, sessionID: sessionID)
        guard let normalizedReason = trimmedNonEmpty(reason) else {
            throw StoreError.shotLifecycleBlankReason
        }

        var metadata = try loadSessionMetadata(propertyID: propertyID, sessionID: sessionID)
        guard let index = metadata.shots.firstIndex(where: { $0.shotID == shotID }) else {
            throw StoreError.shotNotFound(shotID)
        }
        guard metadata.shots[index].lifecycleState == .active else {
            throw StoreError.shotLifecycleInvalidState(
                shotID,
                expected: .active,
                actual: metadata.shots[index].lifecycleState
            )
        }

        metadata.shots[index].lifecycleState = .retired
        metadata.shots[index].retiredAt = retiredAt
        metadata.shots[index].retiredReason = normalizedReason
        metadata.shots[index].retiredByUserID = retiredByUserID
        metadata.shots[index].lifecycleUpdatedAt = retiredAt
        metadata.shots[index].updatedAt = max(metadata.shots[index].updatedAt, retiredAt)

        let retired = metadata.shots[index]
        try saveSessionMetadataAtomically(propertyID: propertyID, sessionID: sessionID, metadata: metadata)
        return retired
    }

    @discardableResult
    func restoreRetiredShot(
        propertyID: UUID,
        sessionID: UUID,
        shotID: UUID,
        restoredAt: Date = Date()
    ) throws -> ShotMetadata {
        try validateSessionAllowsShotLifecycleChange(propertyID: propertyID, sessionID: sessionID)

        var metadata = try loadSessionMetadata(propertyID: propertyID, sessionID: sessionID)
        guard let index = metadata.shots.firstIndex(where: { $0.shotID == shotID }) else {
            throw StoreError.shotNotFound(shotID)
        }
        guard metadata.shots[index].lifecycleState == .retired else {
            throw StoreError.shotLifecycleInvalidState(
                shotID,
                expected: .retired,
                actual: metadata.shots[index].lifecycleState
            )
        }

        metadata.shots[index].lifecycleState = .active
        metadata.shots[index].lifecycleUpdatedAt = restoredAt
        metadata.shots[index].updatedAt = max(metadata.shots[index].updatedAt, restoredAt)

        let restored = metadata.shots[index]
        try saveSessionMetadataAtomically(propertyID: propertyID, sessionID: sessionID, metadata: metadata)
        return restored
    }

    private func validateSessionAllowsShotLifecycleChange(propertyID: UUID, sessionID: UUID) throws {
        let sessions = try fetchSessionsForCacheBuild(propertyID: propertyID)
        guard let session = sessions.first(where: { $0.id == sessionID && $0.deletedAt == nil }) else {
            throw StoreError.sessionNotFound(sessionID)
        }
        guard session.status == .draft && !session.isSealed else {
            throw StoreError.shotLifecycleBlockedForSealedSession(sessionID)
        }
    }

    @discardableResult
    func retireGuidedShot(
        propertyID: UUID,
        sessionID: UUID,
        guidedShotID: UUID,
        reason: String,
        retiredByUserID: UUID? = nil,
        retiredAt: Date = Date()
    ) throws -> GuidedShot {
        try validateSessionAllowsShotLifecycleChange(propertyID: propertyID, sessionID: sessionID)
        guard let normalizedReason = trimmedNonEmpty(reason) else {
            throw StoreError.shotLifecycleBlankReason
        }

        var guidedShots = try fetchGuidedShots(propertyID: propertyID)
        guard let guidedIndex = guidedShots.firstIndex(where: { $0.id == guidedShotID }) else {
            throw StoreError.guidedShotNotFound(guidedShotID)
        }
        guard guidedShots[guidedIndex].status != .retired && !guidedShots[guidedIndex].isRetired else {
            throw StoreError.guidedShotLifecycleInvalidState(guidedShotID)
        }

        var metadata = try loadSessionMetadata(propertyID: propertyID, sessionID: sessionID)
        if let shotID = guidedShots[guidedIndex].shot?.id,
           let shotIndex = metadata.shots.firstIndex(where: { $0.shotID == shotID }) {
            if metadata.shots[shotIndex].lifecycleState == .active {
                metadata.shots[shotIndex].lifecycleState = .retired
                metadata.shots[shotIndex].retiredAt = retiredAt
                metadata.shots[shotIndex].retiredReason = normalizedReason
                metadata.shots[shotIndex].retiredByUserID = retiredByUserID
                metadata.shots[shotIndex].lifecycleUpdatedAt = retiredAt
                metadata.shots[shotIndex].updatedAt = max(metadata.shots[shotIndex].updatedAt, retiredAt)
            } else if metadata.shots[shotIndex].lifecycleState != .retired {
                throw StoreError.shotLifecycleInvalidState(
                    shotID,
                    expected: .active,
                    actual: metadata.shots[shotIndex].lifecycleState
                )
            }
        }

        guidedShots[guidedIndex].status = .retired
        guidedShots[guidedIndex].isRetired = true
        guidedShots[guidedIndex].retiredAt = retiredAt
        guidedShots[guidedIndex].retiredInSessionID = sessionID
        guidedShots[guidedIndex].skipReason = nil
        guidedShots[guidedIndex].skipReasonNote = nil
        guidedShots[guidedIndex].skipSessionID = nil

        let normalizedGuided = LocalConflictRules.normalizeGuidedCompletionStates(guidedShots)
        try saveGuidedShots(normalizedGuided, propertyID: propertyID)
        metadata.guidedShots = normalizedGuided
        try saveSessionMetadataAtomically(propertyID: propertyID, sessionID: sessionID, metadata: metadata)
        return normalizedGuided.first(where: { $0.id == guidedShotID }) ?? guidedShots[guidedIndex]
    }

    @discardableResult
    func restoreRetiredGuidedShot(
        propertyID: UUID,
        sessionID: UUID,
        guidedShotID: UUID,
        restoredAt: Date = Date()
    ) throws -> GuidedShot {
        try validateSessionAllowsShotLifecycleChange(propertyID: propertyID, sessionID: sessionID)

        var guidedShots = try fetchGuidedShots(propertyID: propertyID)
        guard let guidedIndex = guidedShots.firstIndex(where: { $0.id == guidedShotID }) else {
            throw StoreError.guidedShotNotFound(guidedShotID)
        }
        guard guidedShots[guidedIndex].status == .retired || guidedShots[guidedIndex].isRetired else {
            throw StoreError.guidedShotLifecycleInvalidState(guidedShotID)
        }

        var metadata = try loadSessionMetadata(propertyID: propertyID, sessionID: sessionID)
        if let shotID = guidedShots[guidedIndex].shot?.id,
           let shotIndex = metadata.shots.firstIndex(where: { $0.shotID == shotID }) {
            if metadata.shots[shotIndex].lifecycleState == .retired {
                metadata.shots[shotIndex].lifecycleState = .active
                metadata.shots[shotIndex].lifecycleUpdatedAt = restoredAt
                metadata.shots[shotIndex].updatedAt = max(metadata.shots[shotIndex].updatedAt, restoredAt)
            } else if metadata.shots[shotIndex].lifecycleState != .active {
                throw StoreError.shotLifecycleInvalidState(
                    shotID,
                    expected: .retired,
                    actual: metadata.shots[shotIndex].lifecycleState
                )
            }
        }

        guidedShots[guidedIndex].status = .active
        guidedShots[guidedIndex].isRetired = false
        if guidedShots[guidedIndex].shot != nil {
            guidedShots[guidedIndex].isCompleted = true
        }

        let normalizedGuided = LocalConflictRules.normalizeGuidedCompletionStates(guidedShots)
        try saveGuidedShots(normalizedGuided, propertyID: propertyID)
        metadata.guidedShots = normalizedGuided
        try saveSessionMetadataAtomically(propertyID: propertyID, sessionID: sessionID, metadata: metadata)
        return normalizedGuided.first(where: { $0.id == guidedShotID }) ?? guidedShots[guidedIndex]
    }

    func removeShotMetadata(
        propertyID: UUID,
        sessionID: UUID,
        originalFileIdentifiers: [String]
    ) throws {
        try performFileIOSync {
            guard !originalFileIdentifiers.isEmpty else { return }
            var metadata = try readOrRecoverSessionMetadata(propertyID: propertyID, sessionID: sessionID)
            let targets = Set(originalFileIdentifiers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
            guard !targets.isEmpty else { return }
            metadata.shots.removeAll { shot in
                let original = shot.originalFilename.trimmingCharacters(in: .whitespacesAndNewlines)
                let stem = URL(fileURLWithPath: original).deletingPathExtension().lastPathComponent
                return targets.contains(original)
                    || targets.contains(stem)
                    || targets.contains("/\(stem).jpg")
                    || targets.contains("/\(stem).heic")
            }
            try writeSessionMetadata(metadata)
            NotificationCenter.default.post(name: .scoutPersistentDataDidChange, object: nil)
        }
    }

    func fetchShotMetadata(propertyID: UUID, sessionID: UUID) throws -> [ShotMetadata] {
        let metadata = try readOrRecoverSessionMetadata(propertyID: propertyID, sessionID: sessionID)
        return metadata.shots
    }
    
    func latestDraftSession(propertyID: UUID) throws -> Session? {
        let sessions = try fetchSessions(propertyID: propertyID)
        return sessions
            .filter { $0.deletedAt == nil && $0.status == .draft }
            .sorted { $0.startedAt > $1.startedAt }
            .first
    }

    func deleteSession(id: UUID, propertyID: UUID) throws {
        try performFileIOSync {
            try ensurePropertyExists(propertyID)
            var sessions = try readSessions(propertyID: propertyID)
            sessions.removeAll { $0.id == id }
            try writeSessions(sessions, propertyID: propertyID)
            let metadataFolder = sessionMetadataFolderURL(propertyID: propertyID, sessionID: id)
            if fileManager.fileExists(atPath: metadataFolder.path) {
                try? fileManager.removeItem(at: metadataFolder)
            }
            NotificationCenter.default.post(name: .scoutPersistentDataDidChange, object: nil)
        }
    }

    func deleteSessionCascade(id: UUID, propertyID: UUID) throws {
        try performFileIOSync {
            try ensurePropertyExists(propertyID)
            let sessions = try readSessions(propertyID: propertyID)
            guard let target = sessions.first(where: { $0.id == id }) else {
                throw StoreError.sessionNotFound(id)
            }

            let start = target.startedAt
            let end = target.endedAt ?? Date.distantFuture

            var observations = try readObservations(propertyID: propertyID)
            let sessionMatched = observations.filter { $0.sessionID == target.id }
            let timeMatched = observations.filter { $0.sessionID == nil && $0.createdAt >= start && $0.createdAt <= end }
            let matchedObservationIDs = Set((sessionMatched + timeMatched).map(\.id))
            let matchedObservations = observations.filter { matchedObservationIDs.contains($0.id) }
            let matchedShotIDs = Set(matchedObservations.flatMap { obs in
                var ids = obs.shots.map(\.id)
                if let linked = obs.linkedShotID {
                    ids.append(linked)
                }
                return ids
            })

            let observationGuidedRefs = matchedObservations.flatMap { $0.guidedShots.compactMap(\.referenceImagePath) }
            try cleanupReferenceFiles(paths: observationGuidedRefs)
            observations.removeAll { matchedObservationIDs.contains($0.id) }
            try writeObservations(observations, propertyID: propertyID)

            var guided = try readGuidedShots(propertyID: propertyID)
            let guidedToDelete = guided.filter { shot in
                if let shotID = shot.shot?.id, matchedShotIDs.contains(shotID) {
                    return true
                }
                if let capturedAt = shot.shot?.capturedAt, capturedAt >= start && capturedAt <= end {
                    return true
                }
                return false
            }
            try cleanupReferenceFilesForGuidedShots(guidedToDelete)
            guided.removeAll { item in guidedToDelete.contains(where: { $0.id == item.id }) }
            try writeGuidedShots(guided, propertyID: propertyID)

            var updatedSessions = sessions
            updatedSessions.removeAll { $0.id == id }
            try writeSessions(updatedSessions, propertyID: propertyID)
            let metadataFolder = sessionMetadataFolderURL(propertyID: propertyID, sessionID: id)
            if fileManager.fileExists(atPath: metadataFolder.path) {
                try? fileManager.removeItem(at: metadataFolder)
            }
            NotificationCenter.default.post(name: .scoutPersistentDataDidChange, object: nil)
        }
    }

    func ensureSessionFolders(propertyID: UUID, sessionID: UUID) throws {
        let propertyFolder = propertyFolderURL(propertyID: propertyID)
        if !fileManager.fileExists(atPath: propertyFolder.path) {
            try fileManager.createDirectory(at: propertyFolder, withIntermediateDirectories: true)
        }

        let sessionsFolder = sessionsFolderURL(propertyID: propertyID)
        if !fileManager.fileExists(atPath: sessionsFolder.path) {
            try fileManager.createDirectory(at: sessionsFolder, withIntermediateDirectories: true)
        }

        let sessionFolder = sessionFolderURL(propertyID: propertyID, sessionID: sessionID)
        if !fileManager.fileExists(atPath: sessionFolder.path) {
            try fileManager.createDirectory(at: sessionFolder, withIntermediateDirectories: true)
        }

        let originals = originalsFolderURL(propertyID: propertyID, sessionID: sessionID)
        if !fileManager.fileExists(atPath: originals.path) {
            try fileManager.createDirectory(at: originals, withIntermediateDirectories: true)
        }

        let stamped = stampedFolderURL(propertyID: propertyID, sessionID: sessionID)
        if !fileManager.fileExists(atPath: stamped.path) {
            try fileManager.createDirectory(at: stamped, withIntermediateDirectories: true)
        }
    }

    func ensureSessionFileStorage(propertyID: UUID, sessionID: UUID) throws {
        try ensureSessionFolders(propertyID: propertyID, sessionID: sessionID)
    }

    func rootURL() -> URL {
        scoutRootURL
    }

    func storageRootURL() -> URL {
        activeRootURL
    }

    func propertiesLedgerFingerprint() -> String {
        (try? performFileIOSync {
            let fileURL = propertiesURL
            if !fileManager.fileExists(atPath: fileURL.path) {
                _ = ensureUbiquitousItemAvailable(at: fileURL, timeout: 0.8)
            }
            guard fileManager.fileExists(atPath: fileURL.path) else {
                return "missing"
            }
            let attrs = (try? fileManager.attributesOfItem(atPath: fileURL.path)) ?? [:]
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? -1
            let modified = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(size)|\(modified)"
        }) ?? "missing"
    }

    func propertyFolderURL(propertyID: UUID) -> URL {
        propertyFoldersURL.appendingPathComponent(propertyID.uuidString, isDirectory: true)
    }

    func sessionsFolderURL(propertyID: UUID) -> URL {
        propertyFolderURL(propertyID: propertyID)
            .appendingPathComponent("Sessions", isDirectory: true)
    }

    func sessionFolderURL(propertyID: UUID, sessionID: UUID) -> URL {
        sessionsFolderURL(propertyID: propertyID)
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
    }

    func originalsFolderURL(propertyID: UUID, sessionID: UUID) -> URL {
        sessionFolderURL(propertyID: propertyID, sessionID: sessionID)
            .appendingPathComponent("Originals", isDirectory: true)
    }

    func stampedFolderURL(propertyID: UUID, sessionID: UUID) -> URL {
        sessionFolderURL(propertyID: propertyID, sessionID: sessionID)
            .appendingPathComponent("Stamped", isDirectory: true)
    }

    func guidedReferencesDirectoryURL() -> URL {
        scoutRootURL.appendingPathComponent("guided-references", isDirectory: true)
    }

    func legacyMigrationPreflightDirectoryURL() -> URL {
        scoutRootURL
            .appendingPathComponent("migrations", isDirectory: true)
            .appendingPathComponent("supabase-legacy-v1", isDirectory: true)
    }

    func legacyMigrationLedgerURL() -> URL {
        legacyMigrationPreflightDirectoryURL()
            .appendingPathComponent("ledger.json", isDirectory: false)
    }

    func legacyMigrationSummaryReportURL() -> URL {
        legacyMigrationPreflightDirectoryURL()
            .appendingPathComponent("summary-report.txt", isDirectory: false)
    }

    func loadLegacyMigrationLedger() throws -> LegacyMigrationPreflightLedger {
        try performFileIOSync {
            let ledgerURL = legacyMigrationLedgerURL()
            let data = try Data(contentsOf: ledgerURL)
            return try decoder.decode(LegacyMigrationPreflightLedger.self, from: data)
        }
    }

    func writeLegacyMigrationLedger(_ ledger: LegacyMigrationPreflightLedger) throws {
        try performFileIOSync {
            let directoryURL = legacyMigrationPreflightDirectoryURL()
            if !fileManager.fileExists(atPath: directoryURL.path) {
                try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            }
            let ledgerURL = legacyMigrationLedgerURL()
            let ledgerData = try encoder.encode(ledger)
            try atomicWriteFileData(ledgerData, to: ledgerURL)
        }
    }

    @discardableResult
    func writeLegacyMigrationPreflightArtifacts(
        ledger: LegacyMigrationPreflightLedger,
        reportText: String
    ) throws -> LegacyMigrationPreflightArtifacts {
        try performFileIOSync {
            let directoryURL = legacyMigrationPreflightDirectoryURL()
            if !fileManager.fileExists(atPath: directoryURL.path) {
                try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            }

            let ledgerURL = legacyMigrationLedgerURL()
            let reportURL = legacyMigrationSummaryReportURL()
            print("[LegacyMigrationPreflight] directoryURL.path=\(directoryURL.path)")
            print("[LegacyMigrationPreflight] ledgerURL.path=\(ledgerURL.path)")
            print("[LegacyMigrationPreflight] reportURL.path=\(reportURL.path)")
            let ledgerData = try encoder.encode(ledger)
            let reportData = Data(reportText.utf8)
            try atomicWriteFileData(ledgerData, to: ledgerURL)
            try atomicWriteFileData(reportData, to: reportURL)

            return LegacyMigrationPreflightArtifacts(
                directoryURL: directoryURL,
                ledgerURL: ledgerURL,
                reportURL: reportURL
            )
        }
    }

    private func atomicWriteFileData(_ data: Data, to destinationURL: URL) throws {
        let directoryURL = destinationURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directoryURL.path) {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }

        let tempURL = directoryURL.appendingPathComponent("\(destinationURL.lastPathComponent).tmp-\(UUID().uuidString)")
        try data.write(to: tempURL, options: .atomic)

        do {
            if fileManager.fileExists(atPath: destinationURL.path) {
                _ = try fileManager.replaceItemAt(destinationURL, withItemAt: tempURL, backupItemName: nil, options: [.usingNewMetadataOnly])
            } else {
                try fileManager.moveItem(at: tempURL, to: destinationURL)
            }
        } catch {
            if fileManager.fileExists(atPath: tempURL.path) {
                try? fileManager.removeItem(at: tempURL)
            }
            throw error
        }
    }

    func sessionJSONURL(propertyID: UUID, sessionID: UUID) -> URL {
        sessionFolderURL(propertyID: propertyID, sessionID: sessionID)
            .appendingPathComponent("session.json")
    }

    func resolveSessionRelativeFileURL(propertyID: UUID, sessionID: UUID, relativePath: String) -> URL? {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let preferredURL = sessionFolderURL(propertyID: propertyID, sessionID: sessionID)
            .appendingPathComponent(trimmed, isDirectory: false)
        if fileManager.fileExists(atPath: preferredURL.path) {
            return preferredURL
        }

        for scoutRoot in StorageRoot.scoutRootCandidates() {
            let candidateURL = scoutRoot
                .appendingPathComponent("Properties", isDirectory: true)
                .appendingPathComponent(propertyID.uuidString, isDirectory: true)
                .appendingPathComponent("Sessions", isDirectory: true)
                .appendingPathComponent(sessionID.uuidString, isDirectory: true)
                .appendingPathComponent(trimmed, isDirectory: false)
            if fileManager.fileExists(atPath: candidateURL.path) {
                return candidateURL
            }
        }

        return nil
    }

    // Backward-compatible wrappers used by existing call sites.
    func originalsDirectoryURL(propertyID: UUID, sessionID: UUID) -> URL {
        originalsFolderURL(propertyID: propertyID, sessionID: sessionID)
    }

    func stampedDirectoryURL(propertyID: UUID, sessionID: UUID) -> URL {
        stampedFolderURL(propertyID: propertyID, sessionID: sessionID)
    }

    @discardableResult
    func offloadSessionMediaAssets(propertyID: UUID, sessionID: UUID) -> Int {
        (try? performFileIOSync {
            let originals = originalsFolderURL(propertyID: propertyID, sessionID: sessionID)
            let stamped = stampedFolderURL(propertyID: propertyID, sessionID: sessionID)
            var offloaded = 0
            offloaded += offloadUbiquitousFiles(in: originals)
            offloaded += offloadUbiquitousFiles(in: stamped)
            return offloaded
        }) ?? 0
    }

    @discardableResult
    func createSessionArchiveSnapshot(session: Session, trigger: String) throws -> URL? {
        try performFileIOSync {
            guard session.status == .completed, session.isSealed else { return nil }

            let artifacts = try validatedSessionExportArtifacts(for: session)
            let createdAt = Date()
            let stamp = archiveTimestampString(createdAt)
            let triggerSlug = sanitizedArchivePathSegment(trigger)
            let deliveryStateSlug = session.firstDeliveredAt == nil ? "sealed" : "delivered"

            let archivesRoot = activeRootURL
                .appendingPathComponent("Archives", isDirectory: true)
                .appendingPathComponent("Sessions", isDirectory: true)
                .appendingPathComponent(session.propertyID.uuidString, isDirectory: true)
                .appendingPathComponent(session.id.uuidString, isDirectory: true)
            try fileManager.createDirectory(at: archivesRoot, withIntermediateDirectories: true)

            let snapshotFolderName = "\(stamp)-\(deliveryStateSlug)-\(triggerSlug)"
            let snapshotRoot = archivesRoot.appendingPathComponent(snapshotFolderName, isDirectory: true)
            if fileManager.fileExists(atPath: snapshotRoot.path) {
                try fileManager.removeItem(at: snapshotRoot)
            }
            try fileManager.createDirectory(at: snapshotRoot, withIntermediateDirectories: true)

            let payloadRoot = snapshotRoot.appendingPathComponent("Payload", isDirectory: true)
            let originalsRoot = payloadRoot.appendingPathComponent("Originals", isDirectory: true)
            let csvRoot = payloadRoot.appendingPathComponent("CSV", isDirectory: true)
            try fileManager.createDirectory(at: payloadRoot, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: originalsRoot, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: csvRoot, withIntermediateDirectories: true)

            try artifacts.sessionData.write(
                to: payloadRoot.appendingPathComponent("session.json", isDirectory: false),
                options: .atomic
            )
            try artifacts.validationData.write(
                to: payloadRoot.appendingPathComponent("validation.txt", isDirectory: false),
                options: .atomic
            )

            for csv in exportCSVFiles(for: artifacts.metadata) {
                try csv.data.write(
                    to: csvRoot.appendingPathComponent(csv.filename, isDirectory: false),
                    options: .atomic
                )
            }

            for original in artifacts.originalFiles {
                guard ensureUbiquitousItemAvailable(at: original.sourceURL, timeout: 20) else {
                    throw NSError(
                        domain: "LocalStore.SessionArchive",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Missing source file during archive snapshot: \(original.filename)"]
                    )
                }
                let destination = originalsRoot.appendingPathComponent(original.filename, isDirectory: false)
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.copyItem(at: original.sourceURL, to: destination)
            }

            let fileRecords = try archiveFileRecords(in: snapshotRoot)
            let totalBytes = fileRecords.reduce(Int64(0)) { $0 + $1.size }
            let manifest = SessionArchiveManifest(
                schemaVersion: 1,
                createdAt: createdAt,
                trigger: trigger,
                propertyID: session.propertyID,
                sessionID: session.id,
                clientNameAtCapture: artifacts.metadata.primaryContactNameAtCapture,
                orgNameAtCapture: artifacts.metadata.orgNameAtCapture,
                propertyNameAtCapture: artifacts.metadata.propertyNameAtCapture,
                propertyAddressAtCapture: artifacts.metadata.propertyAddressAtCapture,
                sessionStatus: session.status.rawValue,
                isSealed: session.isSealed,
                firstDeliveredAt: session.firstDeliveredAt,
                reExportExpiresAt: session.reExportExpiresAt,
                exportedAt: session.exportedAt,
                fileCount: fileRecords.count,
                totalBytes: totalBytes,
                files: fileRecords
            )

            let manifestData = try encoder.encode(manifest)
            let manifestURL = snapshotRoot.appendingPathComponent("manifest.json", isDirectory: false)
            try manifestData.write(to: manifestURL, options: .atomic)
            try verifySessionArchiveSnapshot(at: snapshotRoot, manifest: manifest)

            print(
                "[SessionArchive] result=success " +
                "propertyID=\(session.propertyID.uuidString) " +
                "sessionID=\(session.id.uuidString) " +
                "trigger=\(trigger) " +
                "snapshot=\(snapshotFolderName) " +
                "files=\(manifest.fileCount) " +
                "bytes=\(manifest.totalBytes)"
            )
            return snapshotRoot
        }
    }

    func fetchSessionArchiveSummaries() throws -> [SessionArchiveSummary] {
        try performFileIOSync {
            let archivesRoot = activeRootURL
                .appendingPathComponent("Archives", isDirectory: true)
                .appendingPathComponent("Sessions", isDirectory: true)
            guard fileManager.fileExists(atPath: archivesRoot.path) else { return [] }

            var summaries: [SessionArchiveSummary] = []
            func composedAddress(from json: [String: Any]) -> String? {
                if let direct = trimmedNonEmpty(json["propertyAddressAtCapture"] as? String) {
                    return direct
                }
                let street = trimmedNonEmpty(json["propertyStreetAtCapture"] as? String)
                let city = trimmedNonEmpty(json["propertyCityAtCapture"] as? String)
                let state = trimmedNonEmpty(json["propertyStateAtCapture"] as? String)
                let zip = trimmedNonEmpty(json["propertyZipAtCapture"] as? String)
                let parts = [street, city, state, zip].compactMap { $0 }
                guard !parts.isEmpty else { return nil }
                return parts.joined(separator: ", ")
            }
            func composedClientName(from json: [String: Any]) -> String? {
                trimmedNonEmpty(json["primaryContactNameAtCapture"] as? String)
                    ?? trimmedNonEmpty(json["primaryContactName"] as? String)
                    ?? trimmedNonEmpty(json["clientName"] as? String)
            }
            let propertyFolders = try fileManager.contentsOfDirectory(
                at: archivesRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ).sorted { $0.lastPathComponent < $1.lastPathComponent }

            for propertyFolder in propertyFolders {
                let propertyValues = try propertyFolder.resourceValues(forKeys: [.isDirectoryKey])
                guard propertyValues.isDirectory == true else { continue }
                guard let propertyID = UUID(uuidString: propertyFolder.lastPathComponent) else { continue }

                let sessionFolders = try fileManager.contentsOfDirectory(
                    at: propertyFolder,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                ).sorted { $0.lastPathComponent < $1.lastPathComponent }

                for sessionFolder in sessionFolders {
                    let sessionValues = try sessionFolder.resourceValues(forKeys: [.isDirectoryKey])
                    guard sessionValues.isDirectory == true else { continue }
                    guard let sessionID = UUID(uuidString: sessionFolder.lastPathComponent) else { continue }

                    let snapshots = try fileManager.contentsOfDirectory(
                        at: sessionFolder,
                        includingPropertiesForKeys: [.isDirectoryKey],
                        options: [.skipsHiddenFiles]
                    ).sorted { $0.lastPathComponent < $1.lastPathComponent }

                    for snapshot in snapshots {
                        let snapshotValues = try snapshot.resourceValues(forKeys: [.isDirectoryKey])
                        guard snapshotValues.isDirectory == true else { continue }
                        let manifestURL = snapshot.appendingPathComponent("manifest.json", isDirectory: false)
                        guard fileManager.fileExists(atPath: manifestURL.path) else { continue }
                        let manifestData = try Data(contentsOf: manifestURL)
                        let manifest = try decoder.decode(SessionArchiveManifest.self, from: manifestData)
                        var clientNameAtCapture = trimmedNonEmpty(manifest.clientNameAtCapture)
                        var orgNameAtCapture = trimmedNonEmpty(manifest.orgNameAtCapture)
                        var propertyNameAtCapture = trimmedNonEmpty(manifest.propertyNameAtCapture)
                        var propertyAddressAtCapture = trimmedNonEmpty(manifest.propertyAddressAtCapture)

                        if clientNameAtCapture == nil || orgNameAtCapture == nil || propertyNameAtCapture == nil || propertyAddressAtCapture == nil {
                            let payloadSessionURL = snapshot
                                .appendingPathComponent("Payload", isDirectory: true)
                                .appendingPathComponent("session.json", isDirectory: false)
                            if fileManager.fileExists(atPath: payloadSessionURL.path),
                               let payloadData = try? Data(contentsOf: payloadSessionURL),
                               let payloadObject = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] {
                                if clientNameAtCapture == nil {
                                    clientNameAtCapture = composedClientName(from: payloadObject)
                                }
                                if propertyNameAtCapture == nil {
                                    propertyNameAtCapture = trimmedNonEmpty(payloadObject["propertyNameAtCapture"] as? String)
                                        ?? trimmedNonEmpty(payloadObject["propertyNameAtExport"] as? String)
                                }
                                if orgNameAtCapture == nil {
                                    orgNameAtCapture = trimmedNonEmpty(payloadObject["orgNameAtCapture"] as? String)
                                }
                                if propertyAddressAtCapture == nil {
                                    propertyAddressAtCapture = composedAddress(from: payloadObject)
                                }
                            }
                        }
                        let snapshotName = snapshot.lastPathComponent
                        summaries.append(
                            SessionArchiveSummary(
                                id: "\(propertyID.uuidString)|\(sessionID.uuidString)|\(snapshotName)",
                                propertyID: propertyID,
                                sessionID: sessionID,
                                snapshotName: snapshotName,
                                createdAt: manifest.createdAt,
                                trigger: manifest.trigger,
                                clientNameAtCapture: clientNameAtCapture,
                                orgNameAtCapture: orgNameAtCapture,
                                propertyNameAtCapture: propertyNameAtCapture,
                                propertyAddressAtCapture: propertyAddressAtCapture,
                                isSealedCheckpoint: true,
                                isDeliveredCheckpoint: manifest.firstDeliveredAt != nil,
                                fileCount: manifest.fileCount,
                                totalBytes: manifest.totalBytes
                            )
                        )
                    }
                }
            }

            var bestBySession: [String: SessionArchiveSummary] = [:]
            func mergedSummary(preferred: SessionArchiveSummary, fallback: SessionArchiveSummary) -> SessionArchiveSummary {
                SessionArchiveSummary(
                    id: preferred.id,
                    propertyID: preferred.propertyID,
                    sessionID: preferred.sessionID,
                    snapshotName: preferred.snapshotName,
                    createdAt: preferred.createdAt,
                    trigger: preferred.trigger,
                    clientNameAtCapture: preferred.clientNameAtCapture ?? fallback.clientNameAtCapture,
                    orgNameAtCapture: preferred.orgNameAtCapture ?? fallback.orgNameAtCapture,
                    propertyNameAtCapture: preferred.propertyNameAtCapture ?? fallback.propertyNameAtCapture,
                    propertyAddressAtCapture: preferred.propertyAddressAtCapture ?? fallback.propertyAddressAtCapture,
                    isSealedCheckpoint: preferred.isSealedCheckpoint,
                    isDeliveredCheckpoint: preferred.isDeliveredCheckpoint,
                    fileCount: preferred.fileCount,
                    totalBytes: preferred.totalBytes
                )
            }
            for summary in summaries {
                let key = "\(summary.propertyID.uuidString)|\(summary.sessionID.uuidString)"
                if let existing = bestBySession[key] {
                    let existingRank = existing.isDeliveredCheckpoint ? 2 : 1
                    let incomingRank = summary.isDeliveredCheckpoint ? 2 : 1
                    if incomingRank > existingRank {
                        bestBySession[key] = mergedSummary(preferred: summary, fallback: existing)
                    } else if incomingRank == existingRank, summary.createdAt > existing.createdAt {
                        bestBySession[key] = mergedSummary(preferred: summary, fallback: existing)
                    } else {
                        bestBySession[key] = mergedSummary(preferred: existing, fallback: summary)
                    }
                } else {
                    bestBySession[key] = summary
                }
            }

            return Array(bestBySession.values).sorted { lhs, rhs in
                if lhs.createdAt == rhs.createdAt {
                    return lhs.id > rhs.id
                }
                return lhs.createdAt > rhs.createdAt
            }
        }
    }

    func deleteSessionArchiveSnapshot(
        propertyID: UUID,
        sessionID: UUID,
        snapshotName: String
    ) throws {
        try performFileIOSync {
            let sessionRoot = activeRootURL
                .appendingPathComponent("Archives", isDirectory: true)
                .appendingPathComponent("Sessions", isDirectory: true)
                .appendingPathComponent(propertyID.uuidString, isDirectory: true)
                .appendingPathComponent(sessionID.uuidString, isDirectory: true)
            let snapshotRoot = sessionRoot.appendingPathComponent(snapshotName, isDirectory: true)

            guard fileManager.fileExists(atPath: snapshotRoot.path) else { return }
            try fileManager.removeItem(at: snapshotRoot)

            if let remainingSnapshots = try? fileManager.contentsOfDirectory(
                at: sessionRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ), remainingSnapshots.isEmpty {
                try? fileManager.removeItem(at: sessionRoot)
                let propertyRoot = sessionRoot.deletingLastPathComponent()
                if let remainingSessions = try? fileManager.contentsOfDirectory(
                    at: propertyRoot,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                ), remainingSessions.isEmpty {
                    try? fileManager.removeItem(at: propertyRoot)
                }
            }

            print(
                "[SessionArchiveDelete] result=success " +
                "propertyID=\(propertyID.uuidString) " +
                "sessionID=\(sessionID.uuidString) " +
                "snapshot=\(snapshotName)"
            )
        }
    }

    func missingOriginalArchiveProvenance(
        propertyID: UUID,
        sessionID: UUID,
        originalFilename: String?,
        originalRelativePath: String?
    ) -> MissingOriginalArchiveProvenance {
        (try? performFileIOSync {
            let sessionRoot = activeRootURL
                .appendingPathComponent("Archives", isDirectory: true)
                .appendingPathComponent("Sessions", isDirectory: true)
                .appendingPathComponent(propertyID.uuidString, isDirectory: true)
                .appendingPathComponent(sessionID.uuidString, isDirectory: true)
            guard fileManager.fileExists(atPath: sessionRoot.path) else {
                return MissingOriginalArchiveProvenance(
                    snapshotExists: false,
                    snapshotCount: 0,
                    latestSnapshotDate: nil,
                    payloadOriginalsCandidateHit: false
                )
            }

            let snapshots = (try? fileManager.contentsOfDirectory(
                at: sessionRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            let snapshotFolders = snapshots.filter { url in
                (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var latestDate: Date?
            var payloadHit = false
            let candidateNames = [
                originalFilename,
                originalRelativePath.map { URL(fileURLWithPath: $0).lastPathComponent }
            ]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            for snapshot in snapshotFolders {
                let manifestURL = snapshot.appendingPathComponent("manifest.json", isDirectory: false)
                if fileManager.fileExists(atPath: manifestURL.path),
                   let data = try? Data(contentsOf: manifestURL),
                   let manifest = try? decoder.decode(SessionArchiveManifest.self, from: data) {
                    latestDate = max(latestDate ?? manifest.createdAt, manifest.createdAt)
                    for name in candidateNames {
                        let expected = "Payload/Originals/\(name)"
                        if manifest.files.contains(where: { $0.relativePath == expected }) {
                            payloadHit = true
                        }
                    }
                }
                if !payloadHit {
                    let originalsRoot = snapshot
                        .appendingPathComponent("Payload", isDirectory: true)
                        .appendingPathComponent("Originals", isDirectory: true)
                    for name in candidateNames {
                        if fileManager.fileExists(atPath: originalsRoot.appendingPathComponent(name).path) {
                            payloadHit = true
                            break
                        }
                    }
                }
            }

            return MissingOriginalArchiveProvenance(
                snapshotExists: !snapshotFolders.isEmpty,
                snapshotCount: snapshotFolders.count,
                latestSnapshotDate: latestDate,
                payloadOriginalsCandidateHit: payloadHit
            )
        }) ?? MissingOriginalArchiveProvenance(
            snapshotExists: false,
            snapshotCount: 0,
            latestSnapshotDate: nil,
            payloadOriginalsCandidateHit: false
        )
    }

    func restoreSessionArchiveSnapshot(
        propertyID: UUID,
        sessionID: UUID,
        snapshotName: String
    ) throws -> Session {
        try performFileIOSync {
            let snapshotRoot = activeRootURL
                .appendingPathComponent("Archives", isDirectory: true)
                .appendingPathComponent("Sessions", isDirectory: true)
                .appendingPathComponent(propertyID.uuidString, isDirectory: true)
                .appendingPathComponent(sessionID.uuidString, isDirectory: true)
                .appendingPathComponent(snapshotName, isDirectory: true)

            guard fileManager.fileExists(atPath: snapshotRoot.path) else {
                throw NSError(
                    domain: "LocalStore.SessionArchiveRestore",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Snapshot not found: \(snapshotName)"]
                )
            }

            let manifestURL = snapshotRoot.appendingPathComponent("manifest.json", isDirectory: false)
            guard fileManager.fileExists(atPath: manifestURL.path) else {
                throw NSError(
                    domain: "LocalStore.SessionArchiveRestore",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Snapshot manifest is missing."]
                )
            }
            let manifestData = try Data(contentsOf: manifestURL)
            let manifest = try decoder.decode(SessionArchiveManifest.self, from: manifestData)
            try verifySessionArchiveSnapshot(at: snapshotRoot, manifest: manifest)

            let sessionJSONURL = snapshotRoot
                .appendingPathComponent("Payload", isDirectory: true)
                .appendingPathComponent("session.json", isDirectory: false)
            guard fileManager.fileExists(atPath: sessionJSONURL.path) else {
                throw NSError(
                    domain: "LocalStore.SessionArchiveRestore",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Snapshot payload is missing session.json."]
                )
            }

            var metadata = try decoder.decode(SessionMetadata.self, from: Data(contentsOf: sessionJSONURL))
            metadata.propertyID = propertyID
            metadata.sessionID = sessionID

            if (try? fetchProperties().contains(where: { $0.id == propertyID })) != true {
                let placeholder = Property(
                    id: propertyID,
                    orgId: metadata.orgID,
                    folderId: metadata.folderIDAtCapture,
                    clientName: metadata.primaryContactNameAtCapture,
                    clientPhone: metadata.propertyPhoneAtCapture,
                    clientEmail: metadata.primaryContactEmailAtCapture,
                    name: metadata.propertyNameAtCapture ?? "Restored Property",
                    address: metadata.propertyAddressAtCapture,
                    street: metadata.propertyStreetAtCapture,
                    city: metadata.propertyCityAtCapture,
                    state: metadata.propertyStateAtCapture,
                    zip: metadata.propertyZipAtCapture
                )
                _ = try createProperty(placeholder)
            }

            let restoredSessionFolder = sessionFolderURL(propertyID: propertyID, sessionID: sessionID)
            if fileManager.fileExists(atPath: restoredSessionFolder.path) {
                try fileManager.removeItem(at: restoredSessionFolder)
            }
            try ensureSessionFileStorage(propertyID: propertyID, sessionID: sessionID)
            let restoredOriginals = restoredSessionFolder.appendingPathComponent("Originals", isDirectory: true)
            if fileManager.fileExists(atPath: restoredOriginals.path) == false {
                try fileManager.createDirectory(at: restoredOriginals, withIntermediateDirectories: true)
            }

            let payloadOriginals = snapshotRoot
                .appendingPathComponent("Payload", isDirectory: true)
                .appendingPathComponent("Originals", isDirectory: true)
            if fileManager.fileExists(atPath: payloadOriginals.path) {
                let originalFiles = try fileManager.contentsOfDirectory(
                    at: payloadOriginals,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )
                for source in originalFiles {
                    let values = try source.resourceValues(forKeys: [.isDirectoryKey])
                    guard values.isDirectory != true else { continue }
                    let destination = restoredOriginals.appendingPathComponent(source.lastPathComponent, isDirectory: false)
                    if fileManager.fileExists(atPath: destination.path) {
                        try fileManager.removeItem(at: destination)
                    }
                    try fileManager.copyItem(at: source, to: destination)
                }
            }

            try saveSessionMetadataAtomically(propertyID: propertyID, sessionID: sessionID, metadata: metadata)
            try syncPropertyStoresFromRestoredSessionMetadata(
                metadata: metadata,
                propertyID: propertyID,
                sessionID: sessionID
            )

            let restoredSession = Session(
                id: sessionID,
                propertyID: propertyID,
                startedAt: metadata.startedAt,
                status: metadata.status,
                endedAt: metadata.endedAt,
                exportedAt: metadata.exportedAt,
                isSealed: metadata.isSealed,
                firstDeliveredAt: metadata.firstDeliveredAt,
                reExportExpiresAt: metadata.reExportExpiresAt
            )
            _ = try upsertSession(restoredSession)

            print(
                "[SessionRestore] result=success " +
                "propertyID=\(propertyID.uuidString) " +
                "sessionID=\(sessionID.uuidString) " +
                "snapshot=\(snapshotName)"
            )
            return restoredSession
        }
    }

    private func syncPropertyStoresFromRestoredSessionMetadata(
        metadata: SessionMetadata,
        propertyID: UUID,
        sessionID: UUID
    ) throws {
        // Authoritative restore: overwrite property-level guided store with snapshot state.
        let normalizedGuided = metadata.guidedShots.map { guided -> GuidedShot in
            var updated = guided
            updated.angleIndex = max(1, guided.angleIndex ?? 1)
            return updated
        }
        try writeGuidedShots(normalizedGuided, propertyID: propertyID)

        let sessionFolder = sessionFolderURL(propertyID: propertyID, sessionID: sessionID)
        let flaggedShotsByIssueID = Dictionary(grouping: metadata.shots.filter { $0.isFlagged && $0.issueID != nil }) { shot in
            shot.issueID!
        }

        // Authoritative restore: property-level observation store is replaced by snapshot-derived issues.
        var mergedByID: [UUID: Observation] = [:]

        func shotPath(for shot: ShotMetadata) -> String {
            let relative = shot.originalRelativePath.trimmingCharacters(in: .whitespacesAndNewlines)
            if relative.isEmpty {
                return sessionFolder
                    .appendingPathComponent("Originals", isDirectory: true)
                    .appendingPathComponent(shot.originalFilename, isDirectory: false)
                    .path
            }
            return sessionFolder.appendingPathComponent(relative, isDirectory: false).path
        }

        func buildObservation(issue: IssueMetadata, fallbackSessionID: UUID) -> Observation {
            let shots = (flaggedShotsByIssueID[issue.issueID] ?? [])
                .sorted { $0.createdAt < $1.createdAt }
                .map { shot in
                    Shot(
                        id: shot.shotID,
                        capturedAt: shot.createdAt,
                        imageLocalIdentifier: shotPath(for: shot),
                        note: shot.noteText
                    )
                }

            let linkedShot = shots.last?.id
            let latestMetaShot = (flaggedShotsByIssueID[issue.issueID] ?? []).sorted { $0.updatedAt > $1.updatedAt }.first
            let status: Observation.Status = issue.issueStatus.lowercased() == "resolved" ? .resolved : .active
            let createdAt = issue.firstSeenAt ?? issue.lastSeenAt ?? metadata.startedAt
            let updatedAt = issue.lastSeenAt ?? issue.resolvedAt ?? createdAt
            let effectiveSessionID = issue.lastCaptureSessionId ?? fallbackSessionID

            return Observation(
                id: issue.issueID,
                propertyID: propertyID,
                sessionID: effectiveSessionID,
                createdAt: createdAt,
                updatedAt: updatedAt,
                statement: trimmedNonEmpty(issue.detailNote) ?? "",
                status: status,
                linkedShotID: linkedShot,
                resolutionPhotoRef: nil,
                resolutionStatement: nil,
                updatedInSessionID: effectiveSessionID,
                resolvedInSessionID: status == .resolved ? effectiveSessionID : nil,
                building: latestMetaShot?.building,
                targetElevation: latestMetaShot?.elevation,
                detailType: latestMetaShot?.detailType,
                priority: latestMetaShot?.priority,
                currentReason: trimmedNonEmpty(issue.currentReason) ?? trimmedNonEmpty(issue.detailNote),
                previousReason: trimmedNonEmpty(issue.previousReason),
                historyEvents: [],
                updateHistory: [],
                note: trimmedNonEmpty(issue.detailNote),
                shots: shots,
                guidedShots: []
            )
        }

        var processedIssueIDs = Set<UUID>()
        for issue in metadata.issues {
            processedIssueIDs.insert(issue.issueID)
            mergedByID[issue.issueID] = buildObservation(issue: issue, fallbackSessionID: sessionID)
        }

        // Fallback: if flagged shots exist without issue rows, still restore a usable flagged entry.
        let orphanIssueIDs = Set(flaggedShotsByIssueID.keys).subtracting(processedIssueIDs)
        for issueID in orphanIssueIDs {
            let synthetic = IssueMetadata(
                issueID: issueID,
                issueStatus: "active",
                currentReason: nil,
                previousReason: nil,
                firstSeenAt: metadata.startedAt,
                firstSeenAtLocal: nil,
                lastSeenAt: metadata.startedAt,
                lastSeenAtLocal: nil,
                resolvedAt: nil,
                resolvedAtLocal: nil,
                lastCaptureSessionId: sessionID,
                detailNote: nil,
                shotKey: nil,
                historyEvents: []
            )
            mergedByID[issueID] = buildObservation(issue: synthetic, fallbackSessionID: sessionID)
        }

        let merged = mergedByID.values.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt < rhs.updatedAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        try writeObservations(merged, propertyID: propertyID)
    }

    func wipeAllLocalData() throws {
        try performFileIOSync {
            if fileManager.fileExists(atPath: scoutRootURL.path) {
                try fileManager.removeItem(at: scoutRootURL)
            }
            try createStorageDirectories(baseDirectoryURL: scoutRootURL)
            NotificationCenter.default.post(name: .scoutPersistentDataDidChange, object: nil)
        }
    }

    // MARK: - Private Helpers

    private func createStorageDirectories(baseDirectoryURL: URL) throws {
        if !fileManager.fileExists(atPath: baseDirectoryURL.path) {
            try fileManager.createDirectory(at: baseDirectoryURL, withIntermediateDirectories: true)
        }

        if !fileManager.fileExists(atPath: observationsDirectoryURL.path) {
            try fileManager.createDirectory(at: observationsDirectoryURL, withIntermediateDirectories: true)
        }

        if !fileManager.fileExists(atPath: guidedShotsDirectoryURL.path) {
            try fileManager.createDirectory(at: guidedShotsDirectoryURL, withIntermediateDirectories: true)
        }
        
        if !fileManager.fileExists(atPath: sessionsDirectoryURL.path) {
            try fileManager.createDirectory(at: sessionsDirectoryURL, withIntermediateDirectories: true)
        }

        if !fileManager.fileExists(atPath: propertyFoldersURL.path) {
            try fileManager.createDirectory(at: propertyFoldersURL, withIntermediateDirectories: true)
        }

        if !fileManager.fileExists(atPath: propertySyncEventsDirectoryURL.path) {
            try fileManager.createDirectory(at: propertySyncEventsDirectoryURL, withIntermediateDirectories: true)
        }
    }

    private func ensurePropertyExists(_ propertyID: UUID) throws {
        let properties = try readProperties()
        guard properties.contains(where: { $0.id == propertyID }) else {
            throw StoreError.propertyNotFound(propertyID)
        }
    }

    @discardableResult
    private func offloadUbiquitousFiles(in directoryURL: URL) -> Int {
        guard fileManager.fileExists(atPath: directoryURL.path) else { return 0 }
        let urls = (try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var offloaded = 0
        for url in urls {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
            if values?.isDirectory == true {
                offloaded += offloadUbiquitousFiles(in: url)
                continue
            }
            guard values?.isUbiquitousItem == true else { continue }
            guard values?.ubiquitousItemDownloadingStatus == .current else { continue }
            if (try? fileManager.evictUbiquitousItem(at: url)) != nil {
                offloaded += 1
            }
        }
        return offloaded
    }

    private func readProperties() throws -> [Property] {
        try migratedPropertyAndOrganizationState().properties
    }

    private func readPropertiesRaw() throws -> [Property] {
        try readPropertiesRaw(downloadTimeout: 6.0)
    }

    private func readPropertiesRaw(downloadTimeout: TimeInterval) throws -> [Property] {
        let syncProjected = try projectedPropertiesFromSyncEvents()
        if let syncProjected {
            if syncProjected.isEmpty {
                if fileManager.fileExists(atPath: propertiesURL.path) {
                    try? fileManager.removeItem(at: propertiesURL)
                }
            } else {
                try writeProperties(syncProjected)
            }
            return syncProjected
        }

        if !fileManager.fileExists(atPath: propertiesURL.path) {
            _ = ensureUbiquitousItemAvailable(at: propertiesURL, timeout: downloadTimeout)
        }
        guard fileManager.fileExists(atPath: propertiesURL.path) else {
            return []
        }

        let data: Data
        do {
            data = try Data(contentsOf: propertiesURL)
        } catch {
            if ensureUbiquitousItemAvailable(at: propertiesURL, timeout: downloadTimeout) {
                data = try Data(contentsOf: propertiesURL)
            } else {
                throw error
            }
        }
        return try decoder.decode([Property].self, from: data)
    }

    private func writeProperties(_ properties: [Property]) throws {
        let data = try encoder.encode(properties)
        try data.write(to: propertiesURL, options: .atomic)
    }

    private func projectedPropertiesFromSyncEvents() throws -> [Property]? {
        let events = try readPropertySyncEvents()
        guard !events.isEmpty else { return nil }

        var latestByPropertyID: [UUID: PropertySyncEvent] = [:]
        for event in events {
            if let existing = latestByPropertyID[event.propertyID] {
                if existing.occurredAt > event.occurredAt {
                    continue
                }
                if existing.occurredAt == event.occurredAt,
                   existing.eventID.uuidString > event.eventID.uuidString {
                    continue
                }
            }
            latestByPropertyID[event.propertyID] = event
        }

        let projected = latestByPropertyID.values.compactMap { event -> Property? in
            guard event.operation == .upsert else { return nil }
            return event.property
        }
        return projected.sorted { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.createdAt < rhs.createdAt
        }
    }

    private func readPropertySyncEvents() throws -> [PropertySyncEvent] {
        guard fileManager.fileExists(atPath: propertySyncEventsDirectoryURL.path) else {
            return []
        }
        let files = try fileManager.contentsOfDirectory(
            at: propertySyncEventsDirectoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        var events: [PropertySyncEvent] = []
        for fileURL in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let values = try fileURL.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == true { continue }
            let data = try Data(contentsOf: fileURL)
            if let event = try? decoder.decode(PropertySyncEvent.self, from: data) {
                events.append(event)
            }
        }
        return events
    }

    private func appendPropertySyncEvent(
        propertyID: UUID,
        operation: PropertySyncEvent.Operation,
        property: Property?,
        occurredAt: Date
    ) throws {
        if !fileManager.fileExists(atPath: propertySyncEventsDirectoryURL.path) {
            try fileManager.createDirectory(at: propertySyncEventsDirectoryURL, withIntermediateDirectories: true)
        }
        let event = PropertySyncEvent(
            eventID: UUID(),
            propertyID: propertyID,
            occurredAt: occurredAt,
            operation: operation,
            property: property
        )
        let timestamp = String(format: "%.6f", occurredAt.timeIntervalSince1970).replacingOccurrences(of: ".", with: "_")
        let filename = "\(timestamp)-\(event.eventID.uuidString).json"
        let data = try encoder.encode(event)
        try data.write(
            to: propertySyncEventsDirectoryURL.appendingPathComponent(filename, isDirectory: false),
            options: .atomic
        )
    }

    private func seedPropertySyncEventsIfNeeded(from properties: [Property]) throws {
        let existing = try readPropertySyncEvents()
        guard existing.isEmpty else { return }
        for property in properties {
            try appendPropertySyncEvent(
                propertyID: property.id,
                operation: .upsert,
                property: property,
                occurredAt: property.updatedAt
            )
        }
    }

    private func readOrganizationsRaw() throws -> [Organization] {
        try readOrganizationsRaw(downloadTimeout: 6.0)
    }

    private func readOrganizationsRaw(downloadTimeout: TimeInterval) throws -> [Organization] {
        if !fileManager.fileExists(atPath: organizationsURL.path) {
            _ = ensureUbiquitousItemAvailable(at: organizationsURL, timeout: downloadTimeout)
        }
        guard fileManager.fileExists(atPath: organizationsURL.path) else {
            return []
        }

        let data: Data
        do {
            data = try Data(contentsOf: organizationsURL)
        } catch {
            if ensureUbiquitousItemAvailable(at: organizationsURL, timeout: downloadTimeout) {
                data = try Data(contentsOf: organizationsURL)
            } else {
                throw error
            }
        }
        return try decoder.decode([Organization].self, from: data)
    }

    private func ensureUbiquitousItemAvailable(at url: URL, timeout: TimeInterval) -> Bool {
        if fileManager.fileExists(atPath: url.path) {
            return true
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

    private func archiveTimestampString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: date)
    }

    private func sanitizedArchivePathSegment(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "snapshot" }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let mappedScalars = trimmed.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let collapsed = String(mappedScalars)
            .replacingOccurrences(of: "__", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return collapsed.isEmpty ? "snapshot" : String(collapsed.prefix(48))
    }

    private func archiveFileRecords(in snapshotRoot: URL) throws -> [SessionArchiveManifest.FileRecord] {
        let urls = try fileManager.subpathsOfDirectory(atPath: snapshotRoot.path)
            .sorted()
            .map { snapshotRoot.appendingPathComponent($0, isDirectory: false) }
            .filter { $0.lastPathComponent != "manifest.json" }
            .filter { fileManager.fileExists(atPath: $0.path) }

        var records: [SessionArchiveManifest.FileRecord] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                continue
            }
            let relativePath = url.path.replacingOccurrences(of: snapshotRoot.path + "/", with: "")
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            records.append(
                SessionArchiveManifest.FileRecord(
                    relativePath: relativePath,
                    size: Int64(data.count),
                    sha256: digest
                )
            )
        }
        return records.sorted { $0.relativePath < $1.relativePath }
    }

    private func verifySessionArchiveSnapshot(at snapshotRoot: URL, manifest: SessionArchiveManifest) throws {
        for record in manifest.files {
            let fileURL = snapshotRoot.appendingPathComponent(record.relativePath, isDirectory: false)
            guard fileManager.fileExists(atPath: fileURL.path) else {
                throw NSError(
                    domain: "LocalStore.SessionArchive",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Archive verify failed: missing file \(record.relativePath)"]
                )
            }
            let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            if digest != record.sha256 || Int64(data.count) != record.size {
                throw NSError(
                    domain: "LocalStore.SessionArchive",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Archive verify failed: checksum mismatch for \(record.relativePath)"]
                )
            }
        }
    }

    private func writeOrganizations(_ organizations: [Organization]) throws {
        let data = try encoder.encode(organizations)
        try data.write(to: organizationsURL, options: .atomic)
    }

    private struct PropertyDeletionTombstone: Codable {
        let propertyID: UUID
        let deletedAt: Date
    }

    private struct PropertySyncEvent: Codable {
        enum Operation: String, Codable {
            case upsert
            case delete
        }

        let eventID: UUID
        let propertyID: UUID
        let occurredAt: Date
        let operation: Operation
        let property: Property?
    }

    private struct HubIndex: Codable {
        struct PropertyRow: Codable {
            let id: UUID
            let orgId: UUID?
            let folderId: String?
            let clientName: String?
            let clientPhone: String?
            let clientEmail: String?
            let name: String
            let address: String?
            let street: String?
            let city: String?
            let state: String?
            let zip: String?
            let baselineSessionID: UUID?
            let isArchived: Bool
            let deletedAt: Date?
            let createdAt: Date
            let updatedAt: Date

            func asProperty() -> Property {
                Property(
                    id: id,
                    orgId: orgId,
                    folderId: folderId,
                    clientName: clientName,
                    clientPhone: clientPhone,
                    clientEmail: clientEmail,
                    name: name,
                    address: address,
                    street: street,
                    city: city,
                    state: state,
                    zip: zip,
                    baselineSessionID: baselineSessionID,
                    isArchived: isArchived,
                    deletedAt: deletedAt,
                    createdAt: createdAt,
                    updatedAt: updatedAt
                )
            }
        }

        struct OrganizationRow: Codable {
            let id: UUID
            let name: String

            func asOrganization() -> Organization {
                Organization(id: id, name: name, contacts: [])
            }
        }

        let schemaVersion: Int
        let generatedAt: Date
        let properties: [PropertyRow]
        let organizations: [OrganizationRow]
    }

    private func readHubIndexRaw(downloadTimeout: TimeInterval) throws -> HubIndex? {
        if !fileManager.fileExists(atPath: hubIndexURL.path) {
            _ = ensureUbiquitousItemAvailable(at: hubIndexURL, timeout: downloadTimeout)
        }
        guard fileManager.fileExists(atPath: hubIndexURL.path) else { return nil }
        if shouldAvoidBlockingUbiquitousRead(at: hubIndexURL, timeout: downloadTimeout) {
            return nil
        }

        let data: Data
        do {
            data = try Data(contentsOf: hubIndexURL)
        } catch {
            if downloadTimeout <= 0.08 {
                return nil
            }
            if ensureUbiquitousItemAvailable(at: hubIndexURL, timeout: downloadTimeout) {
                data = try Data(contentsOf: hubIndexURL)
            } else {
                throw error
            }
        }
        try? data.write(to: localHubIndexCacheURL, options: .atomic)
        return try decoder.decode(HubIndex.self, from: data)
    }

    private func shouldAvoidBlockingUbiquitousRead(at url: URL, timeout: TimeInterval) -> Bool {
        guard timeout <= 0.08 else { return false }
        let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        guard let values = try? url.resourceValues(forKeys: keys),
              values.isUbiquitousItem == true else {
            return false
        }
        if values.ubiquitousItemDownloadingStatus == .current {
            return false
        }
        try? fileManager.startDownloadingUbiquitousItem(at: url)
        return true
    }

    private func writeHubIndex(properties: [Property], organizations: [Organization]) throws {
        let data = try hubIndexData(properties: properties, organizations: organizations)
        try data.write(to: hubIndexURL, options: .atomic)
        try? data.write(to: localHubIndexCacheURL, options: .atomic)
    }

    private func writeHubIndexForAtomicReplacement(
        properties: [Property],
        organizations: [Organization]
    ) throws {
        let data = try hubIndexData(properties: properties, organizations: organizations)
        try atomicWriteFileData(data, to: hubIndexURL)
        try atomicWriteFileData(data, to: localHubIndexCacheURL)
    }

    private func hubIndexData(properties: [Property], organizations: [Organization]) throws -> Data {
        let payload = HubIndex(
            schemaVersion: 1,
            generatedAt: Date(),
            properties: properties.map { property in
                HubIndex.PropertyRow(
                    id: property.id,
                    orgId: property.orgId,
                    folderId: property.folderId,
                    clientName: property.clientName,
                    clientPhone: property.clientPhone,
                    clientEmail: property.clientEmail,
                    name: property.name,
                    address: property.address,
                    street: property.street,
                    city: property.city,
                    state: property.state,
                    zip: property.zip,
                    baselineSessionID: property.baselineSessionID,
                    isArchived: property.isArchived,
                    deletedAt: property.deletedAt,
                    createdAt: property.createdAt,
                    updatedAt: property.updatedAt
                )
            },
            organizations: organizations.map { org in
                HubIndex.OrganizationRow(id: org.id, name: org.name)
            }
        )
        return try encoder.encode(payload)
    }

    private func snapshotPropertyListCacheArtifacts(at urls: [URL]) throws -> [PropertyListCacheArtifactSnapshot] {
        try urls.map { url in
            let data = fileManager.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
            return PropertyListCacheArtifactSnapshot(url: url, data: data)
        }
    }

    private func snapshotPropertySyncEventArtifacts() throws -> PropertySyncEventDirectorySnapshot {
        guard fileManager.fileExists(atPath: propertySyncEventsDirectoryURL.path) else {
            return PropertySyncEventDirectorySnapshot(directoryExisted: false, files: [])
        }

        let urls = try fileManager.contentsOfDirectory(
            at: propertySyncEventsDirectoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        let files = try urls.compactMap { url -> PropertySyncEventArtifactSnapshot? in
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory != true else { return nil }
            return PropertySyncEventArtifactSnapshot(
                filename: url.lastPathComponent,
                data: try Data(contentsOf: url)
            )
        }

        return PropertySyncEventDirectorySnapshot(directoryExisted: true, files: files)
    }

    private func restorePropertyListCacheArtifacts(
        from snapshots: [PropertyListCacheArtifactSnapshot]
    ) throws {
        for snapshot in snapshots {
            if let data = snapshot.data {
                try atomicWriteFileData(data, to: snapshot.url)
            } else if fileManager.fileExists(atPath: snapshot.url.path) {
                try fileManager.removeItem(at: snapshot.url)
            }
        }
    }

    private func restorePropertySyncEventArtifacts(
        from snapshot: PropertySyncEventDirectorySnapshot
    ) throws {
        if fileManager.fileExists(atPath: propertySyncEventsDirectoryURL.path) {
            try fileManager.removeItem(at: propertySyncEventsDirectoryURL)
        }

        guard snapshot.directoryExisted || !snapshot.files.isEmpty else {
            return
        }

        try fileManager.createDirectory(at: propertySyncEventsDirectoryURL, withIntermediateDirectories: true)
        for file in snapshot.files {
            try file.data.write(
                to: propertySyncEventsDirectoryURL.appendingPathComponent(file.filename, isDirectory: false),
                options: .atomic
            )
        }
    }

    private func overwritePropertySyncEvents(with properties: [Property]) throws {
        if fileManager.fileExists(atPath: propertySyncEventsDirectoryURL.path) {
            try fileManager.removeItem(at: propertySyncEventsDirectoryURL)
        }
        guard !properties.isEmpty else { return }
        try fileManager.createDirectory(at: propertySyncEventsDirectoryURL, withIntermediateDirectories: true)
        for property in properties {
            try appendPropertySyncEvent(
                propertyID: property.id,
                operation: .upsert,
                property: property,
                occurredAt: property.updatedAt
            )
        }
    }

    private func readLocalHubIndexCacheRaw() throws -> HubIndex? {
        guard fileManager.fileExists(atPath: localHubIndexCacheURL.path) else { return nil }
        let data = try Data(contentsOf: localHubIndexCacheURL)
        return try decoder.decode(HubIndex.self, from: data)
    }

    private func readPropertyDeletionTombstones() throws -> [PropertyDeletionTombstone] {
        guard fileManager.fileExists(atPath: propertyTombstonesURL.path) else {
            return []
        }
        let data = try Data(contentsOf: propertyTombstonesURL)
        return try decoder.decode([PropertyDeletionTombstone].self, from: data)
    }

    private func writePropertyDeletionTombstones(_ tombstones: [PropertyDeletionTombstone]) throws {
        if tombstones.isEmpty {
            if fileManager.fileExists(atPath: propertyTombstonesURL.path) {
                try fileManager.removeItem(at: propertyTombstonesURL)
            }
            return
        }
        let normalized = tombstones.sorted { lhs, rhs in
            if lhs.deletedAt == rhs.deletedAt {
                return lhs.propertyID.uuidString < rhs.propertyID.uuidString
            }
            return lhs.deletedAt < rhs.deletedAt
        }
        let data = try encoder.encode(normalized)
        try data.write(to: propertyTombstonesURL, options: .atomic)
    }

    private func appendPropertyDeletionTombstone(propertyID: UUID, deletedAt: Date) throws {
        var byID: [UUID: PropertyDeletionTombstone] = Dictionary(
            uniqueKeysWithValues: try readPropertyDeletionTombstones().map { ($0.propertyID, $0) }
        )
        let incoming = PropertyDeletionTombstone(propertyID: propertyID, deletedAt: deletedAt)
        if let existing = byID[propertyID], existing.deletedAt >= incoming.deletedAt {
            return
        }
        byID[propertyID] = incoming
        try writePropertyDeletionTombstones(Array(byID.values))
    }

    private func removePropertyDeletionTombstone(propertyID: UUID) throws {
        let existing = try readPropertyDeletionTombstones()
        let filtered = existing.filter { $0.propertyID != propertyID }
        guard filtered.count != existing.count else { return }
        try writePropertyDeletionTombstones(filtered)
    }

    private func migratedPropertyAndOrganizationState() throws -> (properties: [Property], organizations: [Organization]) {
        try migratedPropertyAndOrganizationState(downloadTimeout: 6.0)
    }

    private func migratedPropertyAndOrganizationState(downloadTimeout: TimeInterval) throws -> (properties: [Property], organizations: [Organization]) {
        let organizationsFileExists = fileManager.fileExists(atPath: organizationsURL.path)
        var organizations = normalizedOrganizations(try readOrganizationsRaw(downloadTimeout: downloadTimeout))
        let originalOrganizationIDs = Set(organizations.map(\.id))
        let defaultOrganization = defaultOrganization(in: &organizations)
        let validOrganizationIDs = Set(organizations.map(\.id))
        let didChangeOrganizations = !organizationsFileExists || Set(organizations.map(\.id)) != originalOrganizationIDs

        var properties = try readPropertiesRaw(downloadTimeout: downloadTimeout)
        var didChangeProperties = false
        var seenFolderNumbers = Set<Int>()

        for index in properties.indices {
            if properties[index].orgId == nil || (properties[index].orgId.map { !validOrganizationIDs.contains($0) } ?? false) {
                properties[index].orgId = defaultOrganization.id
                didChangeProperties = true
            }

            let parsedFolderNumber = parseFolderNumber(properties[index].folderId)
            if let parsedFolderNumber, !seenFolderNumbers.contains(parsedFolderNumber) {
                seenFolderNumbers.insert(parsedFolderNumber)
            } else {
                properties[index].folderId = nil
                didChangeProperties = true
            }
        }

        for index in properties.indices where trimmedNonEmpty(properties[index].folderId) == nil {
            let next = try nextAvailableFolderNumber(used: &seenFolderNumbers)
            properties[index].folderId = formatFolderID(next)
            didChangeProperties = true
        }

        if didChangeOrganizations {
            try writeOrganizations(organizations)
        }
        if didChangeProperties {
            try writeProperties(properties)
        }
        try seedPropertySyncEventsIfNeeded(from: properties)

        let sortedProperties = properties.sorted { $0.createdAt < $1.createdAt }
        try writeHubIndex(properties: sortedProperties, organizations: organizations)
        return (sortedProperties, organizations)
    }

    private func normalizedOrganizations(_ organizations: [Organization]) -> [Organization] {
        var seenIDs = Set<UUID>()
        var output: [Organization] = []
        for organization in organizations {
            let trimmedName = organization.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else { continue }
            guard seenIDs.insert(organization.id).inserted else { continue }
            output.append(Organization(
                id: organization.id,
                name: trimmedName,
                contacts: normalizedOrganizationContacts(organization.contacts)
            ))
        }
        return output.sorted { lhs, rhs in
            if lhs.name.caseInsensitiveCompare("Individual") == .orderedSame { return true }
            if rhs.name.caseInsensitiveCompare("Individual") == .orderedSame { return false }

            let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if nameOrder != .orderedSame {
                return nameOrder == .orderedAscending
            }
            return lhs.id.uuidString.lowercased() < rhs.id.uuidString.lowercased()
        }
    }

    private func normalizedOrganizationContacts(_ contacts: [OrganizationContact]) -> [OrganizationContact] {
        var output: [OrganizationContact] = []
        for contact in contacts {
            let normalizedName = trimmedNonEmpty(contact.name)
            let normalizedPhone = normalizedPropertyPhone(contact.phone)
            let normalizedEmail = trimmedNonEmpty(contact.email)
            guard let normalizedName else { continue }
            let candidate = OrganizationContact(
                id: contact.id,
                name: normalizedName,
                phone: normalizedPhone,
                email: normalizedEmail
            )
            upsertOrganizationContact(candidate, into: &output)
        }
        return output.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func syncOrganizationContacts(in organizations: inout [Organization], with property: Property) {
        guard let organizationID = property.orgId,
              let organizationIndex = organizations.firstIndex(where: { $0.id == organizationID }),
              let name = trimmedNonEmpty(property.clientName) else {
            return
        }

        let candidate = OrganizationContact(
            name: name,
            phone: normalizedPropertyPhone(property.clientPhone),
            email: trimmedNonEmpty(property.clientEmail)
        )
        var contacts = organizations[organizationIndex].contacts
        upsertOrganizationContact(candidate, into: &contacts)
        organizations[organizationIndex].contacts = normalizedOrganizationContacts(contacts)
    }

    private func upsertOrganizationContact(_ candidate: OrganizationContact, into contacts: inout [OrganizationContact]) {
        if let index = contacts.firstIndex(where: { organizationContactMatches($0, candidate) }) {
            var existing = contacts[index]
            existing.name = trimmedNonEmpty(candidate.name) ?? existing.name
            existing.phone = normalizedPropertyPhone(candidate.phone) ?? normalizedPropertyPhone(existing.phone)
            existing.email = trimmedNonEmpty(candidate.email) ?? trimmedNonEmpty(existing.email)
            contacts[index] = existing
            return
        }
        contacts.append(candidate)
    }

    private func organizationContactMatches(_ lhs: OrganizationContact, _ rhs: OrganizationContact) -> Bool {
        let lhsName = trimmedNonEmpty(lhs.name)?.lowercased()
        let rhsName = trimmedNonEmpty(rhs.name)?.lowercased()
        let lhsPhone = normalizedPropertyPhone(lhs.phone)
        let rhsPhone = normalizedPropertyPhone(rhs.phone)
        let lhsEmail = trimmedNonEmpty(lhs.email)?.lowercased()
        let rhsEmail = trimmedNonEmpty(rhs.email)?.lowercased()

        return lhsName == rhsName &&
            lhsPhone == rhsPhone &&
            lhsEmail == rhsEmail
    }

    private func defaultOrganization(in organizations: inout [Organization]) -> Organization {
        if let existing = organizations.first(where: { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("Individual") == .orderedSame }) {
            return existing
        }
        let created = Organization(name: "Individual")
        organizations.append(created)
        organizations = normalizedOrganizations(organizations)
        return organizations.first(where: { $0.id == created.id }) ?? created
    }

    private func parseFolderNumber(_ folderId: String?) -> Int? {
        guard let trimmed = trimmedNonEmpty(folderId),
              trimmed.count == 5,
              let value = Int(trimmed),
              (1...99999).contains(value) else {
            return nil
        }
        return value
    }

    private func formatFolderID(_ value: Int) -> String {
        String(format: "%05d", value)
    }

    private static func sanitizedExportFolderComponent(_ value: String) -> String {
        let illegalCharacters = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let sanitized = value.unicodeScalars.reduce(into: "") { partialResult, scalar in
            partialResult.append(illegalCharacters.contains(scalar) ? " " : String(scalar))
        }
        return sanitized
            .components(separatedBy: CharacterSet.whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func nextAvailableFolderID(in properties: [Property]) throws -> String {
        var used = Set(properties.compactMap { parseFolderNumber($0.folderId) })
        return formatFolderID(try nextAvailableFolderNumber(used: &used))
    }

    private func nextAvailableFolderNumber(used: inout Set<Int>) throws -> Int {
        for candidate in 1...99999 where !used.contains(candidate) {
            used.insert(candidate)
            return candidate
        }
        throw StoreError.noAvailableFolderID
    }

    private func observationsFileURL(for propertyID: UUID) -> URL {
        observationsDirectoryURL.appendingPathComponent("\(propertyID.uuidString).json")
    }

    private func guidedShotsFileURL(for propertyID: UUID) -> URL {
        guidedShotsDirectoryURL.appendingPathComponent("\(propertyID.uuidString).json")
    }
    
    private func sessionsFileURL(for propertyID: UUID) -> URL {
        sessionsDirectoryURL.appendingPathComponent("\(propertyID.uuidString).json")
    }

    private func readObservations(propertyID: UUID) throws -> [Observation] {
        let fileURL = observationsFileURL(for: propertyID)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return []
        }

        let data = try Data(contentsOf: fileURL)
        return try decoder.decode([Observation].self, from: data)
    }

    private func writeObservations(_ observations: [Observation], propertyID: UUID) throws {
        let normalized = observations.map { observation in
            var updated = observation
            updated.historyEvents = LocalConflictRules.normalizeObservationHistoryEventsAppendOnly(
                observation.historyEvents
            )
            updated.updateHistory = LocalConflictRules.normalizeObservationUpdateEntriesAppendOnly(
                observation.updateHistory
            )
            return updated
        }
        let data = try encoder.encode(normalized)
        let fileURL = observationsFileURL(for: propertyID)
        try data.write(to: fileURL, options: .atomic)
    }

    private func readGuidedShots(propertyID: UUID) throws -> [GuidedShot] {
        let fileURL = guidedShotsFileURL(for: propertyID)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return []
        }

        let data = try Data(contentsOf: fileURL)
        return try decoder.decode([GuidedShot].self, from: data)
    }

    private func writeGuidedShots(_ guidedShots: [GuidedShot], propertyID: UUID) throws {
        let normalized = LocalConflictRules.normalizeGuidedCompletionStates(guidedShots)
        let data = try encoder.encode(normalized)
        let fileURL = guidedShotsFileURL(for: propertyID)
        try data.write(to: fileURL, options: .atomic)
    }
    
    private func readSessions(propertyID: UUID) throws -> [Session] {
        let fileURL = sessionsFileURL(for: propertyID)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return []
        }
        
        let data = try Data(contentsOf: fileURL)
        return try decoder.decode([Session].self, from: data)
    }
    
    private func writeSessions(_ sessions: [Session], propertyID: UUID) throws {
        let data = try encoder.encode(sessions)
        let fileURL = sessionsFileURL(for: propertyID)
        try data.write(to: fileURL, options: .atomic)
    }

    private func cleanupReferenceFilesForGuidedShots(_ guidedShots: [GuidedShot]) throws {
        let paths = guidedShots.compactMap(\.referenceImagePath)
        try cleanupReferenceFiles(paths: paths)
    }

    private func cleanupReferenceFiles(paths: [String]) throws {
        let unique = Set(paths.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        for path in unique {
            if fileManager.fileExists(atPath: path) {
                try? fileManager.removeItem(atPath: path)
            }
        }
    }

    private func upsertSessionMetadataLifecycle(for session: Session) throws {
        var metadata = try readOrRecoverSessionMetadata(propertyID: session.propertyID, sessionID: session.id)
        metadata.schemaVersion = max(metadata.schemaVersion, currentSessionSchemaVersion)
        metadata.propertyID = session.propertyID
        metadata.sessionID = session.id
        let currentProperty = currentProperty(for: session.propertyID)
        let propertyName = currentProperty?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let currentOrganization = currentProperty?.orgId.flatMap { organization(withID: $0) }
        let primaryContactName = trimmedNonEmpty(currentProperty?.clientName)
        let primaryContactEmail = trimmedNonEmpty(currentProperty?.clientEmail)
        if (metadata.propertyNameAtCapture ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !propertyName.isEmpty {
            metadata.propertyNameAtCapture = propertyName
        }
        if metadata.orgID == nil {
            metadata.orgID = currentProperty?.orgId
        }
        if metadata.orgNameAtCapture?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            metadata.orgNameAtCapture = trimmedNonEmpty(currentOrganization?.name)
        }
        if metadata.folderIDAtCapture?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            metadata.folderIDAtCapture = trimmedNonEmpty(currentProperty?.folderId)
        }
        if metadata.primaryContactNameAtCapture?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            metadata.primaryContactNameAtCapture = primaryContactName
        }
        if metadata.primaryContactEmailAtCapture?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            metadata.primaryContactEmailAtCapture = primaryContactEmail
        }
        if session.exportedAt != nil, !propertyName.isEmpty {
            metadata.propertyNameAtExport = propertyName
        }
        if metadata.propertyAddressAtCapture?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            metadata.propertyAddressAtCapture = normalizedPropertyAddress(currentProperty?.address)
        }
        if metadata.propertyStreetAtCapture?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            metadata.propertyStreetAtCapture = trimmedNonEmpty(currentProperty?.street)
        }
        if metadata.propertyCityAtCapture?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            metadata.propertyCityAtCapture = trimmedNonEmpty(currentProperty?.city)
        }
        if metadata.propertyStateAtCapture?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            metadata.propertyStateAtCapture = trimmedNonEmpty(currentProperty?.state)
        }
        if metadata.propertyZipAtCapture?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            metadata.propertyZipAtCapture = trimmedNonEmpty(currentProperty?.zip)
        }
        if metadata.propertyPhoneAtCapture?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            metadata.propertyPhoneAtCapture = normalizedPropertyPhone(currentProperty?.clientPhone)
        }
        let captureTimeZone = captureTimeZoneContext(for: session.startedAt)
        if metadata.timeZoneIdentifierAtCapture.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            metadata.timeZoneIdentifierAtCapture = captureTimeZone.identifier
        }
        metadata.timeZoneOffsetAtCapture = captureTimeZone.offsetString
        metadata.timeZoneOffsetMinutesAtCapture = captureTimeZone.offsetMinutes
        metadata.startedAt = session.startedAt
        metadata.sessionStartedAtLocal = localISO8601String(for: session.startedAt, timeZone: captureTimeZone.timeZone)
        metadata.endedAt = session.endedAt
        metadata.sessionEndedAtLocal = session.endedAt.map { localISO8601String(for: $0, timeZone: captureTimeZone.timeZone) }
        metadata.status = session.status
        if metadata.captureProfile == nil {
            metadata.captureProfile = session.captureProfile?.rawValue
        }
        metadata.isBaselineSession = isBaselineSession(sessionID: session.id, propertyID: session.propertyID)
        metadata.exportedAt = session.exportedAt
        metadata.isSealed = session.isSealed
        metadata.firstDeliveredAt = session.firstDeliveredAt
        metadata.reExportExpiresAt = session.reExportExpiresAt
        metadata.appVersion = appVersionString()
        metadata.deviceModel = deviceModelString()
        metadata.osVersion = osVersionString()
        let normalized = normalizeSessionMetadata(metadata, propertyID: session.propertyID, sessionID: session.id)
        try writeSessionMetadata(normalized)
    }

    private func readOrRecoverSessionMetadata(propertyID: UUID, sessionID: UUID) throws -> SessionMetadata {
        let fileURL = sessionMetadataFileURL(propertyID: propertyID, sessionID: sessionID)
        if !fileManager.fileExists(atPath: fileURL.path) {
            let now = Date()
            let captureTimeZone = captureTimeZoneContext(for: now)
            let property = currentProperty(for: propertyID)
            return SessionMetadata(
                schemaVersion: currentSessionSchemaVersion,
                propertyID: propertyID,
                sessionID: sessionID,
                orgID: property?.orgId,
                orgNameAtCapture: property?.orgId.flatMap { organization(withID: $0)?.name },
                folderIDAtCapture: property?.folderId,
                propertyNameAtCapture: nil,
                propertyNameAtExport: nil,
                primaryContactNameAtCapture: property?.clientName,
                primaryContactEmailAtCapture: property?.clientEmail,
                propertyAddressAtCapture: normalizedPropertyAddress(property?.address),
                propertyStreetAtCapture: trimmedNonEmpty(property?.street),
                propertyCityAtCapture: trimmedNonEmpty(property?.city),
                propertyStateAtCapture: trimmedNonEmpty(property?.state),
                propertyZipAtCapture: trimmedNonEmpty(property?.zip),
                propertyPhoneAtCapture: normalizedPropertyPhone(property?.clientPhone),
                timeZoneIdentifierAtCapture: captureTimeZone.identifier,
                timeZoneOffsetAtCapture: captureTimeZone.offsetString,
                timeZoneOffsetMinutesAtCapture: captureTimeZone.offsetMinutes,
                startedAt: now,
                sessionStartedAtLocal: localISO8601String(for: now, timeZone: captureTimeZone.timeZone),
                endedAt: nil,
                sessionEndedAtLocal: nil,
                status: .draft,
                isBaselineSession: false,
                exportedAt: nil,
                isSealed: false,
                firstDeliveredAt: nil,
                reExportExpiresAt: nil,
                appVersion: appVersionString(),
                deviceModel: deviceModelString(),
                osVersion: osVersionString(),
                shots: [],
                issues: [],
                guidedShots: []
            )
        }

        do {
            let data = try Data(contentsOf: fileURL)
            var metadata = try decoder.decode(SessionMetadata.self, from: data)
            metadata.schemaVersion = max(metadata.schemaVersion, currentSessionSchemaVersion)
            metadata.propertyID = propertyID
            metadata.sessionID = sessionID
            metadata.appVersion = metadata.appVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? appVersionString()
                : metadata.appVersion
            metadata.deviceModel = metadata.deviceModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? deviceModelString()
                : metadata.deviceModel
            metadata.osVersion = metadata.osVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? osVersionString()
                : metadata.osVersion
            return normalizeSessionMetadata(metadata, propertyID: propertyID, sessionID: sessionID)
        } catch {
            print("Recoverable session metadata decode failure for session \(sessionID): \(error)")
            let now = Date()
            let captureTimeZone = captureTimeZoneContext(for: now)
            let property = currentProperty(for: propertyID)
            return SessionMetadata(
                schemaVersion: currentSessionSchemaVersion,
                propertyID: propertyID,
                sessionID: sessionID,
                orgID: property?.orgId,
                orgNameAtCapture: property?.orgId.flatMap { organization(withID: $0)?.name },
                folderIDAtCapture: property?.folderId,
                propertyNameAtCapture: nil,
                propertyNameAtExport: nil,
                primaryContactNameAtCapture: property?.clientName,
                primaryContactEmailAtCapture: property?.clientEmail,
                propertyAddressAtCapture: normalizedPropertyAddress(property?.address),
                propertyStreetAtCapture: trimmedNonEmpty(property?.street),
                propertyCityAtCapture: trimmedNonEmpty(property?.city),
                propertyStateAtCapture: trimmedNonEmpty(property?.state),
                propertyZipAtCapture: trimmedNonEmpty(property?.zip),
                propertyPhoneAtCapture: normalizedPropertyPhone(property?.clientPhone),
                timeZoneIdentifierAtCapture: captureTimeZone.identifier,
                timeZoneOffsetAtCapture: captureTimeZone.offsetString,
                timeZoneOffsetMinutesAtCapture: captureTimeZone.offsetMinutes,
                startedAt: now,
                sessionStartedAtLocal: localISO8601String(for: now, timeZone: captureTimeZone.timeZone),
                endedAt: nil,
                sessionEndedAtLocal: nil,
                status: .draft,
                isBaselineSession: false,
                exportedAt: nil,
                isSealed: false,
                firstDeliveredAt: nil,
                reExportExpiresAt: nil,
                appVersion: appVersionString(),
                deviceModel: deviceModelString(),
                osVersion: osVersionString(),
                shots: [],
                issues: [],
                guidedShots: []
            )
        }
    }

    private func writeSessionMetadata(_ metadata: SessionMetadata) throws {
        let normalized = normalizeSessionMetadata(metadata, propertyID: metadata.propertyID, sessionID: metadata.sessionID)
        let propertyID = normalized.propertyID
        let sessionID = normalized.sessionID
        let folder = sessionMetadataFolderURL(propertyID: propertyID, sessionID: sessionID)
        if !fileManager.fileExists(atPath: folder.path) {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try ensureSessionFileStorage(propertyID: propertyID, sessionID: sessionID)
        let fileURL = sessionMetadataFileURL(propertyID: propertyID, sessionID: sessionID)
        let tempURL = folder.appendingPathComponent("session-\(UUID().uuidString).tmp")
        let data = try encoder.encode(normalized)
        try data.write(to: tempURL, options: .atomic)

        do {
            if fileManager.fileExists(atPath: fileURL.path) {
                _ = try fileManager.replaceItemAt(fileURL, withItemAt: tempURL, backupItemName: nil, options: [.usingNewMetadataOnly])
            } else {
                try fileManager.moveItem(at: tempURL, to: fileURL)
            }
        } catch {
            if fileManager.fileExists(atPath: tempURL.path) {
                try? fileManager.removeItem(at: tempURL)
            }
            throw error
        }
        let hasAddressSnapshot = !(normalized.propertyAddressAtCapture?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let hasTimeZoneOffset = !normalized.timeZoneOffsetAtCapture.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        verboseLog("[SessionJSON] schemaVersion=\(normalized.schemaVersion) sessionID=\(sessionID.uuidString) shotsCount=\(normalized.shots.count) issuesCount=\(normalized.issues.count) hasAddressSnapshot=\(hasAddressSnapshot) hasTimeZoneOffset=\(hasTimeZoneOffset)")
        if let firstShot = normalized.shots.first {
            verboseLog("[SessionJSONTime] startedAt=\(normalized.startedAt) sessionStartedAtLocal=\(normalized.sessionStartedAtLocal) timeZoneIdentifierAtCapture=\(normalized.timeZoneIdentifierAtCapture) timeZoneOffsetAtCapture=\(normalized.timeZoneOffsetAtCapture) firstShotCreatedAt=\(firstShot.createdAt) firstShotCapturedAtLocal=\(firstShot.capturedAtLocal ?? "nil") firstShotExifOrientation=\(firstShot.exifOrientation ?? 0)")
        } else {
            verboseLog("[SessionJSONTime] startedAt=\(normalized.startedAt) sessionStartedAtLocal=\(normalized.sessionStartedAtLocal) timeZoneIdentifierAtCapture=\(normalized.timeZoneIdentifierAtCapture) timeZoneOffsetAtCapture=\(normalized.timeZoneOffsetAtCapture) firstShotCreatedAt=nil firstShotCapturedAtLocal=nil firstShotExifOrientation=0")
        }
    }

    private func sessionMetadataFolderURL(propertyID: UUID, sessionID: UUID) -> URL {
        sessionFolderURL(propertyID: propertyID, sessionID: sessionID)
    }

    private func sessionMetadataFileURL(propertyID: UUID, sessionID: UUID) -> URL {
        sessionJSONURL(propertyID: propertyID, sessionID: sessionID)
    }

    private struct PropertyDeletePlan {
        let urls: [URL]
    }

    private func makePropertyDeletePlan(propertyID: UUID, allProperties: [Property]) throws -> PropertyDeletePlan {
        let guided = try readGuidedShots(propertyID: propertyID)
        let observations = try readObservations(propertyID: propertyID)

        let propertyScopedFiles: [URL] = [
            observationsFileURL(for: propertyID),
            guidedShotsFileURL(for: propertyID),
            sessionsFileURL(for: propertyID),
            propertyFolderURL(propertyID: propertyID)
        ]

        let referencedPaths = Set(
            (
                guided.compactMap(\.referenceImagePath) +
                observations.flatMap { $0.guidedShots.compactMap(\.referenceImagePath) }
            )
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        )

        let retainedReferencePaths = try referencedPathsStillUsedByOtherProperties(
            excluding: propertyID,
            allProperties: allProperties
        )

        let deletableReferenceURLs = referencedPaths
            .subtracting(retainedReferencePaths)
            .compactMap { path -> URL? in
                guard path.hasPrefix(activeRootURL.path) || path.hasPrefix(scoutRootURL.path) else { return nil }
                return URL(fileURLWithPath: path)
            }

        var ordered: [URL] = []
        var seen = Set<String>()
        for url in propertyScopedFiles + deletableReferenceURLs.sorted(by: { $0.path < $1.path }) {
            if seen.insert(url.path).inserted {
                ordered.append(url)
            }
        }
        return PropertyDeletePlan(urls: ordered)
    }

    private func referencedPathsStillUsedByOtherProperties(excluding propertyID: UUID, allProperties: [Property]) throws -> Set<String> {
        var referencedPaths = Set<String>()

        for otherPropertyID in allProperties.map(\.id) where otherPropertyID != propertyID {
            let guided = try readGuidedShots(propertyID: otherPropertyID)
            let observations = try readObservations(propertyID: otherPropertyID)

            for path in guided.compactMap(\.referenceImagePath) {
                let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    referencedPaths.insert(trimmed)
                }
            }

            for path in observations.flatMap({ $0.guidedShots.compactMap(\.referenceImagePath) }) {
                let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    referencedPaths.insert(trimmed)
                }
            }
        }

        return referencedPaths
    }

    private func referencedPaths(for properties: [Property]) throws -> Set<String> {
        var referencedPaths = Set<String>()

        for propertyID in properties.map(\.id) {
            let guided = try readGuidedShots(propertyID: propertyID)
            let observations = try readObservations(propertyID: propertyID)

            for path in guided.compactMap(\.referenceImagePath) {
                let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    referencedPaths.insert(trimmed)
                }
            }

            for path in observations.flatMap({ $0.guidedShots.compactMap(\.referenceImagePath) }) {
                let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    referencedPaths.insert(trimmed)
                }
            }
        }

        return referencedPaths
    }

    private func purgeUnreferencedGuidedReferenceFiles(allProperties: [Property]) throws {
        let guidedReferencesDirectory = guidedReferencesDirectoryURL()
        guard fileManager.fileExists(atPath: guidedReferencesDirectory.path) else { return }

        let referencedPaths = try referencedPaths(for: allProperties)
        let children = try fileManager.contentsOfDirectory(
            at: guidedReferencesDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        for childURL in children {
            let childPath = childURL.path.trimmingCharacters(in: .whitespacesAndNewlines)
            if !referencedPaths.contains(childPath) {
                try fileManager.removeItem(at: childURL)
            }
        }

        let remaining = try fileManager.contentsOfDirectory(
            at: guidedReferencesDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        if remaining.isEmpty {
            try fileManager.removeItem(at: guidedReferencesDirectory)
        }
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

    private func deviceModelString() -> String {
        UIDevice.current.model
    }

    private func osVersionString() -> String {
        UIDevice.current.systemVersion
    }

    private func isBaselineSession(sessionID: UUID, propertyID: UUID) -> Bool {
        let properties = (try? readProperties()) ?? []
        return properties.first(where: { $0.id == propertyID })?.baselineSessionID == sessionID
    }

    private func currentPropertyName(for propertyID: UUID) -> String {
        let value = currentProperty(for: propertyID)?.name ?? ""
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func currentProperty(for propertyID: UUID) -> Property? {
        let properties = (try? migratedPropertyAndOrganizationState().properties) ?? ((try? readPropertiesRaw()) ?? [])
        return properties.first(where: { $0.id == propertyID })
    }

    private func organization(withID organizationID: UUID) -> Organization? {
        let organizations = (try? migratedPropertyAndOrganizationState().organizations) ?? ((try? readOrganizationsRaw()) ?? [])
        return organizations.first(where: { $0.id == organizationID })
    }

    private func normalizeSessionMetadata(_ metadata: SessionMetadata, propertyID: UUID, sessionID: UUID) -> SessionMetadata {
        let property = currentProperty(for: propertyID)
        let propertyName = property?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedOrgID = property?.orgId ?? metadata.orgID
        let resolvedOrgName = resolvedOrgID.flatMap { organization(withID: $0)?.name } ?? trimmedNonEmpty(metadata.orgNameAtCapture)
        let resolvedFolderID = trimmedNonEmpty(metadata.folderIDAtCapture) ?? trimmedNonEmpty(property?.folderId)
        let resolvedPrimaryContactName = trimmedNonEmpty(metadata.primaryContactNameAtCapture) ?? trimmedNonEmpty(property?.clientName)
        let resolvedPrimaryContactEmail = trimmedNonEmpty(metadata.primaryContactEmailAtCapture) ?? trimmedNonEmpty(property?.clientEmail)
        let captureTimeZone = captureTimeZoneContext(
            identifier: metadata.timeZoneIdentifierAtCapture,
            offsetString: metadata.timeZoneOffsetAtCapture,
            offsetMinutes: metadata.timeZoneOffsetMinutesAtCapture,
            for: metadata.startedAt
        )
        let resolvedAddress = (metadata.propertyAddressAtCapture?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            ? normalizedPropertyAddress(property?.address)
            : metadata.propertyAddressAtCapture?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedStreet = trimmedNonEmpty(metadata.propertyStreetAtCapture) ?? trimmedNonEmpty(property?.street)
        let resolvedCity = trimmedNonEmpty(metadata.propertyCityAtCapture) ?? trimmedNonEmpty(property?.city)
        let resolvedState = trimmedNonEmpty(metadata.propertyStateAtCapture) ?? trimmedNonEmpty(property?.state)
        let resolvedZip = trimmedNonEmpty(metadata.propertyZipAtCapture) ?? trimmedNonEmpty(property?.zip)
        let resolvedPhone = normalizedPropertyPhone(
            metadata.propertyPhoneAtCapture ?? property?.clientPhone
        )

        let normalizedShotBase = metadata.shots
            .map { normalizeShotMetadata($0, propertyID: propertyID, sessionID: sessionID, captureTimeZone: captureTimeZone) }
            .sorted { $0.createdAt < $1.createdAt }
        let normalizedShots = deduplicatedShots(
            restoredMissingGuidedShots(
                from: normalizedShotBase,
                guidedShots: metadata.guidedShots,
                propertyID: propertyID,
                sessionID: sessionID,
                captureTimeZone: captureTimeZone
            )
        )
        let normalizedIssues = metadata.issues
            .map { normalizeIssueMetadata($0, captureTimeZone: captureTimeZone) }
        let observations = (try? fetchObservations(propertyID: propertyID)) ?? []
        let mergedIssues = mergeIssuesWithCanonicalObservations(
            existingIssues: normalizedIssues,
            observations: observations,
            sessionID: sessionID,
            shots: normalizedShots,
            captureTimeZone: captureTimeZone
        )

        return SessionMetadata(
            schemaVersion: max(metadata.schemaVersion, currentSessionSchemaVersion),
            propertyID: propertyID,
            sessionID: sessionID,
            orgID: resolvedOrgID,
            orgNameAtCapture: resolvedOrgName,
            folderIDAtCapture: resolvedFolderID,
            propertyNameAtCapture: trimmedNonEmpty(metadata.propertyNameAtCapture) ?? (propertyName.isEmpty ? nil : propertyName),
            propertyNameAtExport: trimmedNonEmpty(metadata.propertyNameAtExport),
            primaryContactNameAtCapture: resolvedPrimaryContactName,
            primaryContactEmailAtCapture: resolvedPrimaryContactEmail,
            propertyAddressAtCapture: resolvedAddress,
            propertyStreetAtCapture: resolvedStreet,
            propertyCityAtCapture: resolvedCity,
            propertyStateAtCapture: resolvedState,
            propertyZipAtCapture: resolvedZip,
            propertyPhoneAtCapture: resolvedPhone,
            timeZoneIdentifierAtCapture: captureTimeZone.identifier,
            timeZoneOffsetAtCapture: captureTimeZone.offsetString,
            timeZoneOffsetMinutesAtCapture: captureTimeZone.offsetMinutes,
            captureProfile: trimmedNonEmpty(metadata.captureProfile),
            startedAt: metadata.startedAt,
            sessionStartedAtLocal: localISO8601String(for: metadata.startedAt, timeZone: captureTimeZone.timeZone),
            endedAt: metadata.endedAt,
            sessionEndedAtLocal: metadata.endedAt.map { end in
                localISO8601String(for: end, timeZone: captureTimeZone.timeZone)
            },
            status: metadata.status,
            isBaselineSession: metadata.isBaselineSession,
            exportedAt: metadata.exportedAt,
            isSealed: metadata.isSealed,
            firstDeliveredAt: metadata.firstDeliveredAt,
            reExportExpiresAt: metadata.reExportExpiresAt,
            appVersion: metadata.appVersion,
            deviceModel: metadata.deviceModel,
            osVersion: metadata.osVersion,
            shots: normalizedShots,
            issues: mergedIssues,
            guidedShots: metadata.guidedShots
        )
    }

    private func normalizeShotMetadata(
        _ shot: ShotMetadata,
        propertyID: UUID,
        sessionID: UUID,
        captureTimeZone: CaptureTimeZoneContext
    ) -> ShotMetadata {
        let fileName = URL(fileURLWithPath: shot.originalFilename).lastPathComponent
        let normalizedFilename = fileName.isEmpty ? shot.originalFilename : fileName
        let normalizedRelativePath = shot.originalRelativePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Originals/\(normalizedFilename)"
            : shot.originalRelativePath
        let normalizedShotKey = shot.shotKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? ShotMetadata.makeShotKey(
                building: shot.building,
                elevation: shot.elevation,
                detailType: shot.detailType,
                angleIndex: shot.angleIndex
            )
            : shot.shotKey
        let normalizedStampedFilename = shot.stampedFilename.map { URL(fileURLWithPath: $0).lastPathComponent }
        let normalizedStampedPath: String?
        if let stamped = shot.stampedRelativePath?.trimmingCharacters(in: .whitespacesAndNewlines), !stamped.isEmpty {
            normalizedStampedPath = stamped
        } else if let stampedName = normalizedStampedFilename, !stampedName.isEmpty {
            normalizedStampedPath = "Stamped/\(stampedName)"
        } else {
            normalizedStampedPath = nil
        }
        return ShotMetadata(
            shotID: shot.shotID,
            propertyID: propertyID,
            sessionID: sessionID,
            createdAt: shot.createdAt,
            capturedAtLocal: localISO8601String(for: shot.createdAt, timeZone: captureTimeZone.timeZone),
            updatedAt: shot.updatedAt,
            building: shot.building,
            elevation: CanonicalElevation.normalize(shot.elevation) ?? shot.elevation,
            detailType: shot.detailType,
            angleIndex: max(1, shot.angleIndex),
            trade: shot.trade,
            priority: shot.priority,
            shotKey: normalizedShotKey,
            isGuided: shot.isGuided,
            isFlagged: shot.isFlagged,
            issueID: shot.issueID,
            issueStatus: shot.issueStatus,
            captureKind: shot.captureKind,
            firstCaptureKind: normalizedFirstCaptureKind(
                shot.firstCaptureKind,
                captureKind: shot.captureKind,
                isFlagged: shot.isFlagged
            ),
            noteText: shot.noteText,
            noteCategory: shot.noteCategory,
            originalFilename: normalizedFilename,
            originalRelativePath: normalizedRelativePath,
            originalByteSize: shot.originalByteSize,
            storageBucket: shot.storageBucket,
            storagePath: shot.storagePath,
            checksumSHA256: shot.checksumSHA256,
            byteSize: shot.byteSize ?? shot.originalByteSize,
            uploadState: shot.uploadState,
            uploadAttempts: shot.uploadAttempts,
            lastUploadError: shot.lastUploadError,
            stampedFilename: normalizedStampedFilename,
            stampedRelativePath: normalizedStampedPath,
            captureMode: shot.captureMode,
            lens: shot.lens,
            exifOrientation: normalizeExifOrientation(rawValue: shot.exifOrientation, legacy: shot.orientation),
            orientation: shot.orientation,
            latitude: shot.latitude,
            longitude: shot.longitude,
            accuracyMeters: shot.accuracyMeters,
            imageWidth: shot.imageWidth,
            imageHeight: shot.imageHeight,
            lifecycleState: shot.lifecycleState,
            retiredAt: shot.retiredAt,
            retiredReason: shot.retiredReason,
            retiredByUserID: shot.retiredByUserID,
            supersededByShotID: shot.supersededByShotID,
            supersedesShotID: shot.supersedesShotID,
            replacementReason: shot.replacementReason,
            hiddenFromReports: shot.hiddenFromReports,
            hiddenFromGallery: shot.hiddenFromGallery,
            lifecycleUpdatedAt: shot.lifecycleUpdatedAt
        )
    }

    private func normalizeIssueMetadata(_ issue: IssueMetadata, captureTimeZone: CaptureTimeZoneContext) -> IssueMetadata {
        let firstSeenAt = issue.firstSeenAt
        let lastSeenAt = issue.lastSeenAt ?? issue.firstSeenAt
        let resolvedAt = issue.resolvedAt
        let previousReason = normalizedPreviousReason(
            issue.previousReason,
            from: issue.historyEvents
        )
        return IssueMetadata(
            issueID: issue.issueID,
            issueStatus: issue.issueStatus,
            currentReason: trimmedNonEmpty(issue.currentReason),
            previousReason: previousReason,
            firstSeenAt: firstSeenAt,
            firstSeenAtLocal: firstSeenAt.map {
                localISO8601String(for: $0, timeZone: captureTimeZone.timeZone)
            } ?? trimmedNonEmpty(issue.firstSeenAtLocal),
            lastSeenAt: lastSeenAt,
            lastSeenAtLocal: lastSeenAt.map {
                localISO8601String(for: $0, timeZone: captureTimeZone.timeZone)
            } ?? trimmedNonEmpty(issue.lastSeenAtLocal),
            resolvedAt: resolvedAt,
            resolvedAtLocal: resolvedAt.map {
                localISO8601String(for: $0, timeZone: captureTimeZone.timeZone)
            } ?? trimmedNonEmpty(issue.resolvedAtLocal),
            lastCaptureSessionId: issue.lastCaptureSessionId,
            detailNote: trimmedNonEmpty(issue.detailNote),
            shotKey: trimmedNonEmpty(issue.shotKey),
            historyEvents: issue.historyEvents
        )
    }

    private func normalizedFirstCaptureKind(_ value: String?, captureKind: String?, isFlagged: Bool) -> String? {
        let normalizedValue = trimmedNonEmpty(value)
        guard isFlagged else { return normalizedValue }
        let normalizedCaptureKind = trimmedNonEmpty(captureKind)
        if normalizedCaptureKind == "retake" || normalizedCaptureKind == "captured" {
            return normalizedValue ?? "captured"
        }
        if normalizedValue == nil {
            return normalizedValue ?? "captured"
        }
        return normalizedValue
    }

    private func logicalShotIdentity(for shot: ShotMetadata) -> String {
        shot.logicalShotIdentity
    }

    private func logicalShotIdentity(for issue: IssueMetadata, linkedShot: ShotMetadata?, sessionID: UUID) -> String {
        if let linkedShot {
            return linkedShot.logicalShotIdentity
        }

        let normalizedKey = trimmedNonEmpty(issue.shotKey)?.lowercased() ?? "no-shot-key"
        return "\(sessionID.uuidString.lowercased())|flagged|\(issue.issueID.uuidString.lowercased())|\(normalizedKey)"
    }

    private func deduplicatedShots(_ shots: [ShotMetadata]) -> [ShotMetadata] {
        var byIdentity: [String: ShotMetadata] = [:]
        for shot in shots {
            var identity = logicalShotIdentity(for: shot)
            if shot.isHistorical || shot.supersededByShotID != nil || shot.supersedesShotID != nil {
                identity += "|shot|\(shot.shotID.uuidString.lowercased())"
            }
            guard let existing = byIdentity[identity] else {
                byIdentity[identity] = shot
                continue
            }

            let keepNew: Bool
            if shot.updatedAt != existing.updatedAt {
                keepNew = shot.updatedAt > existing.updatedAt
            } else if shot.createdAt != existing.createdAt {
                keepNew = shot.createdAt > existing.createdAt
            } else {
                keepNew = shot.shotID.uuidString > existing.shotID.uuidString
            }

            if keepNew {
                var replacement = shot
                if replacement.firstCaptureKind?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                    replacement.firstCaptureKind = existing.firstCaptureKind
                }
                byIdentity[identity] = replacement
            } else if existing.firstCaptureKind?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true,
                      let firstCaptureKind = shot.firstCaptureKind {
                var mergedExisting = existing
                mergedExisting.firstCaptureKind = firstCaptureKind
                byIdentity[identity] = mergedExisting
            }
        }

        return byIdentity.values.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.shotID.uuidString < rhs.shotID.uuidString
        }
    }

    private func restoredMissingGuidedShots(
        from shots: [ShotMetadata],
        guidedShots: [GuidedShot],
        propertyID: UUID,
        sessionID: UUID,
        captureTimeZone: CaptureTimeZoneContext
    ) -> [ShotMetadata] {
        var restored = shots
        var existingIDs = Set(shots.map(\.shotID))

        for guided in guidedShots {
            guard let shot = guided.shot else { continue }
            guard existingIDs.insert(shot.id).inserted else { continue }

            let building = trimmedNonEmpty(guided.building) ?? ""
            let elevation = CanonicalElevation.normalize(guided.targetElevation) ?? trimmedNonEmpty(guided.targetElevation) ?? ""
            let detailType = trimmedNonEmpty(guided.detailType) ?? ""
            let angleIndex = max(1, guided.angleIndex ?? 1)
            guard !building.isEmpty, !elevation.isEmpty, !detailType.isEmpty else { continue }

            let localIdentifier = trimmedNonEmpty(shot.imageLocalIdentifier) ?? ""
            let originalFilename = localIdentifier.isEmpty
                ? "\(shot.id.uuidString).heic"
                : URL(fileURLWithPath: localIdentifier).lastPathComponent
            let originalRelativePath = "Originals/\(originalFilename)"
            let originalByteSize: Int? = {
                guard !localIdentifier.isEmpty,
                      let attributes = try? fileManager.attributesOfItem(atPath: localIdentifier),
                      let size = attributes[.size] as? NSNumber else {
                    return nil
                }
                return size.intValue
            }()

            restored.append(
                ShotMetadata(
                    shotID: shot.id,
                    propertyID: propertyID,
                    sessionID: sessionID,
                    createdAt: shot.capturedAt,
                    capturedAtLocal: localISO8601String(for: shot.capturedAt, timeZone: captureTimeZone.timeZone),
                    updatedAt: shot.capturedAt,
                    building: building,
                    elevation: elevation,
                    detailType: detailType,
                    angleIndex: angleIndex,
                    shotKey: ShotMetadata.makeShotKey(
                        building: building,
                        elevation: elevation,
                        detailType: detailType,
                        angleIndex: angleIndex
                    ),
                    isGuided: true,
                    isFlagged: false,
                    issueID: nil,
                    issueStatus: nil,
                    captureKind: nil,
                    firstCaptureKind: nil,
                    noteText: trimmedNonEmpty(shot.note),
                    noteCategory: nil,
                    originalFilename: originalFilename,
                    originalRelativePath: originalRelativePath,
                    originalByteSize: originalByteSize,
                    storageBucket: nil,
                    storagePath: nil,
                    checksumSHA256: nil,
                    byteSize: originalByteSize,
                    uploadState: "pending",
                    uploadAttempts: 0,
                    lastUploadError: nil,
                    stampedFilename: nil,
                    stampedRelativePath: nil,
                    captureMode: nil,
                    lens: nil,
                    exifOrientation: nil,
                    latitude: nil,
                    longitude: nil,
                    accuracyMeters: nil,
                    imageWidth: nil,
                    imageHeight: nil
                )
            )
        }

        return restored
    }

    private func mergeIssuesWithCanonicalObservations(
        existingIssues: [IssueMetadata],
        observations: [Observation],
        sessionID: UUID,
        shots: [ShotMetadata],
        captureTimeZone: CaptureTimeZoneContext
    ) -> [IssueMetadata] {
        var byID: [UUID: IssueMetadata] = [:]
        for existing in existingIssues {
            byID[existing.issueID] = existing
        }

        let relevantShotIDs = Set(shots.compactMap(\.issueID))
        let relevantObservations = observations.filter { observation in
            relevantShotIDs.contains(observation.id) ||
            observation.sessionID == sessionID ||
            observation.updatedInSessionID == sessionID ||
            observation.resolvedInSessionID == sessionID
        }

        for observation in relevantObservations {
            let linkedShotKey = shots
                .filter { $0.issueID == observation.id }
                .sorted { $0.updatedAt > $1.updatedAt }
                .first?.shotKey
                ?? byID[observation.id]?.shotKey

            let lastCaptureSessionId = observation.resolvedInSessionID ?? observation.updatedInSessionID
            let exportedHistoryEvents = observation.historyEvents.map { exportHistoryEvent($0, observation: observation) }
            let issue = IssueMetadata(
                issueID: observation.id,
                issueStatus: observation.status == .resolved ? "resolved" : "active",
                currentReason: Observation.inferredCurrentReason(
                    note: observation.currentReason ?? observation.note,
                    statement: observation.statement
                ),
                previousReason: normalizedPreviousReason(
                    Observation.trimmedNonEmpty(observation.previousReason),
                    from: exportedHistoryEvents
                ) ?? latestPreviousReason(in: observation.historyEvents),
                firstSeenAt: observation.createdAt,
                firstSeenAtLocal: nil,
                lastSeenAt: observation.updatedAt,
                lastSeenAtLocal: nil,
                resolvedAt: observation.status == .resolved ? observation.updatedAt : nil,
                resolvedAtLocal: nil,
                lastCaptureSessionId: lastCaptureSessionId,
                detailNote: Observation.inferredCurrentReason(
                    note: observation.currentReason ?? observation.note,
                    statement: observation.statement
                ),
                shotKey: trimmedNonEmpty(linkedShotKey),
                historyEvents: exportedHistoryEvents
            )
            byID[observation.id] = issue
        }

        return byID.values
            .map { normalizeIssueMetadata($0, captureTimeZone: captureTimeZone) }
        .sorted(by: issueSortAscending)
    }

    private func exportHistoryEvent(_ event: ObservationHistoryEvent, observation: Observation) -> IssueHistoryEvent {
        var type: String
        switch event.kind {
        case .created:
            type = "created"
        case .captured:
            type = "captured"
        case .retake:
            type = "retake"
        case .reclassified:
            type = "reclassify"
        case .resolved:
            type = "resolve"
        case .reopened:
            type = "reopened"
        case .reasonUpdated:
            type = "reason_updated"
        case .titleUpdated:
            type = "title_updated"
        }

        var details: [String: String] = [:]
        if let field = trimmedNonEmpty(event.field) {
            details["field"] = field
        }
        if let before = trimmedNonEmpty(event.beforeValue) {
            details[event.kind == .reasonUpdated ? "oldReason" : "beforeValue"] = before
        }
        if let after = trimmedNonEmpty(event.afterValue) {
            details[event.kind == .reasonUpdated ? "newReason" : "afterValue"] = after
        }
        if let shotID = event.shotID?.uuidString {
            details["shotId"] = shotID
        }

        return IssueHistoryEvent(
            timestamp: event.timestamp,
            sessionId: event.sessionID,
            type: type,
            details: details
        )
    }

    private func normalizedPreviousReason(_ value: String?, from historyEvents: [IssueHistoryEvent]) -> String? {
        trimmedNonEmpty(value) ?? latestPreviousReason(in: historyEvents)
    }

    private func latestPreviousReason(in historyEvents: [IssueHistoryEvent]) -> String? {
        let latest = historyEvents
            .filter { $0.type == "reason_updated" }
            .sorted { lhs, rhs in
                if lhs.timestamp == rhs.timestamp {
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                return lhs.timestamp < rhs.timestamp
            }
            .last
        return trimmedNonEmpty(latest?.details["oldReason"])
    }

    private func latestPreviousReason(in historyEvents: [ObservationHistoryEvent]) -> String? {
        let latest = historyEvents
            .filter { $0.kind == .reasonUpdated }
            .sorted { lhs, rhs in
                if lhs.timestamp == rhs.timestamp {
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                return lhs.timestamp < rhs.timestamp
            }
            .last
        return trimmedNonEmpty(latest?.beforeValue)
    }

    private func issueSortAscending(_ lhs: IssueMetadata, _ rhs: IssueMetadata) -> Bool {
        let lhsDate = lhs.firstSeenAt ?? lhs.lastSeenAt ?? lhs.resolvedAt ?? Date.distantPast
        let rhsDate = rhs.firstSeenAt ?? rhs.lastSeenAt ?? rhs.resolvedAt ?? Date.distantPast
        if lhsDate == rhsDate {
            return lhs.issueID.uuidString < rhs.issueID.uuidString
        }
        return lhsDate < rhsDate
    }

    private func normalizedPropertyAddress(_ value: String?) -> String? {
        trimmedNonEmpty(value)
    }

    private func normalizedPropertyPhone(_ value: String?) -> String? {
        trimmedNonEmpty(value)
    }

    private func trimmedNonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func timeZoneOffsetString(secondsFromGMT: Int) -> String {
        let sign = secondsFromGMT >= 0 ? "+" : "-"
        let absolute = abs(secondsFromGMT)
        let hours = absolute / 3600
        let minutes = (absolute % 3600) / 60
        return String(format: "%@%02d:%02d", sign, hours, minutes)
    }

    private func timeZoneFromOffsetString(_ offset: String) -> TimeZone? {
        let trimmed = offset.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 6 else { return nil }
        let chars = Array(trimmed)
        guard (chars[0] == "+" || chars[0] == "-"), chars[3] == ":" else { return nil }
        let hourString = String(chars[1...2])
        let minuteString = String(chars[4...5])
        guard let hours = Int(hourString), let minutes = Int(minuteString) else { return nil }
        let multiplier = chars[0] == "-" ? -1 : 1
        let seconds = multiplier * ((hours * 3600) + (minutes * 60))
        return TimeZone(secondsFromGMT: seconds)
    }

    private struct CaptureTimeZoneContext {
        let identifier: String
        let timeZone: TimeZone
        let offsetMinutes: Int
        let offsetString: String
    }

    private func captureTimeZoneContext(for date: Date) -> CaptureTimeZoneContext {
        let timeZone = TimeZone.current
        let seconds = timeZone.secondsFromGMT(for: date)
        return CaptureTimeZoneContext(
            identifier: timeZone.identifier,
            timeZone: timeZone,
            offsetMinutes: seconds / 60,
            offsetString: timeZoneOffsetString(secondsFromGMT: seconds)
        )
    }

    private func captureTimeZoneContext(identifier: String, offsetString: String, offsetMinutes: Int?, for date: Date) -> CaptureTimeZoneContext {
        let trimmedIdentifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let preferredTimeZone = TimeZone(identifier: trimmedIdentifier)
        let resolvedTimeZone: TimeZone
        let resolvedOffsetMinutes: Int

        if let offsetMinutes {
            resolvedOffsetMinutes = offsetMinutes
            resolvedTimeZone = preferredTimeZone ?? TimeZone(secondsFromGMT: offsetMinutes * 60) ?? TimeZone.current
        } else if let fromOffset = timeZoneFromOffsetString(offsetString) {
            let seconds = fromOffset.secondsFromGMT()
            resolvedOffsetMinutes = seconds / 60
            resolvedTimeZone = preferredTimeZone ?? fromOffset
        } else if let preferredTimeZone {
            let seconds = preferredTimeZone.secondsFromGMT(for: date)
            resolvedOffsetMinutes = seconds / 60
            resolvedTimeZone = preferredTimeZone
        } else {
            let fallback = captureTimeZoneContext(for: date)
            return fallback
        }

        return CaptureTimeZoneContext(
            identifier: trimmedIdentifier.isEmpty ? resolvedTimeZone.identifier : trimmedIdentifier,
            timeZone: resolvedTimeZone,
            offsetMinutes: resolvedOffsetMinutes,
            offsetString: timeZoneOffsetString(secondsFromGMT: resolvedOffsetMinutes * 60)
        )
    }

    private func localISO8601String(for date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        let rendered = formatter.string(from: date)
        if rendered.hasSuffix("Z") {
            return String(rendered.dropLast()) + "+00:00"
        }
        return rendered
    }

    private func normalizeExifOrientation(rawValue: Int?, legacy: String?) -> Int? {
        if let rawValue, (1...8).contains(rawValue) {
            return rawValue
        }
        let trimmed = legacy?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let direct = Int(trimmed), (1...8).contains(direct) {
            return direct
        }
        let prefix = "exif:"
        if trimmed.lowercased().hasPrefix(prefix),
           let parsed = Int(trimmed.dropFirst(prefix.count)),
           (1...8).contains(parsed) {
            return parsed
        }
        return nil
    }

    private func hasLegacyElevationValues(in fileURL: URL) throws -> Bool {
        guard fileManager.fileExists(atPath: fileURL.path) else { return false }
        let data = try Data(contentsOf: fileURL)
        guard !data.isEmpty else { return false }
        guard let text = String(data: data, encoding: .utf8) else { return false }
        return text.range(
            of: #""targetElevation"\s*:\s*"(North|South|East|West)\s+Elevation""#,
            options: .regularExpression
        ) != nil
    }
}

extension LocalStore {
    func printSessionSchema() {
        let sampleSession = SessionMetadata(
            schemaVersion: 5,
            propertyID: UUID(),
            sessionID: UUID(),
            propertyNameAtCapture: nil,
            propertyNameAtExport: nil,
            startedAt: Date(),
            endedAt: nil,
            status: .draft,
            isBaselineSession: false,
            exportedAt: nil,
            appVersion: "debug",
            deviceModel: "debug",
            osVersion: "debug",
            shots: [],
            issues: []
        )

        let sampleShot = ShotMetadata(
            shotID: UUID(),
            propertyID: UUID(),
            sessionID: UUID(),
            createdAt: Date(),
            updatedAt: Date(),
            building: "",
            elevation: "",
            detailType: "",
            angleIndex: 1,
            shotKey: "",
            isGuided: false,
            isFlagged: false,
            issueID: nil,
            issueStatus: nil,
            noteText: nil,
            noteCategory: nil,
            originalFilename: "",
            originalRelativePath: "",
            originalByteSize: nil,
            storageBucket: nil,
            storagePath: nil,
            checksumSHA256: nil,
            byteSize: nil,
            uploadState: "pending",
            uploadAttempts: 0,
            lastUploadError: nil,
            stampedFilename: nil,
            stampedRelativePath: nil,
            captureMode: nil,
            lens: nil,
            exifOrientation: nil,
            orientation: nil,
            latitude: nil,
            longitude: nil,
            accuracyMeters: nil,
            imageWidth: nil,
            imageHeight: nil
        )

        print("---- SessionMetadata Fields ----")
        for child in Mirror(reflecting: sampleSession).children {
            if let label = child.label {
                print(label)
            }
        }

        print("")
        print("---- ShotMetadata Fields ----")
        for child in Mirror(reflecting: sampleShot).children {
            if let label = child.label {
                print(label)
            }
        }
    }
}
