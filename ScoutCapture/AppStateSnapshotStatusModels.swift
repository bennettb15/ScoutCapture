import Foundation

extension AppState {
    enum SessionSnapshotKind: String, Codable, CaseIterable, Equatable {
        case draft
        case completed
        case export
        case delivery
        case manual
    }

    enum SessionSnapshotUploadOutcome: String, Equatable {
        case disabled
        case unavailable
        case succeeded
        case failed
        case orphanRisk
    }

    struct SessionSnapshotUploadResult: Equatable {
        let outcome: SessionSnapshotUploadOutcome
        let snapshotID: UUID?
        let sessionID: UUID?
        let propertyID: UUID?
        let storagePath: String?
        let message: String?
    }

    struct SessionSnapshotAutoUploadEligibility: Equatable {
        let allowed: Bool
        let reason: String
    }

    struct SessionSnapshotUploadRetryRunSummary: Equatable {
        let didStart: Bool
        let source: String
        let discoveredCount: Int
        let normalizedInFlightCount: Int
        let skippedBackoffCount: Int
        let attemptedCount: Int
        let succeededCount: Int
        let failedCount: Int
        let terminalFailedCount: Int
        let skippedIneligibleCount: Int
    }

    enum SessionSnapshotCloudState: String, Equatable {
        case queued
        case uploading
        case retryScheduled = "retry_scheduled"
        case failed
        case uploaded
    }

    enum PropertyRowCloudGlyphState: String, Equatable {
        case current
        case uploading
        case warning
    }

    enum PropertyRowStatusChipState: String, Equatable {
        case pendingExport = "pending_export"
        case uploading
    }

    struct SessionSnapshotCloudStatus: Equatable {
        enum Tint: String, Equatable {
            case neutral
            case blue
            case orange
            case red
        }

        let state: SessionSnapshotCloudState
        let snapshotID: UUID
        let organizationID: UUID
        let propertyID: UUID
        let sessionID: UUID
        let triggerSource: String
        let reason: String?
        let generatedAt: Date
        let updatedAt: Date

        var accessibilityLabel: String {
            if isConfigurationBlocked {
                return "Session snapshot upload disabled"
            }
            switch state {
            case .queued:
                return "Session snapshot queued"
            case .uploading:
                return "Session snapshot uploading"
            case .retryScheduled:
                return "Session snapshot upload retry scheduled"
            case .failed:
                return "Session snapshot upload failed"
            case .uploaded:
                return "Session snapshot uploaded"
            }
        }

        var helpText: String {
            if isConfigurationBlocked {
                return "Automatic session snapshot upload is disabled or blocked by configuration."
            }
            switch state {
            case .queued:
                return "Automatic session snapshot upload is queued."
            case .uploading:
                return "Automatic session snapshot upload is in progress."
            case .retryScheduled:
                return "Automatic session snapshot upload will retry automatically."
            case .failed:
                return "Automatic session snapshot upload reached a terminal failure."
            case .uploaded:
                return "Automatic session snapshot upload completed."
            }
        }

        var symbolName: String {
            if isConfigurationBlocked {
                return "icloud.slash"
            }
            switch state {
            case .queued:
                return "icloud"
            case .uploading:
                return "icloud.and.arrow.up"
            case .retryScheduled:
                return "arrow.clockwise.icloud"
            case .failed:
                return "exclamationmark.icloud"
            case .uploaded:
                return "checkmark.icloud.fill"
            }
        }

        var tint: Tint {
            if isConfigurationBlocked {
                return .orange
            }
            switch state {
            case .queued:
                return .neutral
            case .uploading:
                return .blue
            case .retryScheduled:
                return .orange
            case .failed:
                return .red
            case .uploaded:
                return .blue
            }
        }

        var isConfigurationBlocked: Bool {
            guard state == .failed else { return false }
            switch reason {
            case "auto_upload_disabled",
                "kill_switch_active",
                "allowlist_empty",
                "snapshot_shadow_write_disabled",
                "supabase_config_invalid",
                "snapshot_target_not_approved",
                "production_validation_manual_only",
                "missing_org_id",
                "allowlist_no_match",
                "authentication_not_ready",
                "active_org_required":
                return true
            default:
                return false
            }
        }
    }

}
