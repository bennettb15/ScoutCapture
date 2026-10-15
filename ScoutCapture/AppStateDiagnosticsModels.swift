import Foundation

extension AppState {
    enum SessionSnapshotRestoreDiagnosticOutcome: String, Codable, Equatable, CaseIterable {
        case restorableMetadataCandidate = "restorable_metadata_candidate"
        case noSnapshotFound = "no_snapshot_found"
        case checksumFailed = "checksum_failed"
        case objectMissing = "object_missing"
        case parentMismatch = "parent_mismatch"
        case staleSnapshot = "stale_snapshot"
        case localNewerConflict = "local_newer_conflict"
        case unsupportedSchema = "unsupported_schema"
        case unableToVerify = "unable_to_verify"
    }

    struct SessionSnapshotRestoreDiagnosticsResult: Equatable {
        var checkedAt: Date
        var propertyID: UUID?
        var sessionID: UUID?
        var snapshotID: UUID?
        var result: SessionSnapshotRestoreDiagnosticOutcome
        var failureReason: String?
        var rowFound: Bool
        var objectReadable: Bool
        var checksumVerified: Bool
        var byteSizeMatches: Bool
        var rowObjectVerified: Bool
        var parentRemoteVerified: Bool
        var snapshotSchemaVersion: Int?
        var snapshotCreatedAt: Date?
        var snapshotGeneratedAt: Date?
        var localKnownStateAt: Date? = nil
        var localKnownStateSource: String? = nil
        var localSessionExists: Bool
        var localSessionStatus: String?
        var localShotCount: Int?
        var localIssueCount: Int?
        var localGuidedCount: Int?
        var snapshotShotCount: Int?
        var snapshotIssueCount: Int?
        var snapshotGuidedCount: Int?
        var snapshotMediaManifestCount: Int?
        var snapshotMissingLocalOriginalsCount: Int?
        var snapshotSupabaseStorageMetadataCount: Int?
        var freshness: String
        var mediaRecoveryDiagnostics: SessionSnapshotMediaRecoveryDiagnostics
    }

    enum SessionSnapshotMediaRecoveryState: String, Codable, Equatable, CaseIterable {
        case recoverableFromSupabaseStorage = "recoverable_from_supabase_storage"
        case recoverableFromLocalCache = "recoverable_from_local_cache"
        case missingRemoteStorageMetadata = "missing_remote_storage_metadata"
        case missingLocalFile = "missing_local_file"
        case missingBoth = "missing_both"
        case checksumUnknown = "checksum_unknown"
        case checksumMismatch = "checksum_mismatch"
        case unsupportedMediaManifest = "unsupported_media_manifest"
        case notChecked = "not_checked"
    }

    enum SessionSnapshotMediaRecoveryPlanningState: String, Codable, Equatable, CaseIterable {
        case fullyRecoverable = "fully_recoverable"
        case partiallyRecoverable = "partially_recoverable"
        case metadataOnly = "metadata_only"
        case remoteOnly = "remote_only"
        case localOnly = "local_only"
        case unrecoverable = "unrecoverable"
    }

    enum SessionSnapshotMediaRecoverySource: String, Codable, Equatable, CaseIterable {
        case localCache = "local_cache"
        case iCloudLocalBackup = "icloud_local_backup"
        case supabaseStorage = "supabase_storage"
        case exportArchives = "export_archives"

        nonisolated static var defaultPriority: [SessionSnapshotMediaRecoverySource] {
            [
                .localCache,
                .iCloudLocalBackup,
                .supabaseStorage,
                .exportArchives
            ]
        }
    }

    struct SessionSnapshotMediaRetrievalPolicyDiagnostics: Equatable {
        let mode: String
        let allowlistMode: String
        let productionWideRetrievalAllowed: Bool
        let maxBatchSize: Int
        let storageQuotaAwarenessRequired: Bool
        let networkRequirement: String
        let batteryRequirement: String
        let checksumValidationRequired: Bool
        let duplicatePreventionRequired: Bool
        let partialFailureHandling: String
        let trustModel: String
        let rolloutPhase: String
        let canStartRetrieval: Bool
        let blockedReasons: [String]

        nonisolated static var guardrailsOnly: SessionSnapshotMediaRetrievalPolicyDiagnostics {
            SessionSnapshotMediaRetrievalPolicyDiagnostics(
                mode: "manual_only",
                allowlistMode: "allowlisted_test_only_first",
                productionWideRetrievalAllowed: false,
                maxBatchSize: 25,
                storageQuotaAwarenessRequired: true,
                networkRequirement: "unmetered_or_operator_approved",
                batteryRequirement: "charging_or_sufficient_battery",
                checksumValidationRequired: true,
                duplicatePreventionRequired: true,
                partialFailureHandling: "per_item_report_continue_safe_items",
                trustModel: "checksum_required_before_accept_storage_metadata_is_locator_only",
                rolloutPhase: "26C_test_only_media_retrieval",
                canStartRetrieval: false,
                blockedReasons: [
                    "manual_operator_confirmation_required",
                    "production_wide_retrieval_blocked"
                ]
            )
        }
    }

    struct SessionSnapshotMediaRecoveryItemDiagnostic: Equatable, Identifiable {
        let id: UUID
        let state: SessionSnapshotMediaRecoveryState
        let localReferencePresent: Bool
        let localFilePresent: Bool
        let remoteStorageMetadataPresent: Bool
        let checksumPresent: Bool
        let checksumVerified: Bool
    }

    struct SessionSnapshotMediaRecoveryDiagnostics: Equatable {
        var checkedAt: Date?
        var readiness: String
        var planningState: SessionSnapshotMediaRecoveryPlanningState
        var sourcePriority: [SessionSnapshotMediaRecoverySource]
        var retrievalPolicy: SessionSnapshotMediaRetrievalPolicyDiagnostics
        var manifestSupported: Bool
        var manifestCount: Int
        var originalsCount: Int
        var localFilesPresentCount: Int
        var remoteStorageMetadataPresentCount: Int
        var recoverableRemoteCount: Int
        var recoverableLocalCount: Int
        var missingCount: Int
        var missingRemoteStorageMetadataCount: Int
        var missingLocalFileCount: Int
        var checksumVerifiedCount: Int
        var checksumUnknownCount: Int
        var checksumMismatchCount: Int
        var unsupportedCount: Int
        var notCheckedCount: Int
        var stateCounts: [SessionSnapshotMediaRecoveryState: Int]
        var items: [SessionSnapshotMediaRecoveryItemDiagnostic]

        static let notChecked = SessionSnapshotMediaRecoveryDiagnostics(
            checkedAt: nil,
            readiness: SessionSnapshotMediaRecoveryState.notChecked.rawValue,
            planningState: .unrecoverable,
            sourcePriority: SessionSnapshotMediaRecoverySource.defaultPriority,
            retrievalPolicy: .guardrailsOnly,
            manifestSupported: false,
            manifestCount: 0,
            originalsCount: 0,
            localFilesPresentCount: 0,
            remoteStorageMetadataPresentCount: 0,
            recoverableRemoteCount: 0,
            recoverableLocalCount: 0,
            missingCount: 0,
            missingRemoteStorageMetadataCount: 0,
            missingLocalFileCount: 0,
            checksumVerifiedCount: 0,
            checksumUnknownCount: 0,
            checksumMismatchCount: 0,
            unsupportedCount: 0,
            notCheckedCount: 0,
            stateCounts: [:],
            items: []
        )
    }

    struct SessionSnapshotHydrationResult: Equatable {
        var hydratedAt: Date
        var allowed: Bool
        var blockedReason: String?
        var sourceSnapshotID: UUID?
        var propertyID: UUID?
        var sessionID: UUID?
        var hydratedShotCount: Int
        var hydratedIssueCount: Int
        var hydratedGuidedCount: Int
    }

    struct SessionSnapshotHydrationPolicyDiagnostics: Equatable {
        var hydrationAvailable: Bool
        var productionHydrationAllowed: Bool
        var hydrationMode: String
        var hydrationScope: String
        var productionHydrationBlockedReason: String?
    }

    struct SessionSnapshotHydrationConfirmation: Equatable {
        var confirmationRequired: Bool
        var canHydrate: Bool
        var blockedReason: String?
        var propertyIDText: String
        var sessionIDText: String
        var snapshotIDText: String
        var restoreResult: String
        var shotCountText: String
        var issueCountText: String
        var guidedCountText: String
        var messageText: String
    }

    struct SessionSnapshotMediaRetrievalConfirmation: Equatable {
        var confirmationRequired: Bool
        var canRetrieve: Bool
        var blockedReason: String?
        var propertyIDText: String
        var sessionIDText: String
        var snapshotIDText: String
        var mediaCount: Int
        var maxBatchSize: Int
        var messageText: String
    }

    enum SessionSnapshotMediaRetrievalItemStatus: String, Codable, Equatable {
        case downloaded
        case skippedExisting = "skipped_existing"
        case skippedMissingStorageMetadata = "skipped_missing_storage_metadata"
        case skippedChecksumMissing = "skipped_checksum_missing"
        case rejectedChecksumMismatch = "rejected_checksum_mismatch"
        case failed
    }

    struct SessionSnapshotMediaRetrievalItemResult: Equatable, Identifiable {
        let id: UUID
        let status: SessionSnapshotMediaRetrievalItemStatus
        let checksumVerified: Bool
        let recoveredLocalPathPresent: Bool
        let failureReason: String?
    }

    struct SessionSnapshotMediaRetrievalResult: Equatable {
        let retrievedAt: Date
        let allowed: Bool
        let blockedReason: String?
        let propertyID: UUID?
        let sessionID: UUID?
        let snapshotID: UUID?
        let attemptedCount: Int
        let downloadedCount: Int
        let checksumVerifiedCount: Int
        let skippedExistingCount: Int
        let failedCount: Int
        let recoveredLocalPathCount: Int
        let recoveredMediaDirectoryPathPresent: Bool
        let items: [SessionSnapshotMediaRetrievalItemResult]
    }


    enum SnapshotRecoveryCohortCategory: String, Codable, Equatable, CaseIterable {
        case completedSealedSession = "completed_sealed_session"
        case draftSession = "draft_session"
        case highVolumeMetadata = "many_shots_issues_guided_items"
        case noMediaManifest = "no_media_manifest"
        case localNewerConflict = "local_newer_conflict"
        case missingLocalMetadata = "missing_local_metadata"
        case orgDriftHistory = "org_drift_history"
        case staleSnapshot = "stale_snapshot"
        case noSnapshotFound = "no_snapshot_found"
        case blockedVerification = "blocked_verification"
        case unknown = "unknown"
    }

    enum SnapshotRecoveryReadiness: String, Codable, Equatable, CaseIterable {
        case readyForManualHydration = "ready_for_manual_hydration"
        case needsReview = "needs_review"
        case blocked = "blocked"
        case notChecked = "not_checked"
    }

    enum SnapshotRestoreRiskLevel: String, Codable, Equatable, CaseIterable {
        case low
        case medium
        case high
        case blocking
        case unknown
    }

    struct SnapshotRecoveryCohortResult: Equatable {
        var checkedAt: Date
        var propertyID: UUID?
        var sessionID: UUID?
        var snapshotID: UUID?
        var category: SnapshotRecoveryCohortCategory
        var readiness: SnapshotRecoveryReadiness
        var riskLevel: SnapshotRestoreRiskLevel
        var snapshotFreshnessAgeSeconds: TimeInterval?
        var hydrationEligibilityReason: String
        var latestSnapshotCovered: Bool
        var restoreDiagnosticsResult: String
    }

    enum SessionSnapshotUploadError: LocalizedError, Equatable {
        case disabled
        case missingSupabaseClient
        case missingOrgID
        case notPreviewable(String)
        case remoteUnavailable(String)

        var errorDescription: String? {
            switch self {
            case .disabled:
                return "Session snapshot shadow-write is disabled."
            case .missingSupabaseClient:
                return "Supabase client is unavailable for session snapshot upload."
            case .missingOrgID:
                return "Session snapshot upload requires an org_id."
            case .notPreviewable(let reason):
                return "Session snapshot is not previewable: \(reason)"
            case .remoteUnavailable(let reason):
                return "Session snapshot remote table or bucket is unavailable: \(reason)"
            }
        }
    }
    struct CaptureProfileMaintenanceBackfillResult: Equatable {
        var localPropertiesFound: Int = 0
        var propertiesScanned: Int = 0
        var sessionsScanned: Int = 0
        var remotePropertiesChecked: Int = 0
        var remoteSessionsChecked: Int = 0
        var remoteActivePropertyCount: Int = 0
        var propertyProfilesFilled: Int = 0
        var sessionProfilesFilled: Int = 0
        var sessionsEnsured: Int = 0
        var skipped: Int = 0
        var failed: Int = 0
        var staleOrgReconciledCount: Int = 0
        var trueOrgMismatchCount: Int = 0
        var propertiesFilteredDeleted: Int = 0
        var propertiesFilteredArchived: Int = 0
        var propertiesFilteredOrgMismatch: Int = 0
        var propertiesFilteredInaccessible: Int = 0
        var sessionMetadataMissing: Int = 0
        var sessionProfileUnknown: Int = 0
    }

    enum DiagnosticErrorCategory: String, Equatable {
        case authOrRLS = "auth_or_rls"
        case network
        case conflict
        case duplicate
        case localIO = "local_io"
        case unknown
    }

    struct DiagnosticErrorSnapshot: Equatable {
        let category: DiagnosticErrorCategory
        let message: String
        let recordedAt: Date
    }

    struct OfflineReplayDiagnostics: Equatable {
        var discoveredCount: Int = 0
        var attemptedCount: Int = 0
        var succeededCount: Int = 0
        var failedCount: Int = 0
        var skippedBackoffCount: Int = 0
        var normalizedInFlightCount: Int = 0
        var lastRunAt: Date?
    }

    struct OfflineQueueDiagnostics: Equatable {
        var totalQueued: Int = 0
        var pendingCount: Int = 0
        var failedCount: Int = 0
        var acknowledgedHistoricalCount: Int = 0
        var oldestFailureAgeSeconds: TimeInterval?
        var refreshedAt: Date?
    }

    struct MediaDiagnostics: Equatable {
        var lastBackfillDiscoveredCount: Int = 0
        var lastBackfillAttemptedCount: Int = 0
        var lastBackfillSkippedRetryCapCount: Int = 0
        var uploadSuccessCount: Int = 0
        var uploadFailureCount: Int = 0
        var pendingLocalMediaCount: Int?
        var lastBackfillAt: Date?
    }

    struct ShadowWriteEntityDiagnostics: Equatable {
        var successCount: Int = 0
        var failureCount: Int = 0
    }

    struct ShadowWriteDiagnostics: Equatable {
        var property = ShadowWriteEntityDiagnostics()
        var session = ShadowWriteEntityDiagnostics()
        var shotMetadata = ShadowWriteEntityDiagnostics()
        var captureProfile = ShadowWriteEntityDiagnostics()
    }

    struct SessionSnapshotUploadDiagnostics: Equatable {
        var flagEnabled: Bool = false
        var autoUploadFlagEnabled: Bool = false
        var autoUploadKillSwitchActive: Bool = false
        var autoUploadAllowlistMatch: Bool = false
        var autoUploadSkippedReason: String?
        var autoUploadTriggerSource: String?
        var lastAutoAttemptAt: Date?
        var lastAutoSuccessAt: Date?
        var lastAutoFailureAt: Date?
        var lastAutoFailureMessage: String?
        var lastAutoPropertyID: UUID?
        var lastAutoSessionID: UUID?
        var lastAutoSnapshotID: UUID?
        var lastAutoUploadPath: String?
        var lastAutoUploadOutcome: String = "not_attempted"
        var lastDraftReuseDecisionAt: Date?
        var lastDraftReusePropertyID: UUID?
        var lastDraftReuseSessionID: UUID?
        var lastDraftReuseDecision: String = "not_checked"
        var lastDraftReuseCandidateCount: Int = 0
        var lastDraftReuseBlockedReason: String?
        var lastDraftDuplicateDetected: Bool = false
        var lastDraftForegroundRefreshReconciliation: String = "not_checked"
        var lastOrgPersistenceRepairAt: Date?
        var lastOrgPersistencePropertyID: UUID?
        var lastOrgPersistencePersistedOrgID: UUID?
        var lastOrgPersistenceRuntimeOrgID: UUID?
        var lastOrgPersistenceCanonicalSupabaseOrgID: UUID?
        var lastOrgPersistenceMatch: Bool?
        var lastOrgPersistenceRepairResult: String = "not_checked"
        var remoteAvailability: String = "not_checked"
        var attemptedCount: Int = 0
        var successCount: Int = 0
        var failureCount: Int = 0
        var orphanRiskCount: Int = 0
        var lastAttemptAt: Date?
        var lastSuccessAt: Date?
        var lastFailureAt: Date?
        var lastFailureMessage: String?
        var lastSnapshotID: UUID?
        var lastPropertyID: UUID?
        var lastSessionID: UUID?
        var lastUploadPath: String?
        var lastStorageUploadCompleted: Bool = false
        var lastRowInsertCompleted: Bool = false
        var lastUploadOutcome: String = "not_attempted"
        var lastUploadErrorMessage: String?
        var lastKind: String?
        var lastTrigger: String?
        var lastAuthPreflightAt: Date?
        var lastAuthPreflightAppUserID: String?
        var lastAuthPreflightClientUserID: String?
        var lastAuthPreflightUsersMatch: Bool?
        var lastAuthPreflightPayloadOrgID: UUID?
        var lastAuthPreflightPayloadPropertyID: UUID?
        var lastAuthPreflightPayloadSessionID: UUID?
        var lastAuthPreflightRemotePropertyExists: Bool?
        var lastAuthPreflightRemoteSessionExists: Bool?
        var lastAuthPreflightRemotePropertyOrgID: UUID?
        var lastAuthPreflightRemoteSessionOrgID: UUID?
        var lastAuthPreflightRemoteSessionPropertyMatches: Bool?
        var lastAuthPreflightRemoteOrgIDsMatch: Bool?
        var lastAuthPreflightReady: Bool?
        var lastAuthPreflightFailureMessage: String?
        var lastLocalOrgRepairAt: Date?
        var lastLocalOrgRepairOutcome: String = "not_attempted"
        var lastLocalOrgRepairPropertyID: UUID?
        var lastLocalOrgRepairSessionID: UUID?
        var lastLocalOrgRepairPreviousOrgID: UUID?
        var lastLocalOrgRepairCanonicalOrgID: UUID?
        var lastLocalOrgRepairMessage: String?
        var lastLocalOrgDriftAuditAt: Date?
        var lastLocalOrgDriftAuditPropertiesChecked: Int = 0
        var lastLocalOrgDriftAuditSessionsChecked: Int = 0
        var lastLocalOrgDriftAuditPropertyMismatchCount: Int = 0
        var lastLocalOrgDriftAuditSessionMismatchCount: Int = 0
        var lastLocalOrgDriftAuditUnableToConfirmCount: Int = 0
        var lastLocalOrgDriftAuditSamples: [String] = []
        var lastLocalOrgDriftRepairAt: Date?
        var lastLocalOrgDriftRepairAttemptedCount: Int = 0
        var lastLocalOrgDriftRepairPropertyCount: Int = 0
        var lastLocalOrgDriftRepairSessionCount: Int = 0
        var lastLocalOrgDriftRepairSkippedCount: Int = 0
        var lastLocalOrgDriftRepairFailureCount: Int = 0
        var lastLocalOrgDriftRepairSamples: [String] = []
        var lastReadbackAt: Date?
        var lastReadbackStatus: String = "not_checked"
        var lastReadbackSnapshotID: UUID?
        var lastReadbackRowFound: Bool = false
        var lastReadbackPayloadReadable: Bool = false
        var lastReadbackChecksumVerified: Bool = false
        var lastReadbackRowObjectConsistent: Bool = false
        var lastReadbackPayloadByteSize: Int?
        var lastReadbackSnapshotCreatedAt: Date?
        var lastReadbackFailureMessage: String?
        var lastRestoreDiagnosticsAt: Date?
        var lastRestoreDiagnosticsResult: String = "not_checked"
        var lastRestoreDiagnosticsFailureReason: String?
        var lastRestoreDiagnosticsPropertyID: UUID?
        var lastRestoreDiagnosticsSessionID: UUID?
        var lastRestoreDiagnosticsSnapshotID: UUID?
        var lastRestoreDiagnosticsRowFound: Bool = false
        var lastRestoreDiagnosticsObjectReadable: Bool = false
        var lastRestoreDiagnosticsChecksumVerified: Bool = false
        var lastRestoreDiagnosticsByteSizeMatches: Bool = false
        var lastRestoreDiagnosticsRowObjectVerified: Bool = false
        var lastRestoreDiagnosticsParentRemoteVerified: Bool = false
        var lastRestoreDiagnosticsSnapshotSchemaVersion: Int?
        var lastRestoreDiagnosticsSnapshotCreatedAt: Date?
        var lastRestoreDiagnosticsSnapshotGeneratedAt: Date?
        var lastRestoreDiagnosticsLocalKnownStateAt: Date?
        var lastRestoreDiagnosticsLocalKnownStateSource: String?
        var lastRestoreDiagnosticsLocalSessionExists: Bool = false
        var lastRestoreDiagnosticsLocalSessionStatus: String?
        var lastRestoreDiagnosticsLocalShotCount: Int?
        var lastRestoreDiagnosticsLocalIssueCount: Int?
        var lastRestoreDiagnosticsLocalGuidedCount: Int?
        var lastRestoreDiagnosticsSnapshotShotCount: Int?
        var lastRestoreDiagnosticsSnapshotIssueCount: Int?
        var lastRestoreDiagnosticsSnapshotGuidedCount: Int?
        var lastRestoreDiagnosticsSnapshotMediaManifestCount: Int?
        var lastRestoreDiagnosticsSnapshotMissingLocalOriginalsCount: Int?
        var lastRestoreDiagnosticsSnapshotSupabaseStorageMetadataCount: Int?
        var lastRestoreDiagnosticsFreshness: String = "not_checked"
        var lastRestoreDiagnosticsMediaRecoveryReadiness: String = SessionSnapshotMediaRecoveryState.notChecked.rawValue
        var lastRestoreDiagnosticsMediaRecoveryPlanningState: String = SessionSnapshotMediaRecoveryPlanningState.unrecoverable.rawValue
        var lastRestoreDiagnosticsMediaRecoverySourcePriority: [String] = SessionSnapshotMediaRecoverySource.defaultPriority.map(\.rawValue)
        var lastRestoreDiagnosticsMediaRetrievalMode: String = SessionSnapshotMediaRetrievalPolicyDiagnostics.guardrailsOnly.mode
        var lastRestoreDiagnosticsMediaRetrievalAllowlistMode: String = SessionSnapshotMediaRetrievalPolicyDiagnostics.guardrailsOnly.allowlistMode
        var lastRestoreDiagnosticsMediaProductionWideRetrievalAllowed: Bool = false
        var lastRestoreDiagnosticsMediaRetrievalMaxBatchSize: Int = SessionSnapshotMediaRetrievalPolicyDiagnostics.guardrailsOnly.maxBatchSize
        var lastRestoreDiagnosticsMediaRetrievalStorageQuotaRequired: Bool = true
        var lastRestoreDiagnosticsMediaRetrievalNetworkRequirement: String = SessionSnapshotMediaRetrievalPolicyDiagnostics.guardrailsOnly.networkRequirement
        var lastRestoreDiagnosticsMediaRetrievalBatteryRequirement: String = SessionSnapshotMediaRetrievalPolicyDiagnostics.guardrailsOnly.batteryRequirement
        var lastRestoreDiagnosticsMediaRetrievalChecksumRequired: Bool = true
        var lastRestoreDiagnosticsMediaRetrievalDuplicatePreventionRequired: Bool = true
        var lastRestoreDiagnosticsMediaRetrievalPartialFailureHandling: String = SessionSnapshotMediaRetrievalPolicyDiagnostics.guardrailsOnly.partialFailureHandling
        var lastRestoreDiagnosticsMediaRetrievalTrustModel: String = SessionSnapshotMediaRetrievalPolicyDiagnostics.guardrailsOnly.trustModel
        var lastRestoreDiagnosticsMediaRetrievalRolloutPhase: String = SessionSnapshotMediaRetrievalPolicyDiagnostics.guardrailsOnly.rolloutPhase
        var lastRestoreDiagnosticsMediaRetrievalCanStart: Bool = false
        var lastRestoreDiagnosticsMediaRetrievalBlockedReasons: [String] = SessionSnapshotMediaRetrievalPolicyDiagnostics.guardrailsOnly.blockedReasons
        var lastRestoreDiagnosticsMediaManifestSupported: Bool = false
        var lastRestoreDiagnosticsMediaManifestCount: Int = 0
        var lastRestoreDiagnosticsMediaOriginalsCount: Int = 0
        var lastRestoreDiagnosticsMediaLocalFilesPresentCount: Int = 0
        var lastRestoreDiagnosticsMediaRemoteStorageMetadataPresentCount: Int = 0
        var lastRestoreDiagnosticsMediaRecoverableRemoteCount: Int = 0
        var lastRestoreDiagnosticsMediaRecoverableLocalCount: Int = 0
        var lastRestoreDiagnosticsMediaMissingCount: Int = 0
        var lastRestoreDiagnosticsMediaMissingRemoteStorageMetadataCount: Int = 0
        var lastRestoreDiagnosticsMediaMissingLocalFileCount: Int = 0
        var lastRestoreDiagnosticsMediaChecksumVerifiedCount: Int = 0
        var lastRestoreDiagnosticsMediaChecksumUnknownCount: Int = 0
        var lastRestoreDiagnosticsMediaChecksumMismatchCount: Int = 0
        var lastRestoreDiagnosticsMediaUnsupportedCount: Int = 0
        var lastRestoreDiagnosticsMediaNotCheckedCount: Int = 0
        var lastRestoreDiagnosticsMediaStateCounts: [String] = []
        var lastMediaRetrievalAt: Date?
        var lastMediaRetrievalAllowed: Bool = false
        var lastMediaRetrievalBlockedReason: String?
        var lastMediaRetrievalPropertyID: UUID?
        var lastMediaRetrievalSessionID: UUID?
        var lastMediaRetrievalSnapshotID: UUID?
        var lastMediaRetrievalAttemptedCount: Int = 0
        var lastMediaRetrievalDownloadedCount: Int = 0
        var lastMediaRetrievalChecksumVerifiedCount: Int = 0
        var lastMediaRetrievalSkippedExistingCount: Int = 0
        var lastMediaRetrievalFailedCount: Int = 0
        var lastMediaRetrievalRecoveredLocalPathCount: Int = 0
        var lastMediaRetrievalRecoveredDirectoryPathPresent: Bool = false
        var lastHydrationAt: Date?
        var lastHydrationAllowed: Bool = false
        var lastHydrationBlockedReason: String?
        var lastHydrationSourceSnapshotID: UUID?
        var lastHydrationPropertyID: UUID?
        var lastHydrationSessionID: UUID?
        var lastHydrationShotCount: Int = 0
        var lastHydrationIssueCount: Int = 0
        var lastHydrationGuidedCount: Int = 0
        var productionHydrationAllowed: Bool = false
        var hydrationMode: String = "blocked_by_default"
        var hydrationScope: String = "none"
        var productionHydrationBlockedReason: String = "production_hydration_gate_disabled"
        var lastRecoveryCohortAt: Date?
        var lastRecoveryCohortCategory: String = SnapshotRecoveryCohortCategory.unknown.rawValue
        var lastRecoveryReadiness: String = SnapshotRecoveryReadiness.notChecked.rawValue
        var lastRecoveryRiskLevel: String = SnapshotRestoreRiskLevel.unknown.rawValue
        var lastRecoverySnapshotFreshnessAgeSeconds: TimeInterval?
        var lastRecoveryHydrationEligibilityReason: String = "not_checked"
        var lastRecoveryLatestSnapshotCovered: Bool = false
        var lastRecoveryRestoreDiagnosticsResult: String = "not_checked"
        var lastCanonicalReadDiagnosticsAt: Date?
        var lastCanonicalReadDiagnosticsVerifiedOrgID: UUID?
        var lastCanonicalReadDiagnosticsPropertyID: UUID?
        var lastCanonicalReadDiagnosticsSessionID: UUID?
        var lastCanonicalReadDiagnosticsResult: String = CanonicalReadDiagnosticResult.localOnly.rawValue
        var lastCanonicalReadDiagnosticsRemotePropertyFound: Bool = false
        var lastCanonicalReadDiagnosticsRemoteSessionFound: Bool = false
        var lastCanonicalReadDiagnosticsLocalPropertyFound: Bool = false
        var lastCanonicalReadDiagnosticsLocalSessionFound: Bool = false
        var lastCanonicalReadDiagnosticsCountParity: Bool?
        var lastCanonicalReadDiagnosticsStatusParity: Bool?
        var lastCanonicalReadDiagnosticsParentOrgConsistent: Bool?
        var lastCanonicalReadDiagnosticsParentPropertyConsistent: Bool?
        var lastCanonicalReadDiagnosticsLocalShotCount: Int?
        var lastCanonicalReadDiagnosticsRemoteShotCount: Int?
        var lastCanonicalReadDiagnosticsLocalIssueObservationCount: Int?
        var lastCanonicalReadDiagnosticsRemoteIssueObservationCount: Int?
        var lastCanonicalReadDiagnosticsLocalGuidedCount: Int?
        var lastCanonicalReadDiagnosticsRemoteGuidedCount: Int?
        var lastCanonicalReadDiagnosticsLocalKnownStateAt: Date?
        var lastCanonicalReadDiagnosticsLocalKnownStateSource: String?
        var lastCanonicalReadDiagnosticsRemoteFreshnessAgeSeconds: TimeInterval?
        var lastCanonicalReadDiagnosticsRemoteRevision: Int64?
        var lastCanonicalReadDiagnosticsRecommendation: String = "local_first"
        var lastCanonicalReadDiagnosticsBlockedReason: String?
        var lastNormalizedParityGapTaxonomy: [String] = []
        var lastNormalizedParityCompleteness: String = "not_checked"
        var lastRemoteShadowWriteCoverage: String = "not_checked"
        var lastMissingRemoteEntityClassification: String = "not_checked"
        var lastLineageDivergenceSource: String = "not_checked"
        var lastParityRepairToolingRecommended: Bool = false
        var lastCanonicalReadsRemainBlocked: Bool = true
        var lastCanonicalReadRolloutBlockers: [String] = []
        var lastCanonicalReadPrerequisitesBeforeAllowlist: [String] = []
        var lastCanonicalReadProbableCauses: [String] = []
        var lastParityRepairStrategies: [String] = []
        var lastParityRepairSafetyRules: [String] = []
        var lastParityDiagnosticsBeforeRepair: [String] = []
        var lastParityCompletenessScore: Double = 0
        var lastShadowWriteCoverageScore: Double = 0
        var lastLineageConfidence: String = "not_checked"
        var lastMissingChildCount: Int = 0
        var lastReplayEligibility: String = "not_checked"
        var lastParityRepairRolloutPhase: String = "diagnostics_only"
        var lastNormalizedBackfillEligible: Bool = false
        var lastNormalizedBackfillBlockedReason: String = "not_checked"
        var lastNormalizedBackfillPlannedSessionUpserts: Int = 0
        var lastNormalizedBackfillPlannedShotUpserts: Int = 0
        var lastNormalizedBackfillPlannedObservationUpserts: Int = 0
        var lastNormalizedBackfillExecutedEntityCount: Int = 0
        var lastNormalizedBackfillSkippedEntityCount: Int = 0
        var lastNormalizedBackfillRemoteNewerConflictCount: Int = 0
        var lastNormalizedBackfillProductionBlocked: Bool = true
        var lastSelectedSessionLifecycleReplaySucceeded: Bool = false
        var lastSelectedSessionLifecycleReplayOrgID: UUID?
        var lastSelectedSessionLifecycleReplayPropertyID: UUID?
        var lastSelectedSessionLifecycleReplaySessionID: UUID?
        var lastSelectedSessionLifecycleReplayExecutedEntityCount: Int = 0
        var lastSelectedSessionLifecycleReplayFailedEntityCount: Int = 0
        var lastSelectedSessionLifecycleReplayRemoteNewerConflictCount: Int = 0
        var lastCanonicalReadCandidateAllowed: Bool = false
        var lastCanonicalReadCandidateBlockedReason: String = "not_checked"
        var lastCanonicalReadCandidateEffectiveSourceRecommendation: String = "local_first"
        var lastCanonicalReadCandidateLocalFallbackAvailable: Bool = true
        var lastCanonicalReadCandidateParityConfidence: Double = 0
        var lastCanonicalReadCandidateReplayConfidence: Double = 0
        var lastCanonicalReadCandidateMediaRecoveryConfidence: Double = 0
        var lastCanonicalReadCandidateRemoteStateReadable: Bool = false
        var lastCanonicalReadCandidateFlagEnabled: Bool = false
        var lastCanonicalReadCandidateOrgAllowlisted: Bool = false
        var lastCanonicalReadCandidatePropertyAllowlisted: Bool = false
        var lastCanonicalReadCandidateSessionAllowlisted: Bool = false
        var lastCanonicalReadCandidateProductionWideEnabled: Bool = false
        var lastCanonicalReadCandidateWarnings: [String] = []
        var lastCanonicalCandidateOverlayBuilt: Bool = false
        var lastCanonicalCandidateOverlayAllowed: Bool = false
        var lastCanonicalCandidateOverlayBlockedReason: String = "not_checked"
        var lastCanonicalCandidateOverlaySource: String = "not_built"
        var lastCanonicalCandidateOverlayPropertyID: UUID?
        var lastCanonicalCandidateOverlaySessionID: UUID?
        var lastCanonicalCandidateOverlayShotCount: Int = 0
        var lastCanonicalCandidateOverlayIssueObservationCount: Int = 0
        var lastCanonicalCandidateOverlayGuidedCount: Int?
        var lastCanonicalCandidateOverlayFallbackSource: String = "local"
        var lastCanonicalCandidateOverlayActiveSource: String = "local"
        var lastCanonicalCandidateOverlayRollbackAvailable: Bool = true
        var lastCanonicalCandidateOverlayProductionBlocked: Bool = true
        var lastCanonicalCandidateOverlayComparisonResult: String = "candidate_unavailable"
        var lastCanonicalCandidateOverlayComparisonLocalStatus: String = "unknown"
        var lastCanonicalCandidateOverlayComparisonRemoteStatus: String = "unknown"
        var lastCanonicalCandidateOverlayComparisonLocalShotCount: Int?
        var lastCanonicalCandidateOverlayComparisonRemoteShotCount: Int?
        var lastCanonicalCandidateOverlayComparisonLocalIssueObservationCount: Int?
        var lastCanonicalCandidateOverlayComparisonRemoteIssueObservationCount: Int?
        var lastCanonicalCandidateOverlayComparisonLocalFreshness: String = "unknown"
        var lastCanonicalCandidateOverlayComparisonRemoteFreshness: String = "unknown"
        var lastCanonicalCandidateOverlayComparisonParityConfidence: String = "not_checked"
        var lastCanonicalCandidateOverlayComparisonTrustedReason: String = "not_checked"
        var lastCanonicalCandidateOverlayComparisonBlockedReason: String = "not_checked"
        var lastCanonicalCandidateActivationAllowed: Bool = false
        var lastCanonicalCandidateActivationBlockedReason: String = "not_checked"
        var lastCanonicalCandidateActivationActiveSource: String = "local"
        var lastCanonicalCandidateActivationRollbackSource: String = "local"
        var lastCanonicalCandidateActivationScope: String = "selected_session_only"
        var lastCanonicalCandidateActivationPropertyID: UUID?
        var lastCanonicalCandidateActivationSessionID: UUID?
        var lastCanonicalCandidateActivationRollbackAvailable: Bool = true
        var lastCanonicalCandidateActivationLastActivatedAt: Date?
        var lastCanonicalCandidateActivationLastRolledBackAt: Date?
        var lastCanonicalCandidateActivationProductionBlocked: Bool = true
        var runtimeSelectedSessionQAAuthAuthorized: Bool = false
        var runtimeSelectedSessionQAAuthOrgID: UUID?
        var runtimeSelectedSessionQAAuthPropertyID: UUID?
        var runtimeSelectedSessionQAAuthSessionID: UUID?
        var runtimeSelectedSessionQAAuthAuthorizedAt: Date?
        var runtimeSelectedSessionQAAuthExpiresAt: Date?
        var runtimeSelectedSessionQAAuthFreshness: String = "not_authorized"
        var runtimeSelectedSessionQAAuthScopeMatches: Bool = false
        var runtimeSelectedSessionQAAuthClearReason: String?
        var lastSelectedSessionValidationPipelineState: String = "not_started"
        var lastSelectedSessionValidationPipelineCheckedAt: Date?
        var lastSelectedSessionValidationPipelineBlocker: String?
        var lastSelectedSessionValidationPipelineReportText: String = ""
    }

    struct LocalDiagnosticsState: Equatable {
        var offlineReplay = OfflineReplayDiagnostics()
        var offlineQueue = OfflineQueueDiagnostics()
        var media = MediaDiagnostics()
        var shadowWrites = ShadowWriteDiagnostics()
        var sessionSnapshotUpload = SessionSnapshotUploadDiagnostics()
        var captureProfileMaintenance: CaptureProfileMaintenanceBackfillResult?
        var lastError: DiagnosticErrorSnapshot?
    }

}
