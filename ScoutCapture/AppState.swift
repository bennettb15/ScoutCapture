import Foundation
import Combine
import CryptoKit
import Supabase
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

extension Notification.Name {
    static let scoutClearLocalUICache = Notification.Name("scout.clearLocalUICache")
    static let scoutVerifySessionJSONSource = Notification.Name("scout.verifySessionJSONSource")
    static let scoutVerifyExportSessionJSONSource = Notification.Name("scout.verifyExportSessionJSONSource")
}

struct SupabaseRuntimeConfiguration {
    let url: URL?
    let anonKey: String?

    var isConfigured: Bool {
        url != nil && !(anonKey?.isEmpty ?? true)
    }
}

enum CutoverPhase: String, CaseIterable {
    case phaseA = "phase_a"
    case phaseB = "phase_b"
    case phaseC = "phase_c"

    var displayName: String {
        switch self {
        case .phaseA:
            return "Phase A"
        case .phaseB:
            return "Phase B"
        case .phaseC:
            return "Phase C"
        }
    }

    var summary: String {
        switch self {
        case .phaseA:
            return "iCloud read/write"
        case .phaseB:
            return "iCloud read/write + Supabase metadata shadow-write"
        case .phaseC:
            return "Supabase canonical read/write + iCloud passive cache/DR"
        }
    }

    var logDescription: String {
        "\(displayName) (\(summary))"
    }
}

// 2C-08 rollback is operator-driven and restart-based. This catalog is only used to
// make the intended rollback posture explicit in startup logs.
enum CutoverRollbackTrigger: String, CaseIterable {
    case operatorFlagRollback = "operator_flag_rollback"
    case phaseBShadowWriteInstability = "phase_b_shadow_write_instability"
    case phaseCCanonicalPathInstability = "phase_c_canonical_path_instability"
    case unexpectedRemoteMetadataDivergence = "unexpected_remote_metadata_divergence"

    var summary: String {
        switch self {
        case .operatorFlagRollback:
            return "Operator changes cutover flags and restarts the app"
        case .phaseBShadowWriteInstability:
            return "Phase B metadata shadow-write failures or instability"
        case .phaseCCanonicalPathInstability:
            return "Phase C canonical Supabase read/write instability"
        case .unexpectedRemoteMetadataDivergence:
            return "Unexpected remote metadata divergence during cutover"
        }
    }

    static var restartCatalogForLogs: String {
        allCases.map { "\($0.rawValue)=\($0.summary)" }.joined(separator: " | ")
    }
}

struct BackendFeatureFlags {
    let supabaseEnabled: Bool
    let shadowWriteEnabled: Bool
    let supabaseReadEnabled: Bool
    let supabasePropertyReadEnabled: Bool
    let mediaSupabaseUploadEnabled: Bool
    let syncDeltaEnabled: Bool
    let sessionCoordinationEnabled: Bool

    // The cutover phase is derived from the existing backend flags. Property-list
    // remote reads remain separately controlled by `supabase_property_read_enabled`
    // so the stabilized 2C-07 property refresh behavior is not coupled to phase.
    // `supabase_enabled` only indicates backend availability/bootstrap posture.
    // The actual A/B/C cutover meaning comes from `shadow_write_enabled` and
    // `supabase_read_enabled`.
    var cutoverPhase: CutoverPhase {
        if !supabaseEnabled {
            return .phaseA
        }
        if supabaseReadEnabled {
            return .phaseC
        }
        if shadowWriteEnabled {
            return .phaseB
        }
        return .phaseA
    }

    static func load(
        bundle: Bundle = .main,
        userDefaults: UserDefaults = .standard
    ) -> BackendFeatureFlags {
        BackendFeatureFlags(
            supabaseEnabled: Self.boolValue(for: "supabase_enabled", bundle: bundle, userDefaults: userDefaults),
            shadowWriteEnabled: Self.boolValue(for: "shadow_write_enabled", bundle: bundle, userDefaults: userDefaults),
            supabaseReadEnabled: Self.boolValue(for: "supabase_read_enabled", bundle: bundle, userDefaults: userDefaults),
            supabasePropertyReadEnabled: Self.boolValue(for: "supabase_property_read_enabled", bundle: bundle, userDefaults: userDefaults),
            mediaSupabaseUploadEnabled: Self.boolValue(for: "media_supabase_upload_enabled", bundle: bundle, userDefaults: userDefaults),
            syncDeltaEnabled: Self.boolValue(for: "sync_delta_enabled", bundle: bundle, userDefaults: userDefaults),
            sessionCoordinationEnabled: Self.boolValue(for: "session_coordination_enabled", bundle: bundle, userDefaults: userDefaults)
        )
    }

    private static func boolValue(
        for key: String,
        bundle: Bundle,
        userDefaults: UserDefaults
    ) -> Bool {
        if userDefaults.object(forKey: key) != nil {
            return userDefaults.bool(forKey: key)
        }

        if let number = bundle.object(forInfoDictionaryKey: key) as? NSNumber {
            return number.boolValue
        }

        if let string = bundle.object(forInfoDictionaryKey: key) as? String {
            switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes", "on":
                return true
            default:
                return false
            }
        }

        return false
    }
}

struct AuthenticatedSupabaseUser: Equatable {
    let id: UUID
    let email: String?
}

struct ActiveOrganizationMembership: Equatable, Identifiable {
    let id: UUID
    let name: String
    let role: String
}

enum AuthenticationFlowResult: Equatable {
    case signedIn
    case requiresEmailConfirmation
}

private enum AppStateTestEnvironment {
    static var isRunningUnderXCTest: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}

final class AppState: ObservableObject {
    typealias PropertyShadowWriteOverride = (Property) async throws -> Void
    typealias SessionShadowWriteOverride = (Property, Session, SessionMetadata) async throws -> Void
#if DEBUG
    private typealias SyncDeltaFetchOverride = (
        UUID,
        Date?,
        Date?
    ) async throws -> ([RemotePropertyDeltaRecord], [RemoteSessionDeltaRecord])
    private typealias SessionCoordinationFetchOverride = (
        UUID,
        UUID,
        UUID
    ) async throws -> RemoteSessionCoordinationRecord?
#endif

    struct PendingSupabaseMediaBackfillCandidate: Equatable {
        let propertyID: UUID
        let sessionID: UUID
        let shotID: UUID
        let uploadState: String
        let uploadAttempts: Int
    }

    struct OperationalMediaHydrationRequest: Hashable {
        let propertyID: UUID
        let sessionID: UUID
        let shotID: UUID
    }

    struct SupabaseMediaBackfillRunSummary: Equatable {
        let didStart: Bool
        let reason: String
        let discoveredCount: Int
        let excludedInFlightCount: Int
        let skippedRetryCapCount: Int
        let attemptedCount: Int
    }

    struct OfflineReplayRunSummary: Equatable {
        let didStart: Bool
        let source: String
        let discoveredCount: Int
        let normalizedInFlightCount: Int
        let skippedBackoffCount: Int
        let attemptedCount: Int
        let succeededCount: Int
        let failedCount: Int
    }

    private struct QueuedPropertyMutationPayload: Codable {
        let property: SupabasePropertyPayload
    }

    private struct QueuedSessionMutationPayload: Codable {
        let property: SupabasePropertyPayload
        let session: SupabaseSessionPayload
    }

    struct SessionCoordinationDiff: Equatable, Identifiable {
        let id: String
        let label: String
        let remoteValue: String
        let localValue: String
    }

    struct SessionCoordinationConflictReview: Equatable {
        let sessionID: UUID
        let diffs: [SessionCoordinationDiff]
    }

    struct SessionEntryCoordinationBlock: Equatable {
        let ownerDescription: String
        let lockedAt: Date?
    }

    enum SessionEntryCoordinationStatus: Equatable {
        case allowed
        case blocked(SessionEntryCoordinationBlock)
    }

    private struct SessionCoordinationTier1Snapshot: Codable, Equatable {
        struct Entry: Codable, Equatable {
            let id: UUID
            let value: String
        }

        let priorities: [Entry]
        let trades: [Entry]
        let flaggedReasons: [Entry]
    }

    private struct SessionCoordinationState: Equatable {
        var lockedByUserID: UUID?
        var lockedByDeviceID: String?
        var lockedAt: Date?
    }

    private struct PropertySessionOccupancyState: Equatable {
        var occupiedByUserID: UUID?
        var occupiedByDeviceID: String?
        var occupiedAt: Date?
    }

#if DEBUG
    struct DebugRemotePropertyDeltaInput {
        let id: UUID
        let orgID: UUID
        let folderID: String?
        let clientName: String?
        let clientEmail: String?
        let clientPhone: String?
        let name: String
        let addressLine1: String?
        let city: String?
        let state: String?
        let postalCode: String?
        let baselineSessionID: UUID?
        let isArchived: Bool
        let createdAt: Date
        let updatedAt: Date
        let deletedAt: Date?
    }

    struct DebugRemoteSessionDeltaInput {
        let id: UUID
        let orgID: UUID
        let propertyID: UUID
        let title: String?
        let status: String
        let startedAt: String
        let completedAt: String?
        let updatedAt: Date
        let deletedAt: Date?
    }

    struct DebugSessionCoordinationRemoteInput {
        let sessionID: UUID
        let orgID: UUID
        let propertyID: UUID
        let lockedByUserID: UUID?
        let lockedByDeviceID: String?
        let lockedAt: String?
        let coordinationTier1Snapshot: String?
        let updatedAt: Date?
    }
#endif

    enum PropertyCreationError: LocalizedError {
        case missingPropertyName
        case missingOrganization
        case noAvailableFolderID
        case persistenceFailed

        var errorDescription: String? {
            switch self {
            case .missingPropertyName:
                return "Enter a property name."
            case .missingOrganization:
                return "Select an organization."
            case .noAvailableFolderID:
                return "No folder IDs are available. Please contact support."
            case .persistenceFailed:
                return "The property could not be saved."
            }
        }
    }

    struct HubPropertyMeta: Equatable {
        let clientLine: String?
        let addressLine: String?
        let normalizedNameToken: String
        let normalizedClientToken: String
        let normalizedOrganizationToken: String
        let normalizedAddressToken: String
    }

    struct PropertyDataCounts {
        let sessions: Int
        let guided: Int
        let observations: Int

        var isEmpty: Bool {
            sessions == 0 && guided == 0 && observations == 0
        }
    }

    private struct SupabaseShotStoragePayload: Encodable {
        let id: UUID
        let orgID: UUID
        let sessionID: UUID
        let storageBucket: String?
        let storagePath: String?
        let checksumSHA256: String?
        let byteSize: Int?
        let uploadState: String
        let uploadAttempts: Int
        let lastUploadError: String?

        enum CodingKeys: String, CodingKey {
            case id
            case orgID = "org_id"
            case sessionID = "session_id"
            case storageBucket = "storage_bucket"
            case storagePath = "storage_path"
            case checksumSHA256 = "checksum_sha256"
            case byteSize = "byte_size"
            case uploadState = "upload_state"
            case uploadAttempts = "upload_attempts"
            case lastUploadError = "last_upload_error"
        }
    }

    private struct SupabaseOrgPayload: Encodable {
        let id: UUID
        let name: String
    }

    private struct SupabaseAccessibleOrgRecord: Decodable {
        let id: UUID
        let name: String
        let deletedAt: String?

        enum CodingKeys: String, CodingKey {
            case id
            case name
            case deletedAt = "deleted_at"
        }
    }

    private struct SupabaseOrgMembershipRecord: Decodable {
        let orgID: UUID
        let role: String
        let deletedAt: String?

        enum CodingKeys: String, CodingKey {
            case orgID = "org_id"
            case role
            case deletedAt = "deleted_at"
        }
    }

    private struct SupabasePropertyPayload: Codable {
        let id: UUID
        let orgID: UUID
        let clientName: String?
        let clientEmail: String?
        let clientPhone: String?
        let name: String
        let addressLine1: String?
        let city: String?
        let state: String?
        let postalCode: String?

        enum CodingKeys: String, CodingKey {
            case id
            case orgID = "org_id"
            case clientName = "client_name"
            case clientEmail = "client_email"
            case clientPhone = "client_phone"
            case name
            case addressLine1 = "address_line1"
            case city
            case state
            case postalCode = "postal_code"
        }
    }

    private struct SupabaseSessionPayload: Codable {
        let id: UUID
        let orgID: UUID
        let propertyID: UUID
        let title: String?
        let status: String
        let startedAt: String
        let completedAt: String?
        let lockedByUserID: UUID?
        let lockedByDeviceID: String?
        let lockedAt: String?
        let coordinationTier1Snapshot: String?

        enum CodingKeys: String, CodingKey {
            case id
            case orgID = "org_id"
            case propertyID = "property_id"
            case title
            case status
            case startedAt = "started_at"
            case completedAt = "completed_at"
            case lockedByUserID = "locked_by_user_id"
            case lockedByDeviceID = "locked_by_device_id"
            case lockedAt = "locked_at"
            case coordinationTier1Snapshot = "coordination_tier1_snapshot"
        }
    }

    private struct RemoteSessionCoordinationRecord: Decodable {
        let id: UUID
        let orgID: UUID
        let propertyID: UUID
        let lockedByUserID: UUID?
        let lockedByDeviceID: String?
        let lockedAt: String?
        let coordinationTier1Snapshot: String?
        let updatedAt: Date?

        enum CodingKeys: String, CodingKey {
            case id
            case orgID = "org_id"
            case propertyID = "property_id"
            case lockedByUserID = "locked_by_user_id"
            case lockedByDeviceID = "locked_by_device_id"
            case lockedAt = "locked_at"
            case coordinationTier1Snapshot = "coordination_tier1_snapshot"
            case updatedAt = "updated_at"
        }
    }

    private struct PropertySessionOccupancyPayload: Codable {
        let propertyID: UUID
        let orgID: UUID
        let occupiedByUserID: UUID?
        let occupiedByDeviceID: String?
        let occupiedAt: String?
        let updatedBy: UUID?

        enum CodingKeys: String, CodingKey {
            case propertyID = "property_id"
            case orgID = "org_id"
            case occupiedByUserID = "occupied_by_user_id"
            case occupiedByDeviceID = "occupied_by_device_id"
            case occupiedAt = "occupied_at"
            case updatedBy = "updated_by"
        }
    }

    private struct RemotePropertySessionOccupancyRecord: Decodable {
        let propertyID: UUID
        let orgID: UUID
        let occupiedByUserID: UUID?
        let occupiedByDeviceID: String?
        let occupiedAt: String?

        enum CodingKeys: String, CodingKey {
            case propertyID = "property_id"
            case orgID = "org_id"
            case occupiedByUserID = "occupied_by_user_id"
            case occupiedByDeviceID = "occupied_by_device_id"
            case occupiedAt = "occupied_at"
        }
    }

    private struct SupabaseShotStorageRecord: Decodable {
        let id: UUID
        let storageBucket: String?
        let storagePath: String?
        let checksumSHA256: String?
        let byteSize: Int?
        let uploadState: String
        let uploadAttempts: Int
        let lastUploadError: String?

        enum CodingKeys: String, CodingKey {
            case id
            case storageBucket = "storage_bucket"
            case storagePath = "storage_path"
            case checksumSHA256 = "checksum_sha256"
            case byteSize = "byte_size"
            case uploadState = "upload_state"
            case uploadAttempts = "upload_attempts"
            case lastUploadError = "last_upload_error"
        }
    }

    private struct SupabasePropertyIdentityRecord: Decodable {
        let id: UUID
        let orgID: UUID
        let name: String

        enum CodingKeys: String, CodingKey {
            case id
            case orgID = "org_id"
            case name
        }
    }

    private struct RemotePropertyDeltaRecord: Decodable {
        let id: UUID
        let orgID: UUID
        let folderID: String?
        let clientName: String?
        let clientEmail: String?
        let clientPhone: String?
        let name: String
        let addressLine1: String?
        let city: String?
        let state: String?
        let postalCode: String?
        let baselineSessionID: UUID?
        let isArchived: Bool
        let createdAt: Date
        let updatedAt: Date
        let deletedAt: Date?

        enum CodingKeys: String, CodingKey {
            case id
            case orgID = "org_id"
            case folderID = "folder_id"
            case clientName = "client_name"
            case clientEmail = "client_email"
            case clientPhone = "client_phone"
            case name
            case addressLine1 = "address_line1"
            case city
            case state
            case postalCode = "postal_code"
            case baselineSessionID = "baseline_session_id"
            case isArchived = "is_archived"
            case createdAt = "created_at"
            case updatedAt = "updated_at"
            case deletedAt = "deleted_at"
        }
    }

    private struct RemotePropertyRecord: Decodable {
        let id: UUID
        let orgID: UUID
        let folderID: String?
        let clientName: String?
        let clientEmail: String?
        let clientPhone: String?
        let name: String
        let addressLine1: String
        let city: String
        let state: String
        let postalCode: String
        let baselineSessionID: UUID?
        let isArchived: Bool
        let createdAt: Date?
        let updatedAt: Date

        enum CodingKeys: String, CodingKey {
            case id
            case orgID = "org_id"
            case folderID = "folder_id"
            case clientName = "client_name"
            case clientEmail = "client_email"
            case clientPhone = "client_phone"
            case name
            case addressLine1 = "address_line1"
            case city
            case state
            case postalCode = "postal_code"
            case baselineSessionID = "baseline_session_id"
            case isArchived = "is_archived"
            case createdAt = "created_at"
            case updatedAt = "updated_at"
        }
    }

    private struct SupabaseOrgIdentityRecord: Decodable {
        let id: UUID
    }

    private enum RemotePropertyFetchError: LocalizedError {
        case missingClient
        case missingActiveOrganization
        case timedOut
        case emptyResponseRejected(localCacheCount: Int)
        case orgScopeMismatch(expected: UUID, actual: UUID, propertyID: UUID)
        case duplicatePropertyID(UUID)
        case invalidPropertyName(UUID)
        case invalidAddressLine1(UUID)
        case invalidCity(UUID)
        case invalidState(UUID)
        case invalidPostalCode(UUID)
        case invalidUpdatedAt(UUID)
        case invalidCreatedAt(UUID)
        case missingLocalCreatedAtFallback(UUID)

        var errorDescription: String? {
            switch self {
            case .missingClient:
                return "Supabase client is unavailable for remote property fetch."
            case .missingActiveOrganization:
                return "An active organization is required for remote property fetch."
            case .timedOut:
                return "Remote property fetch timed out after 3 seconds."
            case let .emptyResponseRejected(localCacheCount):
                return "Rejected empty remote property response because local cache contains \(localCacheCount) records."
            case let .orgScopeMismatch(expected, actual, propertyID):
                return "Rejected remote property \(propertyID.uuidString) because org scope \(actual.uuidString) did not match active org \(expected.uuidString)."
            case let .duplicatePropertyID(propertyID):
                return "Rejected remote property response because duplicate property ID \(propertyID.uuidString) was detected."
            case let .invalidPropertyName(propertyID):
                return "Rejected remote property \(propertyID.uuidString) because name was empty."
            case let .invalidAddressLine1(propertyID):
                return "Rejected remote property \(propertyID.uuidString) because address_line1 was empty."
            case let .invalidCity(propertyID):
                return "Rejected remote property \(propertyID.uuidString) because city was empty."
            case let .invalidState(propertyID):
                return "Rejected remote property \(propertyID.uuidString) because state was empty."
            case let .invalidPostalCode(propertyID):
                return "Rejected remote property \(propertyID.uuidString) because postal_code was empty."
            case let .invalidUpdatedAt(propertyID):
                return "Rejected remote property \(propertyID.uuidString) because updated_at was invalid or unexpected."
            case let .invalidCreatedAt(propertyID):
                return "Rejected remote property \(propertyID.uuidString) because created_at was invalid or unexpected."
            case let .missingLocalCreatedAtFallback(propertyID):
                return "Rejected remote property \(propertyID.uuidString) because created_at was null and no local createdAt fallback existed."
            }
        }
    }

    private struct SupabaseSessionIdentityRecord: Decodable {
        let id: UUID
        let orgID: UUID
        let propertyID: UUID
        let title: String?
        let status: String
        let startedAt: String

        enum CodingKeys: String, CodingKey {
            case id
            case orgID = "org_id"
            case propertyID = "property_id"
            case title
            case status
            case startedAt = "started_at"
        }
    }

    private struct RemoteSessionDeltaRecord: Decodable {
        let id: UUID
        let orgID: UUID
        let propertyID: UUID
        let title: String?
        let status: String
        let startedAt: String
        let completedAt: String?
        let updatedAt: Date
        let deletedAt: Date?

        enum CodingKeys: String, CodingKey {
            case id
            case orgID = "org_id"
            case propertyID = "property_id"
            case title
            case status
            case startedAt = "started_at"
            case completedAt = "completed_at"
            case updatedAt = "updated_at"
            case deletedAt = "deleted_at"
        }
    }

    private struct SupabaseRowUpdatedAtRecord: Decodable {
        let id: UUID
        let updatedAt: Date

        enum CodingKeys: String, CodingKey {
            case id
            case updatedAt = "updated_at"
        }
    }

    private struct SupabaseShotIdentityRecord: Decodable {
        let id: UUID
        let orgID: UUID
        let sessionID: UUID
        let storageBucket: String?
        let storagePath: String?
        let checksumSHA256: String?
        let uploadState: String

        enum CodingKeys: String, CodingKey {
            case id
            case orgID = "org_id"
            case sessionID = "session_id"
            case storageBucket = "storage_bucket"
            case storagePath = "storage_path"
            case checksumSHA256 = "checksum_sha256"
            case uploadState = "upload_state"
        }
    }

    private struct SupabaseShotFinalizeReadinessRecord: Decodable {
        let id: UUID
        let orgID: UUID
        let sessionID: UUID
        let storageBucket: String?
        let storagePath: String?
        let checksumSHA256: String?
        let byteSize: Int?
        let uploadState: String

        enum CodingKeys: String, CodingKey {
            case id
            case orgID = "org_id"
            case sessionID = "session_id"
            case storageBucket = "storage_bucket"
            case storagePath = "storage_path"
            case checksumSHA256 = "checksum_sha256"
            case byteSize = "byte_size"
            case uploadState = "upload_state"
        }
    }

    struct LegacyMigrationPreflightResult {
        let generatedAt: Date
        let activeOrganizationID: UUID
        let ledgerURL: URL
        let reportURL: URL
        let summary: LegacyMigrationPreflightLedger.Summary
    }

    struct LegacyMigrationStep2AResult {
        let runID: UUID
        let activeOrganizationID: UUID
        let ledgerURL: URL
        let verifiedPropertyCount: Int
        let verifiedSessionCount: Int
    }

    struct LegacyMigrationStep2BSlice1Result {
        let runID: UUID
        let activeOrganizationID: UUID
        let ledgerURL: URL
        let verifiedShotCount: Int
    }

    struct LegacyMigrationStep2BSlice2AResult {
        let runID: UUID
        let activeOrganizationID: UUID
        let ledgerURL: URL
        let uploadedMediaCount: Int
    }

    struct LegacyMigrationStep2BSlice2BReadinessResult {
        let runID: UUID
        let activeOrganizationID: UUID
        let ledgerURL: URL
        let verifiedMediaCount: Int
        let readyForFinalizeCount: Int
    }

    struct LegacyMigrationStep2BSlice2BFinalizeResult {
        let runID: UUID
        let activeOrganizationID: UUID
        let ledgerURL: URL
        let verifiedMediaCount: Int
    }

    @Published var properties: [Property] = []
    @Published var organizations: [Organization] = []
    @Published private(set) var isLoading: Bool = true
    @Published private(set) var sessionIndexByProperty: [UUID: [Session]] = [:]
    @Published private(set) var draftSessionByProperty: [UUID: Session] = [:]
    @Published private(set) var pendingExportSessionByProperty: [UUID: Session] = [:]
    @Published private(set) var hubMetaByProperty: [UUID: HubPropertyMeta] = [:]
    @Published private(set) var cloudBackupStatus: CloudBackupStatus
    @Published private(set) var supabaseConfiguration: SupabaseRuntimeConfiguration
    @Published private(set) var backendFeatureFlags: BackendFeatureFlags
    @Published private(set) var isAuthenticationReady: Bool = false
    @Published private(set) var isAuthenticating: Bool = false
    @Published private(set) var authenticatedSupabaseUser: AuthenticatedSupabaseUser?
    @Published var authenticationErrorMessage: String?
    @Published var locallyLockedPropertyIDs: Set<UUID> = []
    @Published private var propertySessionOccupancyByPropertyID: [UUID: PropertySessionOccupancyState] = [:]
    @Published private(set) var activeOrganizationID: UUID?
    @Published private(set) var accessibleOrganizations: [ActiveOrganizationMembership] = []
    @Published private(set) var isOrganizationContextReady: Bool = false

    @Published var selectedPropertyID: UUID? {
        didSet {
            persistSelectedPropertyID()
        }
    }

    @Published var currentSession: Session? {
        didSet {
            logActiveSession(currentSession)
        }
    }

    var selectedProperty: Property? {
        guard let selectedPropertyID else { return nil }
        return properties.first { $0.id == selectedPropertyID }
    }

    private let injectedLocalStore: LocalStore?
    private lazy var localStore: LocalStore = injectedLocalStore ?? LocalStore()
    private var supabaseClient: SupabaseClient?
    private let userDefaults: UserDefaults
    private let cloudBackupManager: CloudBackupManager?
    private let propertyShadowWriteOverride: PropertyShadowWriteOverride?
    private let sessionShadowWriteOverride: SessionShadowWriteOverride?
    private let selectedPropertyDefaultsKey = "scoutcapture.selectedPropertyID"
    private let activeOrganizationDefaultsKeyPrefix = "scoutcapture.activeOrganizationID"
    private let propertyActivationTimestampsDefaultsKey = "scoutcapture.propertyActivationTimestamps.v1"
    private let deviceIdentifierDefaultsKey = "scoutcapture.deviceIdentifier.v1"
    private let reExportWindowDays = 7
    private let sessionMediaOffloadCooldown: TimeInterval = 30 * 60
    private let activatedPropertyRetentionWindow: TimeInterval = 7 * 24 * 60 * 60
    private let offloadSweepQueue = DispatchQueue(label: "ScoutCapture.AppState.offloadSweep", qos: .utility)
    private let archiveSnapshotQueue = DispatchQueue(label: "ScoutCapture.AppState.archiveSnapshot", qos: .utility)
    private let logThrottleQueue = DispatchQueue(label: "ScoutCapture.AppState.logThrottle")
    private let supabaseMediaOperationQueue = DispatchQueue(label: "ScoutCapture.AppState.supabaseMediaOperations")
    private let offlineReplayStateQueue = DispatchQueue(label: "ScoutCapture.AppState.offlineReplay")
    private var cloudBackupLogRunOpen: Bool = false
    private var cloudBackupLogHasPrintedStart: Bool = false
    private var cloudBackupLogHasPrintedTerminal: Bool = false
    private var cloudBackupLogHasPrintedClose: Bool = false
    private var lastHubFetchLogSignature: String?
    private var lastHubFetchLogAt: Date?
    private var lastSessionOffloadLogSignature: String?
    private var lastSessionOffloadLogAt: Date?
    private var didLoad = false
    private var cancellables: Set<AnyCancellable> = []
    private var liveSyncTimer: Timer?
    private var lastLiveSyncFingerprint: String?
    private var lastBackgroundRemoteFingerprint: String?
    private var lastBackgroundRemoteAttemptCompletedAt: Date?
    private var liveSyncBurstUntil: Date?
    private var lastLiveSyncRefreshAt: Date?
    private var isBackgroundRefreshInFlight: Bool = false
    private var lastBackgroundRefreshStartedAt: Date?
    private let minimumBackgroundRefreshInterval: TimeInterval = 1.0
    // Give iCloud small-manifest fetch enough time during splash to avoid source=none on cold starts.
    private let startupHubIndexTimeout: TimeInterval = 1.25
    private var isStartupHydrationInProgress: Bool = false
    private var startupHydrationCompletedAt: Date?
    // Keep a short grace for non-empty in-memory states, but do not stall first-load empty hubs.
    private let startupFallbackGraceWindow: TimeInterval = 25.0
    private let supabaseOperationalMediaBucket = "scoutcapture-originals"
    private let maximumSupabaseMediaUploadAttempts = 5
    private let failedSupabaseMediaRetryCooldown: TimeInterval = 30
    private var inFlightSupabaseMediaOperations: Set<String> = []
    private var isSupabaseMediaBackfillInProgress: Bool = false
    private var lastSupabaseMediaBackfillTriggerAt: Date?
    private var lastSupabaseMediaBackfillTriggerReason: String?
    private var isSyncDeltaPullInFlight: Bool = false
    private var isOfflineReplayInFlight: Bool = false
    private var sessionCoordinationStateBySessionID: [UUID: SessionCoordinationState] = [:]
    private var sessionCoordinationEntrySnapshotBySessionID: [UUID: String] = [:]
#if DEBUG
    private var propertySessionOccupancyDebugRemoteRecords: [UUID: RemotePropertySessionOccupancyRecord] = [:]
#endif
    private var lastForegroundSyncDeltaCompletedAt: Date?
#if DEBUG
    private var syncDeltaFetchOverride: SyncDeltaFetchOverride?
    private var sessionCoordinationFetchOverride: SessionCoordinationFetchOverride?
    private var sessionCoordinationDebugRemoteRecords: [UUID: RemoteSessionCoordinationRecord] = [:]
#endif
    private var authStateChangesTask: Task<Void, Never>?
    private var lastEnsuredUserProfileID: UUID?
    private var allProperties: [Property] = []
    private var allOrganizations: [Organization] = []
    private var allSessionIndexByProperty: [UUID: [Session]] = [:]
    private var allDraftSessionByProperty: [UUID: Session] = [:]
    private var allPendingExportSessionByProperty: [UUID: Session] = [:]
    private var allHubMetaByProperty: [UUID: HubPropertyMeta] = [:]

    var requiresAuthentication: Bool {
        backendFeatureFlags.supabaseEnabled && supabaseClient != nil
    }

    var cutoverPhase: CutoverPhase {
        backendFeatureFlags.cutoverPhase
    }

    private static var unavailableCloudBackupStatus: CloudBackupStatus {
        CloudBackupStatus(
            state: .unavailable,
            isRunning: false,
            lastSuccessfulBackupAt: nil,
            lastFailureMessage: nil,
            iCloudAvailable: false,
            hasBackup: false,
            progressPhase: nil,
            progressCompleted: nil,
            progressTotal: nil,
            snapshotFileCount: nil,
            snapshotByteCount: nil,
            lastRunChangedCount: nil,
            lastRunUnchangedCount: nil,
            lastRunChangedByteCount: nil,
            lastRunAddedCount: nil,
            lastRunUpdatedCount: nil,
            lastRunSourceFileCount: nil,
            lastRunPrunedCount: nil,
            lastRunNewBlobsWrittenCount: nil,
            lastRunReusedBlobsReferencedCount: nil,
            lastRunBlobBytesWritten: nil,
            lastRunBlobBytesReused: nil,
            lastRunChangedPathsSample: nil,
            lastRunPrunedPathsSample: nil,
            safetyPauseUntil: nil,
            safetyPauseReason: nil
        )
    }

    var isAuthenticated: Bool {
        authenticatedSupabaseUser != nil
    }

    var sharedLocalStore: LocalStore {
        localStore
    }

    var activeOrganization: ActiveOrganizationMembership? {
        guard let activeOrganizationID else { return nil }
        return accessibleOrganizations.first { $0.id == activeOrganizationID }
    }

    var organizationSelectionOptions: [Organization] {
        if requiresAuthentication {
            return accessibleOrganizations.map { membership in
                let localMatch = allOrganizations.first(where: { $0.id == membership.id })
                return Organization(
                    id: membership.id,
                    name: membership.name,
                    contacts: localMatch?.contacts ?? []
                )
            }
        }
        return organizations
    }

    func sessionArchiveSummaries() -> [LocalStore.SessionArchiveSummary] {
        (try? localStore.fetchSessionArchiveSummaries()) ?? []
    }

    @discardableResult
    func deleteSessionArchiveSnapshot(
        propertyID: UUID,
        sessionID: UUID,
        snapshotName: String
    ) -> Bool {
        do {
            try localStore.deleteSessionArchiveSnapshot(
                propertyID: propertyID,
                sessionID: sessionID,
                snapshotName: snapshotName
            )
            triggerBackupForLifecycleEvent()
            return true
        } catch {
            print(
                "[SessionArchiveDelete] result=failed " +
                "propertyID=\(propertyID.uuidString) " +
                "sessionID=\(sessionID.uuidString) " +
                "snapshot=\(snapshotName) " +
                "error=\(error.localizedDescription)"
            )
            return false
        }
    }

    @discardableResult
    func restoreSessionArchiveSnapshot(
        propertyID: UUID,
        sessionID: UUID,
        snapshotName: String
    ) -> Bool {
        do {
            let restored = try localStore.restoreSessionArchiveSnapshot(
                propertyID: propertyID,
                sessionID: sessionID,
                snapshotName: snapshotName
            )
            let applyUIUpdates = {
                self.reloadSessionCache(for: restored.propertyID)
                self.refreshProperties()
                self.triggerBackupForLifecycleEvent()
            }
            if Thread.isMainThread {
                applyUIUpdates()
            } else {
                DispatchQueue.main.sync(execute: applyUIUpdates)
            }
            return true
        } catch {
            print(
                "[SessionRestore] result=failed " +
                "propertyID=\(propertyID.uuidString) " +
                "sessionID=\(sessionID.uuidString) " +
                "snapshot=\(snapshotName) " +
                "error=\(error.localizedDescription)"
            )
            return false
        }
    }

    init(
        localStore: LocalStore? = nil,
        userDefaults: UserDefaults = .standard,
        propertyShadowWriteOverride: PropertyShadowWriteOverride? = nil,
        sessionShadowWriteOverride: SessionShadowWriteOverride? = nil,
        disableCloudBackupForTests: Bool = false
    ) {
        self.injectedLocalStore = localStore
        self.userDefaults = userDefaults
        #if DEBUG
        if disableCloudBackupForTests || AppStateTestEnvironment.isRunningUnderXCTest {
            self.cloudBackupManager = nil
        } else {
            self.cloudBackupManager = CloudBackupManager(userDefaults: userDefaults)
        }
        #else
        self.cloudBackupManager = CloudBackupManager(userDefaults: userDefaults)
        #endif
        self.cloudBackupStatus = cloudBackupManager?.status ?? Self.unavailableCloudBackupStatus
        self.propertyShadowWriteOverride = propertyShadowWriteOverride
        self.sessionShadowWriteOverride = sessionShadowWriteOverride
        self.supabaseConfiguration = AppState.loadSupabaseConfiguration()
        self.backendFeatureFlags = BackendFeatureFlags.load(userDefaults: userDefaults)

        if let rawID = userDefaults.string(forKey: selectedPropertyDefaultsKey) {
            self.selectedPropertyID = UUID(uuidString: rawID)
        } else {
            self.selectedPropertyID = nil
        }

        self.currentSession = nil

        if let cloudBackupManager {
            cloudBackupManager.$status
                .receive(on: DispatchQueue.main)
                .sink { [weak self] status in
                    self?.logCloudBackupStatusSink(status)
                    self?.cloudBackupStatus = status
                }
                .store(in: &cancellables)
        }

        NotificationCenter.default.publisher(for: .scoutPersistentDataDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                print("[AppStateDiag] scoutPersistentDataDidChange_sink")
                self?.cloudBackupManager?.markDataChanged(scheduleBackupAfter: 30)
            }
            .store(in: &cancellables)

        print("[AppStateDiag] init")
        logCutoverConfiguration()
        prepareCollaborativeBackendBootstrap()
    }

    deinit {
        print("[AppStateDiag] deinit_enter")
    }

    private static func loadSupabaseConfiguration(bundle: Bundle = .main) -> SupabaseRuntimeConfiguration {
        let rawURL = (bundle.object(forInfoDictionaryKey: "SUPABASE_URL") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let rawAnonKey = (bundle.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return SupabaseRuntimeConfiguration(
            url: rawURL.flatMap(URL.init(string:)),
            anonKey: rawAnonKey
        )
    }

    static func cutoverConfigurationWarnings(for flags: BackendFeatureFlags) -> [String] {
        var warnings: [String] = []

        if !flags.supabaseEnabled && flags.shadowWriteEnabled {
            warnings.append("shadow_write_enabled is ignored while supabase_enabled=false; restart rollback lands in Phase A.")
        }
        if !flags.supabaseEnabled && flags.supabaseReadEnabled {
            warnings.append("supabase_read_enabled is ignored while supabase_enabled=false; operational Supabase reads stay off until restart with supabase_enabled=true.")
        }
        if !flags.supabaseEnabled && flags.supabasePropertyReadEnabled {
            warnings.append("supabase_property_read_enabled is ignored while supabase_enabled=false; property-list remote reads remain local/iCloud only.")
        }
        if !flags.supabaseEnabled && flags.mediaSupabaseUploadEnabled {
            warnings.append("media_supabase_upload_enabled is ignored while supabase_enabled=false; captures stay in the existing local pending state until restart into a Supabase-enabled phase.")
        }
        if flags.supabaseEnabled && !flags.shadowWriteEnabled && !flags.supabaseReadEnabled {
            warnings.append("supabase_enabled=true while shadow_write_enabled=false and supabase_read_enabled=false leaves the app in an effective Phase A posture with backend bootstrap only.")
        }
        if flags.supabaseEnabled && flags.supabaseReadEnabled && !flags.shadowWriteEnabled {
            warnings.append("supabase_read_enabled=true while shadow_write_enabled=false selects Phase C directly; confirm this intentional skip past Phase B shadow-write.")
        }
        if flags.supabaseEnabled && flags.supabaseReadEnabled && flags.shadowWriteEnabled {
            warnings.append("supabase_read_enabled=true and shadow_write_enabled=true resolves to Phase C; shadow-write remains enabled but no longer defines the canonical phase.")
        }

        return warnings
    }

    private func logCutoverConfiguration() {
        print(
            "[Cutover] phase=\(cutoverPhase.rawValue) " +
            "summary=\"\(cutoverPhase.summary)\" " +
            "restartRollback=true " +
            "propertyReadSeparate=\(backendFeatureFlags.supabasePropertyReadEnabled)"
        )
        print("[Cutover] rollback_catalog=\(CutoverRollbackTrigger.restartCatalogForLogs)")

        let warnings = AppState.cutoverConfigurationWarnings(for: backendFeatureFlags)
        if warnings.isEmpty {
            print("[Cutover] validation=ok")
        } else {
            for warning in warnings {
                print("[Cutover][warning] \(warning)")
            }
        }
    }

    private func prepareCollaborativeBackendBootstrap() {
        guard backendFeatureFlags.supabaseEnabled else {
            stopAllObservers()
            supabaseClient = nil
            isAuthenticationReady = true
            isOrganizationContextReady = true
            print("[Supabase] bootstrap skipped because supabase_enabled=false")
            return
        }

        guard supabaseConfiguration.isConfigured else {
            stopAllObservers()
            supabaseClient = nil
            isAuthenticationReady = true
            isOrganizationContextReady = true
            print("[Supabase] bootstrap skipped because configuration is missing or invalid")
            return
        }

        print(
            "[Supabase] dev bootstrap enabled " +
            "shadowWrite=\(backendFeatureFlags.shadowWriteEnabled) " +
            "read=\(backendFeatureFlags.supabaseReadEnabled) " +
            "propertyRead=\(backendFeatureFlags.supabasePropertyReadEnabled) " +
            "mediaUpload=\(backendFeatureFlags.mediaSupabaseUploadEnabled)"
        )
        if let url = supabaseConfiguration.url, let anonKey = supabaseConfiguration.anonKey {
            supabaseClient = SupabaseClient(supabaseURL: url, supabaseKey: anonKey)
            beginObservingAuthenticationState()
        }
    }

    func stopAuthenticationObservation() {
        print("[AppStateDiag] stopAuthenticationObservation")
        let existingTask = authStateChangesTask
        authStateChangesTask = nil
        existingTask?.cancel()
    }

    func stopAllObservers() {
        print("[AppStateDiag] stopAllObservers")
        stopAuthenticationObservation()
        cancellables.removeAll()
    }

    func shutdown() {
        print("[AppStateDiag] shutdown_start")
        stopAllObservers()
        cloudBackupManager?.shutdown()
        localStore.shutdown()
        print("[AppStateDiag] shutdown_after_fileio_sync")
    }

    private func beginObservingAuthenticationState() {
        stopAuthenticationObservation()

        guard let client = supabaseClient else {
            applyAuthenticationState(user: nil, ready: true)
            return
        }

        applyAuthenticationState(user: nil, ready: false)

        authStateChangesTask = Task { [weak self] in
            for await (event, authSession) in client.auth.authStateChanges {
                if Task.isCancelled {
                    return
                }

                guard let self else { return }

                let userID = authSession?.user.id
                let email = authSession?.user.email
                let user = userID.map { AuthenticatedSupabaseUser(id: $0, email: email) }
                await MainActor.run {
                    self.applyAuthenticationState(user: user, ready: true)
                }

                if event == .signedOut {
                    await MainActor.run {
                        self.lastEnsuredUserProfileID = nil
                        self.clearOrganizationContext()
                    }
                    continue
                }

                if [.initialSession, .signedIn, .tokenRefreshed, .userUpdated].contains(event) {
                    do {
                        try await self.ensureCurrentUserProfileIfNeeded(for: userID)
                        if Task.isCancelled {
                            return
                        }
                        try await self.refreshOrganizationContext(for: userID)
                    } catch {
                        print("[SupabaseAuth] ensure_current_user_profile failed: \(error.localizedDescription)")
                        await MainActor.run {
                            self.handleOrganizationRefreshFailure()
                        }
                    }
                }
            }
        }
    }

    private func applyAuthenticationState(user: AuthenticatedSupabaseUser?, ready: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.authenticatedSupabaseUser != user {
                self.authenticatedSupabaseUser = user
            }
            if self.isAuthenticationReady != ready {
                self.isAuthenticationReady = ready
            }
            if user == nil {
                self.authenticationErrorMessage = nil
            }
        }
    }

    private func applyOrganizationContext(
        memberships: [ActiveOrganizationMembership],
        activeOrganizationID: UUID?,
        ready: Bool
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let previousReady = self.isOrganizationContextReady
            let previousActiveOrganizationID = self.activeOrganizationID

            if self.accessibleOrganizations != memberships {
                self.accessibleOrganizations = memberships
            }
            if self.activeOrganizationID != activeOrganizationID {
                self.activeOrganizationID = activeOrganizationID
                self.persistActiveOrganizationID()
            }
            if self.isOrganizationContextReady != ready {
                self.isOrganizationContextReady = ready
            }
            self.applyTenantScopedState()
            if ready, activeOrganizationID != nil {
                self.queuePendingSupabaseMediaBackfillIfNeeded(reason: "org_context_ready")
                if !previousReady {
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        await self.performRemoteConvergenceCycle(source: "launch")
                    }
                }
            }
        }
    }

#if DEBUG
    @MainActor
    func _debugSetOrganizationContextForTests(
        memberships: [ActiveOrganizationMembership],
        activeOrganizationID: UUID?,
        ready: Bool
    ) {
        // Test-only hook for delta apply/unit coverage. Keep this path state-only so
        // tests can control scheduling explicitly instead of inheriting app triggers.
        if accessibleOrganizations != memberships {
            accessibleOrganizations = memberships
        }
        if self.activeOrganizationID != activeOrganizationID {
            self.activeOrganizationID = activeOrganizationID
            persistActiveOrganizationID()
        }
        if isOrganizationContextReady != ready {
            isOrganizationContextReady = ready
        }
        applyTenantScopedState()
    }

    func _debugRefreshPropertiesLocallyForTests() {
        performLocalPropertyRefreshFallback()
    }
#endif

    private func handleOrganizationRefreshFailure() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let hasUsableContext = self.isOrganizationContextReady
                && self.activeOrganizationID != nil
                && !self.accessibleOrganizations.isEmpty
            guard !hasUsableContext else { return }
            self.clearOrganizationContext()
        }
    }

    private func clearOrganizationContext() {
        applyOrganizationContext(memberships: [], activeOrganizationID: nil, ready: !requiresAuthentication)
    }

    private func refreshOrganizationContext(for userID: UUID?) async throws {
        guard requiresAuthentication else {
            clearOrganizationContext()
            return
        }

        guard userID != nil, let client = supabaseClient else {
            clearOrganizationContext()
            return
        }

        await MainActor.run {
            let hasUsableContext = self.isOrganizationContextReady
                && self.activeOrganizationID != nil
                && !self.accessibleOrganizations.isEmpty
            if !hasUsableContext {
                self.isOrganizationContextReady = false
            }
        }

        let membershipRows = try await client
            .from("org_memberships")
            .select("org_id, role, deleted_at")
            .execute()
            .value as [SupabaseOrgMembershipRecord]

        let orgRows = try await client
            .from("orgs")
            .select("id, name, deleted_at")
            .execute()
            .value as [SupabaseAccessibleOrgRecord]

        let activeMemberships = membershipRows.filter { $0.deletedAt == nil }
        let namesByID = Dictionary(
            uniqueKeysWithValues: orgRows
                .filter { $0.deletedAt == nil }
                .map { ($0.id, $0.name) }
        )

        let memberships = activeMemberships
            .compactMap { row -> ActiveOrganizationMembership? in
                guard let name = namesByID[row.orgID] else { return nil }
                return ActiveOrganizationMembership(id: row.orgID, name: name, role: row.role)
            }
            .sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }

        let persistedID = persistedActiveOrganizationID(for: userID)
        let resolvedActiveID: UUID?
        if let persistedID,
           memberships.contains(where: { $0.id == persistedID }) {
            resolvedActiveID = persistedID
        } else {
            resolvedActiveID = memberships.first?.id
        }

        applyOrganizationContext(
            memberships: memberships,
            activeOrganizationID: resolvedActiveID,
            ready: true
        )
    }

    func setActiveOrganization(id: UUID) {
        if requiresAuthentication {
            guard accessibleOrganizations.contains(where: { $0.id == id }) else { return }
        } else {
            guard allOrganizations.contains(where: { $0.id == id }) else { return }
        }

        guard activeOrganizationID != id else { return }

        activeOrganizationID = id
        persistActiveOrganizationID()
        applyTenantScopedState()
        if isOrganizationContextReady {
            Task { @MainActor [weak self] in
                guard let self else { return }
                await performRemoteConvergenceCycle(source: "org_switch")
            }
        }
    }

    private func activeOrganizationDefaultsKey(for userID: UUID?) -> String {
        guard let userID else { return activeOrganizationDefaultsKeyPrefix }
        return "\(activeOrganizationDefaultsKeyPrefix).\(userID.uuidString.lowercased())"
    }

    private func persistedActiveOrganizationID(for userID: UUID?) -> UUID? {
        let rawID = userDefaults.string(forKey: activeOrganizationDefaultsKey(for: userID))
        return rawID.flatMap(UUID.init(uuidString:))
    }

    private func persistActiveOrganizationID() {
        let key = activeOrganizationDefaultsKey(for: authenticatedSupabaseUser?.id)
        if let activeOrganizationID {
            userDefaults.set(activeOrganizationID.uuidString, forKey: key)
        } else {
            userDefaults.removeObject(forKey: key)
        }
    }

    private func applyTenantScopedState() {
        let scopedOrganizations = scopedOrganizations(from: allOrganizations)
        let scopedProperties = scopedProperties(from: allProperties)
        let scopedPropertyIDs = Set(scopedProperties.map(\.id))
        let scopedSessionIndex = allSessionIndexByProperty.filter { scopedPropertyIDs.contains($0.key) }
        let scopedDrafts = allDraftSessionByProperty.filter { scopedPropertyIDs.contains($0.key) }
        let scopedPending = allPendingExportSessionByProperty.filter { scopedPropertyIDs.contains($0.key) }
        let scopedMeta = allHubMetaByProperty.filter { scopedPropertyIDs.contains($0.key) }

        if organizations != scopedOrganizations {
            organizations = scopedOrganizations
        }
        if properties != scopedProperties {
            properties = scopedProperties
        }
        if sessionIndexByProperty != scopedSessionIndex {
            sessionIndexByProperty = scopedSessionIndex
        }
        if draftSessionByProperty != scopedDrafts {
            draftSessionByProperty = scopedDrafts
        }
        if pendingExportSessionByProperty != scopedPending {
            pendingExportSessionByProperty = scopedPending
        }
        if hubMetaByProperty != scopedMeta {
            hubMetaByProperty = scopedMeta
        }

        if let selectedPropertyID,
           !scopedPropertyIDs.contains(selectedPropertyID) {
            self.selectedPropertyID = nil
            if currentSession?.propertyID == selectedPropertyID {
                clearCurrentSession()
            }
        }

        if let currentSession,
           !scopedPropertyIDs.contains(currentSession.propertyID) {
            clearCurrentSession()
        }
    }

    private func scopedOrganizations(from organizations: [Organization]) -> [Organization] {
        guard requiresAuthentication else { return organizations }
        guard let activeOrganizationID else { return [] }
        return organizations.filter { $0.id == activeOrganizationID }
    }

    private func scopedProperties(from properties: [Property]) -> [Property] {
        guard requiresAuthentication else { return properties }
        guard let activeOrganizationID else { return [] }
        return properties.filter { $0.orgId == activeOrganizationID }
    }

    private func canAccessOrganization(_ organizationID: UUID?) -> Bool {
        guard let organizationID else { return !requiresAuthentication }
        if requiresAuthentication {
            return organizationID == activeOrganizationID
        }
        return allOrganizations.contains(where: { $0.id == organizationID })
    }

    private func canAccessProperty(_ propertyID: UUID) -> Bool {
        properties.contains(where: { $0.id == propertyID })
    }

    private func ensureLocalOrganizationExists(for organizationID: UUID) throws {
        guard !allOrganizations.contains(where: { $0.id == organizationID }) else { return }
        guard let organization = organizationSelectionOptions.first(where: { $0.id == organizationID }) else {
            throw PropertyCreationError.missingOrganization
        }

        _ = try localStore.createOrganization(
            Organization(id: organization.id, name: organization.name, contacts: organization.contacts)
        )
        allOrganizations = (try? localStore.fetchOrganizations()) ?? allOrganizations
    }

    private func setAuthenticating(_ authenticating: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isAuthenticating = authenticating
        }
    }

    private func ensureCurrentUserProfileIfNeeded(for userID: UUID?, force: Bool = false) async throws {
        guard let userID, let client = supabaseClient else { return }
        let lastEnsuredUserProfileID = await MainActor.run { self.lastEnsuredUserProfileID }
        guard force || lastEnsuredUserProfileID != userID else { return }

        try await (try client.rpc("ensure_current_user_profile")).execute()
        await MainActor.run {
            self.lastEnsuredUserProfileID = userID
        }
    }

    func signIn(email: String, password: String) async throws {
        guard let client = supabaseClient else { return }

        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        setAuthenticating(true)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.authenticationErrorMessage = nil
        }
        defer { setAuthenticating(false) }

        do {
            let session = try await client.auth.signIn(email: trimmedEmail, password: password)
            try await ensureCurrentUserProfileIfNeeded(for: session.user.id, force: true)
        } catch {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.authenticationErrorMessage = error.localizedDescription
            }
            throw error
        }
    }

    func signUp(email: String, password: String) async throws -> AuthenticationFlowResult {
        guard let client = supabaseClient else { return .requiresEmailConfirmation }

        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        setAuthenticating(true)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.authenticationErrorMessage = nil
        }
        defer { setAuthenticating(false) }

        do {
            let response = try await client.auth.signUp(email: trimmedEmail, password: password)
            if let session = response.session {
                try await ensureCurrentUserProfileIfNeeded(for: session.user.id, force: true)
                return .signedIn
            }
            return .requiresEmailConfirmation
        } catch {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.authenticationErrorMessage = error.localizedDescription
            }
            throw error
        }
    }

    func signOut() async {
        guard let client = supabaseClient else { return }

        let orgIDsToClear = Set(accessibleOrganizations.map(\.id)).union(activeOrganizationID.map { [$0] } ?? [])

        setAuthenticating(true)
        defer { setAuthenticating(false) }

        do {
            try await client.auth.signOut(scope: .local)
            for orgID in orgIDsToClear {
                clearSyncCursors(orgID: orgID)
            }
        } catch {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.authenticationErrorMessage = error.localizedDescription
            }
        }
    }

    func uploadOperationalMediaIfNeeded(
        propertyID: UUID,
        sessionID: UUID,
        shotID: UUID
    ) {
        // 2C-08 keeps the existing local pending shot state when immediate media
        // upload is disabled; no alternate uploadState is introduced here.
        if backendFeatureFlags.cutoverPhase == .phaseB,
           backendFeatureFlags.supabaseEnabled,
           !backendFeatureFlags.mediaSupabaseUploadEnabled {
            print(
                "[CutoverMedia] result=skipped " +
                "reason=media_upload_disabled " +
                "phase=\(cutoverPhase.rawValue) " +
                "state_remains=pending " +
                "shotID=\(shotID.uuidString)"
            )
        }

        guard backendFeatureFlags.supabaseEnabled,
              backendFeatureFlags.mediaSupabaseUploadEnabled,
              supabaseClient != nil else {
            return
        }

        let operationKey = "upload|\(sessionID.uuidString.lowercased())|\(shotID.uuidString.lowercased())"
        guard beginSupabaseMediaOperation(operationKey) else { return }

        Task(priority: .utility) { [weak self] in
            defer { self?.endSupabaseMediaOperation(operationKey) }
            await self?.performOperationalMediaUpload(
                propertyID: propertyID,
                sessionID: sessionID,
                shotID: shotID
            )
        }
    }

    private func queuePendingSupabaseMediaBackfillIfNeeded(reason: String) {
        guard backendFeatureFlags.supabaseEnabled,
              backendFeatureFlags.mediaSupabaseUploadEnabled,
              supabaseClient != nil else {
            return
        }
        if requiresAuthentication &&
            (!isAuthenticationReady || !isOrganizationContextReady || activeOrganizationID == nil) {
            return
        }

        let now = Date()
        let launchAdjacentReasons: Set<String> = ["org_context_ready", "scene_active"]
        if launchAdjacentReasons.contains(reason),
           let previousAt = lastSupabaseMediaBackfillTriggerAt,
           let previousReason = lastSupabaseMediaBackfillTriggerReason,
           launchAdjacentReasons.contains(previousReason),
           now.timeIntervalSince(previousAt) < 3.0 {
            return
        }
        lastSupabaseMediaBackfillTriggerAt = now
        lastSupabaseMediaBackfillTriggerReason = reason

        Task(priority: .utility) { [weak self] in
            _ = await self?.runPendingSupabaseMediaBackfill(reason: reason)
        }
    }

    @discardableResult
    private func runPendingSupabaseMediaBackfill(reason: String) async -> SupabaseMediaBackfillRunSummary {
        guard beginSupabaseMediaBackfillRun() else {
            print("[SupabaseMediaBackfill] skipped reason=in_progress trigger=\(reason)")
            return SupabaseMediaBackfillRunSummary(
                didStart: false,
                reason: reason,
                discoveredCount: 0,
                excludedInFlightCount: 0,
                skippedRetryCapCount: 0,
                attemptedCount: 0
            )
        }
        defer { endSupabaseMediaBackfillRun() }

        let discovery = discoverPendingSupabaseMediaBackfillCandidates()
        print(
            "[SupabaseMediaBackfill] result=start " +
            "trigger=\(reason) " +
            "discovered=\(discovery.candidates.count) " +
            "excludedInFlight=\(discovery.excludedInFlightCount)"
        )

        var skippedRetryCapCount = 0
        var attemptedCount = 0

        for candidate in discovery.candidates {
            if candidate.uploadAttempts >= maximumSupabaseMediaUploadAttempts {
                skippedRetryCapCount += 1
                print(
                    "[SupabaseMediaBackfill] result=skipped " +
                    "reason=retry_cap " +
                    "shotID=\(candidate.shotID.uuidString) " +
                    "attempts=\(candidate.uploadAttempts) " +
                    "cap=\(maximumSupabaseMediaUploadAttempts)"
                )
                continue
            }

            let operationKey = supabaseUploadOperationKey(
                sessionID: candidate.sessionID,
                shotID: candidate.shotID
            )
            guard beginSupabaseMediaOperation(operationKey) else { continue }

            attemptedCount += 1
            print(
                "[SupabaseMediaBackfill] result=dispatch " +
                "shotID=\(candidate.shotID.uuidString) " +
                "state=\(candidate.uploadState) " +
                "attempts=\(candidate.uploadAttempts)"
            )

            await performOperationalMediaUpload(
                propertyID: candidate.propertyID,
                sessionID: candidate.sessionID,
                shotID: candidate.shotID
            )
            endSupabaseMediaOperation(operationKey)
        }

        print(
            "[SupabaseMediaBackfill] result=complete " +
            "trigger=\(reason) " +
            "discovered=\(discovery.candidates.count) " +
            "excludedInFlight=\(discovery.excludedInFlightCount) " +
            "skippedRetryCap=\(skippedRetryCapCount) " +
            "attempted=\(attemptedCount)"
        )

        return SupabaseMediaBackfillRunSummary(
            didStart: true,
            reason: reason,
            discoveredCount: discovery.candidates.count,
            excludedInFlightCount: discovery.excludedInFlightCount,
            skippedRetryCapCount: skippedRetryCapCount,
            attemptedCount: attemptedCount
        )
    }

    private func discoverPendingSupabaseMediaBackfillCandidates() -> (candidates: [PendingSupabaseMediaBackfillCandidate], excludedInFlightCount: Int) {
        let inFlightOperations = snapshotInFlightSupabaseMediaOperations()
        let properties = ((try? localStore.fetchProperties()) ?? [])
            .sorted { $0.id.uuidString < $1.id.uuidString }

        var candidates: [PendingSupabaseMediaBackfillCandidate] = []
        var excludedInFlightCount = 0

        for property in properties {
            if requiresAuthentication,
               isOrganizationContextReady,
               let activeOrganizationID,
               property.orgId != activeOrganizationID {
                continue
            }

            let sessions = ((try? localStore.fetchSessions(propertyID: property.id)) ?? [])
                .sorted {
                    if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
                    return $0.id.uuidString < $1.id.uuidString
                }

            for session in sessions {
                guard let metadata = try? localStore.loadSessionMetadata(propertyID: property.id, sessionID: session.id) else {
                    continue
                }

                let orderedShots = metadata.shots.sorted {
                    if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                    return $0.shotID.uuidString < $1.shotID.uuidString
                }

                for shot in orderedShots {
                    let isEligibleFailedRetry =
                        shot.uploadState == "failed" &&
                        Date().timeIntervalSince(shot.updatedAt) >= failedSupabaseMediaRetryCooldown
                    guard shot.uploadState == "pending" ||
                            shot.uploadState == "uploading" ||
                            isEligibleFailedRetry else {
                        continue
                    }

                    let operationKey = supabaseUploadOperationKey(
                        sessionID: session.id,
                        shotID: shot.shotID
                    )
                    if inFlightOperations.contains(operationKey) {
                        excludedInFlightCount += 1
                        continue
                    }

                    candidates.append(
                        PendingSupabaseMediaBackfillCandidate(
                            propertyID: property.id,
                            sessionID: session.id,
                            shotID: shot.shotID,
                            uploadState: shot.uploadState,
                            uploadAttempts: shot.uploadAttempts
                        )
                    )
                }
            }
        }

        return (candidates, excludedInFlightCount)
    }

    func ensureOperationalMediaAvailable(
        propertyID: UUID,
        sessionID: UUID,
        shotID: UUID
    ) {
        Task(priority: .utility) { [weak self] in
            _ = await self?.ensureOperationalMediaAvailableIfNeeded(
                propertyID: propertyID,
                sessionID: sessionID,
                shotID: shotID
            )
        }
    }

    func ensureOperationalMediaAvailableForSession(
        propertyID: UUID,
        sessionID: UUID
    ) {
        guard backendFeatureFlags.supabaseEnabled,
              backendFeatureFlags.supabaseReadEnabled else {
            return
        }

        guard let metadata = try? localStore.loadSessionMetadata(propertyID: propertyID, sessionID: sessionID) else {
            return
        }

        for shot in metadata.shots {
            ensureOperationalMediaAvailable(
                propertyID: propertyID,
                sessionID: sessionID,
                shotID: shot.shotID
            )
        }
    }

    func ensureOperationalMediaAvailableForRequests(
        _ requests: [OperationalMediaHydrationRequest]
    ) async -> Bool {
        let uniqueRequests = Array(Set(requests))
        guard !uniqueRequests.isEmpty else { return false }

        var startedAny = false
        await withTaskGroup(of: Bool.self) { group in
            for request in uniqueRequests {
                group.addTask { [weak self] in
                    guard let self else { return false }
                    return await self.ensureOperationalMediaAvailableIfNeeded(
                        propertyID: request.propertyID,
                        sessionID: request.sessionID,
                        shotID: request.shotID
                    )
                }
            }

            for await didStart in group {
                if didStart {
                    startedAny = true
                }
            }
        }

        return startedAny
    }

    private func ensureOperationalMediaAvailableIfNeeded(
        propertyID: UUID,
        sessionID: UUID,
        shotID: UUID
    ) async -> Bool {
        guard backendFeatureFlags.supabaseEnabled,
              backendFeatureFlags.supabaseReadEnabled,
              supabaseClient != nil else {
            return false
        }

        let operationKey = "download|\(sessionID.uuidString.lowercased())|\(shotID.uuidString.lowercased())"
        guard beginSupabaseMediaOperation(operationKey) else { return false }
        defer { endSupabaseMediaOperation(operationKey) }

        await performOperationalMediaHydration(
            propertyID: propertyID,
            sessionID: sessionID,
            shotID: shotID
        )
        return true
    }

    private var isPhaseBMetadataShadowWriteEnabled: Bool {
        backendFeatureFlags.cutoverPhase == .phaseB &&
        backendFeatureFlags.shadowWriteEnabled
    }

    private func syncCursorDefaultsKey(entity: String, orgID: UUID) -> String {
        "scoutcapture.syncCursor.\(entity).\(orgID.uuidString.lowercased())"
    }

    private func readSyncCursor(entity: String, orgID: UUID) -> Date? {
        let key = syncCursorDefaultsKey(entity: entity, orgID: orgID)
        guard userDefaults.object(forKey: key) != nil else { return nil }
        return Date(timeIntervalSinceReferenceDate: userDefaults.double(forKey: key))
    }

    private func writeSyncCursor(entity: String, orgID: UUID, date: Date) {
        let key = syncCursorDefaultsKey(entity: entity, orgID: orgID)
        userDefaults.set(date.timeIntervalSinceReferenceDate, forKey: key)
    }

    private func clearSyncCursors(orgID: UUID) {
        userDefaults.removeObject(forKey: syncCursorDefaultsKey(entity: "properties", orgID: orgID))
        userDefaults.removeObject(forKey: syncCursorDefaultsKey(entity: "sessions", orgID: orgID))
    }

    private func advanceSyncCursor(entity: String, orgID: UUID, updatedAts: [Date]) {
        guard let batchMax = updatedAts.max() else { return }
        let current = readSyncCursor(entity: entity, orgID: orgID) ?? .distantPast
        writeSyncCursor(entity: entity, orgID: orgID, date: max(current, batchMax))
    }

    private func supabaseTimestampString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func parseSupabaseDateString(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = formatter.date(from: trimmed) {
            return parsed
        }

        let fallbackFormatter = ISO8601DateFormatter()
        fallbackFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        fallbackFormatter.formatOptions = [.withInternetDateTime]
        return fallbackFormatter.date(from: trimmed)
    }

    private func propertyFromSyncDeltaRecord(
        _ record: RemotePropertyDeltaRecord,
        createdAt: Date
    ) -> Property {
        let trimmedAddressLine1 = normalizedRemotePropertyText(record.addressLine1)
        let trimmedCity = normalizedRemotePropertyText(record.city)
        let trimmedState = normalizedRemotePropertyText(record.state)
        let trimmedPostalCode = normalizedRemotePropertyText(record.postalCode)
        let addressParts = [
            trimmedAddressLine1,
            [trimmedCity, trimmedState].compactMap { $0 }.joined(separator: ", "),
            trimmedPostalCode
        ].compactMap { value -> String? in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }

        return Property(
            id: record.id,
            orgId: record.orgID,
            folderId: normalizedRemotePropertyText(record.folderID),
            clientName: normalizedRemotePropertyText(record.clientName),
            clientPhone: normalizedRemotePropertyText(record.clientPhone),
            clientEmail: normalizedRemotePropertyText(record.clientEmail),
            name: record.name.trimmingCharacters(in: .whitespacesAndNewlines),
            address: addressParts.joined(separator: ", "),
            street: trimmedAddressLine1,
            city: trimmedCity,
            state: trimmedState,
            zip: trimmedPostalCode,
            baselineSessionID: record.baselineSessionID,
            isArchived: record.deletedAt != nil ? true : record.isArchived,
            createdAt: createdAt,
            updatedAt: record.updatedAt
        )
    }

    private func fetchSyncDelta(
        orgID: UUID,
        propertyCursor: Date?,
        sessionCursor: Date?
    ) async throws -> ([RemotePropertyDeltaRecord], [RemoteSessionDeltaRecord]) {
        guard let client = supabaseClient else {
            return ([], [])
        }

        let orgValue = orgID.uuidString.lowercased()

        async let propertyFetch: [RemotePropertyDeltaRecord] = {
            var query = client
                .from("properties")
                .select("id, org_id, folder_id, client_name, client_email, client_phone, name, address_line1, city, state, postal_code, baseline_session_id, is_archived, created_at, updated_at, deleted_at")
                .eq("org_id", value: orgValue)
            if let propertyCursor {
                query = query.gt("updated_at", value: supabaseTimestampString(propertyCursor))
            }
            return try await query
                .order("updated_at", ascending: true)
                .limit(500)
                .execute()
                .value as [RemotePropertyDeltaRecord]
        }()

        async let sessionFetch: [RemoteSessionDeltaRecord] = {
            var query = client
                .from("sessions")
                .select("id, org_id, property_id, title, status, started_at, completed_at, updated_at, deleted_at")
                .eq("org_id", value: orgValue)
            if let sessionCursor {
                query = query.gt("updated_at", value: supabaseTimestampString(sessionCursor))
            }
            return try await query
                .order("updated_at", ascending: true)
                .limit(500)
                .execute()
                .value as [RemoteSessionDeltaRecord]
        }()

        return try await (propertyFetch, sessionFetch)
    }

    @discardableResult
    private func applySyncDeltaProperties(
        records: [RemotePropertyDeltaRecord],
        orgID: UUID
    ) -> (applied: Int, skipped: Int) {
        guard !records.isEmpty else { return (0, 0) }

        var applied = 0
        var skipped = 0
        var didMutateProperties = false

        for record in records where record.orgID == orgID {
            let existingIndex = allProperties.firstIndex(where: { $0.id == record.id })
            let existingProperty = existingIndex.flatMap { allProperties[$0] }
            if let existingProperty,
               existingProperty.updatedAt >= record.updatedAt {
                skipped += 1
                if existingProperty.updatedAt > record.updatedAt {
                    print(
                        "[SyncApply] conflictsDetected=1 " +
                        "reason=local_property_newer " +
                        "propertyID=\(record.id.uuidString) " +
                        "orgID=\(orgID.uuidString)"
                    )
                }
                continue
            }

            let createdAt = existingProperty?.createdAt ?? record.createdAt
            let candidate = propertyFromSyncDeltaRecord(record, createdAt: createdAt)

            do {
                let persisted: Property
                if existingProperty != nil {
                    persisted = try localStore.updateProperty(candidate)
                } else {
                    persisted = try localStore.createProperty(candidate)
                }

                var canonical = persisted
                canonical.orgId = candidate.orgId
                canonical.folderId = candidate.folderId
                canonical.clientName = candidate.clientName
                canonical.clientPhone = candidate.clientPhone
                canonical.clientEmail = candidate.clientEmail
                canonical.name = candidate.name
                canonical.address = candidate.address
                canonical.street = candidate.street
                canonical.city = candidate.city
                canonical.state = candidate.state
                canonical.zip = candidate.zip
                canonical.baselineSessionID = candidate.baselineSessionID
                canonical.isArchived = candidate.isArchived
                canonical.createdAt = candidate.createdAt
                canonical.updatedAt = candidate.updatedAt

                if let existingIndex {
                    allProperties[existingIndex] = canonical
                } else {
                    allProperties.append(canonical)
                }

                applied += 1
                didMutateProperties = true
            } catch LocalStore.StoreError.propertyNotFound {
                do {
                    let persisted = try localStore.createProperty(candidate)
                    var canonical = persisted
                    canonical.createdAt = candidate.createdAt
                    canonical.updatedAt = candidate.updatedAt
                    allProperties.append(canonical)
                    applied += 1
                    didMutateProperties = true
                } catch {
                    skipped += 1
                    print(
                        "[SyncApply] action=property_upsert_failed " +
                        "propertyID=\(record.id.uuidString) " +
                        "orgID=\(orgID.uuidString) " +
                        "reason=\(error.localizedDescription)"
                    )
                }
            } catch {
                skipped += 1
                print(
                    "[SyncApply] action=property_upsert_failed " +
                    "propertyID=\(record.id.uuidString) " +
                    "orgID=\(orgID.uuidString) " +
                    "reason=\(error.localizedDescription)"
                )
            }
        }

        guard didMutateProperties else {
            return (applied, skipped)
        }

        allProperties.sort(by: Self.propertyIsOrderedBefore)
        allOrganizations = (try? localStore.fetchOrganizations()) ?? allOrganizations

        // `LocalStore.updateProperty()` rewrites updatedAt to "now"; repair the
        // persisted property list once per batch so future delta comparisons remain deterministic.
        do {
            try localStore.replacePropertyListCacheAtomically(
                properties: allProperties,
                organizations: allOrganizations
            )
        } catch {
            print(
                "[SyncApply] action=property_batch_repair_failed " +
                "orgID=\(orgID.uuidString) " +
                "reason=\(error.localizedDescription)"
            )
        }

        return (applied, skipped)
    }

    @discardableResult
    private func applySyncDeltaSessions(
        records: [RemoteSessionDeltaRecord],
        orgID: UUID
    ) -> (applied: Int, skipped: Int) {
        guard !records.isEmpty else { return (0, 0) }

        var applied = 0
        var skipped = 0

        for record in records where record.orgID == orgID {
            guard allProperties.contains(where: { $0.id == record.propertyID }) else {
                skipped += 1
                print(
                    "[SyncApply] action=session_skipped " +
                    "sessionID=\(record.id.uuidString) " +
                    "reason=unknown_property"
                )
                continue
            }
            guard record.deletedAt == nil else {
                skipped += 1
                print(
                    "[SyncApply] action=session_skipped " +
                    "sessionID=\(record.id.uuidString) " +
                    "reason=soft_deleted"
                )
                continue
            }
            guard let startedAt = parseSupabaseDateString(record.startedAt) else {
                skipped += 1
                print(
                    "[SyncApply] action=session_skipped " +
                    "sessionID=\(record.id.uuidString) " +
                    "reason=invalid_started_at"
                )
                continue
            }

            let endedAt = record.completedAt.flatMap(parseSupabaseDateString)
            let normalizedStatus = record.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let session = Session(
                id: record.id,
                propertyID: record.propertyID,
                startedAt: startedAt,
                status: Session.Status(rawValue: normalizedStatus) ?? .draft,
                endedAt: endedAt
            )

            do {
                _ = try localStore.upsertSession(session)
                applied += 1
            } catch {
                skipped += 1
                print(
                    "[SyncApply] action=session_upsert_failed " +
                    "sessionID=\(record.id.uuidString) " +
                    "reason=\(error.localizedDescription)"
                )
            }
        }

        return (applied, skipped)
    }

    @MainActor
    private func performSyncDeltaPull(source: String) async {
        guard isSyncDeltaEnabled else { return }
        guard !isSyncDeltaPullInFlight else {
            print("[SyncDeltaPull] skipped source=\(source) reason=in_flight")
            return
        }
        if source == "foreground",
           let lastForegroundSyncDeltaCompletedAt,
           Date().timeIntervalSince(lastForegroundSyncDeltaCompletedAt) < 30 {
            print("[SyncDeltaPull] skipped source=\(source) reason=cooldown")
            return
        }
        guard let orgID = activeOrganizationID else { return }

        isSyncDeltaPullInFlight = true
        let startedAt = Date()
        defer { isSyncDeltaPullInFlight = false }

        let propertyCursor = readSyncCursor(entity: "properties", orgID: orgID)
        let sessionCursor = readSyncCursor(entity: "sessions", orgID: orgID)

        print(
            "[SyncDeltaPull] start " +
            "source=\(source) " +
            "orgID=\(orgID.uuidString) " +
            "propertyCursor=\(propertyCursor.map { supabaseTimestampString($0) } ?? "nil") " +
            "sessionCursor=\(sessionCursor.map { supabaseTimestampString($0) } ?? "nil")"
        )
        print(
            "[SyncConvergence] start " +
            "source=\(source) " +
            "orgID=\(orgID.uuidString)"
        )

        let propertyRecords: [RemotePropertyDeltaRecord]
        let sessionRecords: [RemoteSessionDeltaRecord]
        do {
            #if DEBUG
            if let syncDeltaFetchOverride {
                (propertyRecords, sessionRecords) = try await syncDeltaFetchOverride(
                    orgID,
                    propertyCursor,
                    sessionCursor
                )
            } else {
                (propertyRecords, sessionRecords) = try await fetchSyncDelta(
                    orgID: orgID,
                    propertyCursor: propertyCursor,
                    sessionCursor: sessionCursor
                )
            }
            #else
            (propertyRecords, sessionRecords) = try await fetchSyncDelta(
                orgID: orgID,
                propertyCursor: propertyCursor,
                sessionCursor: sessionCursor
            )
            #endif
        } catch {
            print("[SyncDeltaPull] error source=\(source) error=\(error.localizedDescription)")
            return
        }

        let propertyResult = applySyncDeltaProperties(records: propertyRecords, orgID: orgID)
        let sessionResult = applySyncDeltaSessions(records: sessionRecords, orgID: orgID)
        let totalApplied = propertyResult.applied + sessionResult.applied

        if totalApplied > 0 {
            let caches = makeHubCaches(for: allProperties)
            applyHubCachePayload(
                properties: allProperties,
                organizations: allOrganizations,
                caches: caches
            )
        }

        advanceSyncCursor(entity: "properties", orgID: orgID, updatedAts: propertyRecords.map(\.updatedAt))
        advanceSyncCursor(entity: "sessions", orgID: orgID, updatedAts: sessionRecords.map(\.updatedAt))
        if source == "foreground" {
            lastForegroundSyncDeltaCompletedAt = Date()
        }

        if propertyRecords.isEmpty && sessionRecords.isEmpty {
            print("[SyncDeltaPull] no_op source=\(source)")
        }

        let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        print(
            "[SyncDeltaPull] complete " +
            "source=\(source) " +
            "orgID=\(orgID.uuidString) " +
            "propertyCount=\(propertyRecords.count) " +
            "sessionCount=\(sessionRecords.count) " +
            "applied=\(totalApplied) " +
            "skipped=\(propertyResult.skipped + sessionResult.skipped) " +
            "elapsedMs=\(elapsedMs)"
        )
        print(
            "[SyncConvergence] end " +
            "source=\(source) " +
            "orgID=\(orgID.uuidString) " +
            "elapsedMs=\(elapsedMs)"
        )
    }

    @MainActor
    private func performRemoteConvergenceCycle(source: String) async {
        _ = await performOfflineReplay(source: source)
        await performSyncDeltaPull(source: source)
    }

    private func offlineReplayNotReadySummary(source: String, reason: String) -> OfflineReplayRunSummary {
        print("[OfflineReplay] skipped source=\(source) reason=not_ready detail=\(reason)")
        return OfflineReplayRunSummary(
            didStart: false,
            source: source,
            discoveredCount: 0,
            normalizedInFlightCount: 0,
            skippedBackoffCount: 0,
            attemptedCount: 0,
            succeededCount: 0,
            failedCount: 0
        )
    }

    @MainActor
    private func performOfflineReplay(source: String) async -> OfflineReplayRunSummary {
        guard isPhaseBMetadataShadowWriteEnabled,
              backendFeatureFlags.supabaseEnabled,
              backendFeatureFlags.shadowWriteEnabled else {
            return offlineReplayNotReadySummary(source: source, reason: "disabled")
        }
        guard isOrganizationContextReady else {
            return offlineReplayNotReadySummary(source: source, reason: "organization_context")
        }
        guard let orgID = activeOrganizationID else {
            return offlineReplayNotReadySummary(source: source, reason: "missing_org")
        }
        guard supabaseClient != nil else {
            return offlineReplayNotReadySummary(source: source, reason: "missing_client")
        }
        if requiresAuthentication && (!isAuthenticationReady || authenticatedSupabaseUser == nil) {
            return offlineReplayNotReadySummary(source: source, reason: "authentication")
        }
        guard beginOfflineReplayRun() else {
            print("[OfflineReplay] skipped source=\(source) reason=in_flight")
            return OfflineReplayRunSummary(
                didStart: false,
                source: source,
                discoveredCount: 0,
                normalizedInFlightCount: 0,
                skippedBackoffCount: 0,
                attemptedCount: 0,
                succeededCount: 0,
                failedCount: 0
            )
        }

        let startedAt = Date()
        defer { endOfflineReplayRun() }

        var normalizedInFlightCount = 0
        do {
            let queuedMutations = try localStore.fetchQueuedMutations()
            for item in queuedMutations where item.status == .inFlight {
                var normalized = item
                normalized.status = .pending
                normalized.updatedAt = Date()
                normalizedInFlightCount += 1
                try localStore.updateQueuedMutation(normalized)
            }
        } catch {
            print("[OfflineReplay] skipped source=\(source) reason=queue_read_failed error=\(error.localizedDescription)")
            return OfflineReplayRunSummary(
                didStart: false,
                source: source,
                discoveredCount: 0,
                normalizedInFlightCount: 0,
                skippedBackoffCount: 0,
                attemptedCount: 0,
                succeededCount: 0,
                failedCount: 0
            )
        }

        let queuedMutations: [LocalStore.QueuedMutation]
        do {
            queuedMutations = try localStore.fetchQueuedMutations()
        } catch {
            print("[OfflineReplay] skipped source=\(source) reason=queue_read_failed error=\(error.localizedDescription)")
            return OfflineReplayRunSummary(
                didStart: false,
                source: source,
                discoveredCount: 0,
                normalizedInFlightCount: normalizedInFlightCount,
                skippedBackoffCount: 0,
                attemptedCount: 0,
                succeededCount: 0,
                failedCount: 0
            )
        }

        let orgMutations = queuedMutations.filter { $0.organizationID == orgID && $0.status != .completed }
        let now = Date()
        var skippedBackoffCount = 0
        let replayable = orgMutations.filter { mutation in
            if mutation.status == .failed,
               let nextAttemptAt = mutation.nextAttemptAt,
               now < nextAttemptAt {
                skippedBackoffCount += 1
                return false
            }
            return shouldReplayMutation(mutation, now: now)
        }
        .sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt < rhs.createdAt
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }

        print(
            "[OfflineReplay] start " +
            "source=\(source) " +
            "orgID=\(orgID.uuidString) " +
            "discoveredCount=\(orgMutations.count) " +
            "eligibleCount=\(replayable.count) " +
            "normalizedInFlightCount=\(normalizedInFlightCount)"
        )

        var attemptedCount = 0
        var succeededCount = 0
        var failedCount = 0

        for item in replayable {
            var inFlightItem = item
            inFlightItem.status = .inFlight
            inFlightItem.updatedAt = Date()

            do {
                try localStore.updateQueuedMutation(inFlightItem)
            } catch {
                print(
                    "[OfflineReplay] item_failure " +
                    "source=\(source) " +
                    "queueItemID=\(item.id.uuidString) " +
                    "entityType=\(item.entityType) " +
                    "entityID=\(item.entityID.uuidString) " +
                    "operation=\(item.operation) " +
                    "error=\(error.localizedDescription)"
                )
                failedCount += 1
                continue
            }

            attemptedCount += 1
            print(
                "[OfflineReplay] item_dispatch " +
                "source=\(source) " +
                "orgID=\(orgID.uuidString) " +
                "queueItemID=\(item.id.uuidString) " +
                "entityType=\(item.entityType) " +
                "entityID=\(item.entityID.uuidString) " +
                "operation=\(item.operation) " +
                "attemptCount=\(item.attemptCount)"
            )

            let attemptStartedAt = Date()
            do {
                switch item.operation {
                case "upsert_property":
                    let decodedPayload = try JSONDecoder().decode(
                        QueuedPropertyMutationPayload.self,
                        from: item.payloadData
                    )
                    let payload = canonicalQueuedPropertyPayload(
                        decodedPayload.property,
                        queueItem: item
                    )
                    let property = queuedPropertyFromPayload(payload.property, queueItem: item)
                    try await performQueuedPropertyRemoteWrite(property: property, payload: payload.property)
                    await reconcilePropertyShadowWrite(
                        propertyID: property.id,
                        orgID: property.orgId ?? item.organizationID,
                        localUpdatedAt: property.updatedAt
                    )
                case "upsert_session":
                    let payload = try JSONDecoder().decode(
                        QueuedSessionMutationPayload.self,
                        from: item.payloadData
                    )
                    let property = queuedPropertyFromPayload(payload.property, queueItem: item)
                    let session = queuedSessionFromPayload(payload, queueItem: item)
                    let metadata = queuedSessionMetadataFromPayload(payload, session: session)
                    try await performQueuedSessionRemoteWrite(
                        property: property,
                        session: session,
                        metadata: metadata,
                        payload: payload
                    )
                    await reconcileSessionShadowWrite(
                        sessionID: session.id,
                        propertyID: session.propertyID,
                        orgID: property.orgId ?? item.organizationID,
                        localUpdatedAt: localSessionShadowWriteTimestamp(session)
                    )
                default:
                    throw NSError(
                        domain: "ScoutCapture.OfflineReplay",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Unsupported queued operation: \(item.operation)"]
                    )
                }

                try localStore.removeQueuedMutation(id: item.id)
                succeededCount += 1
                let elapsedMs = Int(Date().timeIntervalSince(attemptStartedAt) * 1000)
                print(
                    "[OfflineReplay] item_success " +
                    "source=\(source) " +
                    "queueItemID=\(item.id.uuidString) " +
                    "entityType=\(item.entityType) " +
                    "entityID=\(item.entityID.uuidString) " +
                    "operation=\(item.operation) " +
                    "elapsedMs=\(elapsedMs)"
                )
                print(
                    "[OfflineQueue] result=removed_after_success " +
                    "queueItemID=\(item.id.uuidString) " +
                    "entityType=\(item.entityType) " +
                    "entityID=\(item.entityID.uuidString) " +
                    "operation=\(item.operation)"
                )
            } catch {
                failedCount += 1
                var failedItem = inFlightItem
                failedItem.attemptCount += 1
                failedItem.lastAttemptAt = Date()
                failedItem.nextAttemptAt = failedItem.lastAttemptAt?.addingTimeInterval(
                    offlineReplayBackoffInterval(forAttemptCount: failedItem.attemptCount)
                )
                failedItem.lastError = error.localizedDescription
                failedItem.status = .failed
                failedItem.updatedAt = Date()
                try? localStore.updateQueuedMutation(failedItem)
                print(
                    "[OfflineReplay] item_failure " +
                    "source=\(source) " +
                    "queueItemID=\(item.id.uuidString) " +
                    "entityType=\(item.entityType) " +
                    "entityID=\(item.entityID.uuidString) " +
                    "operation=\(item.operation) " +
                    "attemptCount=\(failedItem.attemptCount) " +
                    "nextAttemptAt=\(failedItem.nextAttemptAt.map { supabaseTimestampString($0) } ?? "nil") " +
                    "error=\(error.localizedDescription)"
                )
                print(
                    "[OfflineQueue] result=failed " +
                    "queueItemID=\(item.id.uuidString) " +
                    "entityType=\(item.entityType) " +
                    "entityID=\(item.entityID.uuidString) " +
                    "operation=\(item.operation) " +
                    "nextAttemptAt=\(failedItem.nextAttemptAt.map { supabaseTimestampString($0) } ?? "nil")"
                )
            }
        }

        let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        print(
            "[OfflineReplay] complete " +
            "source=\(source) " +
            "orgID=\(orgID.uuidString) " +
            "discoveredCount=\(orgMutations.count) " +
            "normalizedInFlightCount=\(normalizedInFlightCount) " +
            "skippedBackoffCount=\(skippedBackoffCount) " +
            "attemptedCount=\(attemptedCount) " +
            "succeededCount=\(succeededCount) " +
            "failedCount=\(failedCount) " +
            "elapsedMs=\(elapsedMs)"
        )

        return OfflineReplayRunSummary(
            didStart: true,
            source: source,
            discoveredCount: orgMutations.count,
            normalizedInFlightCount: normalizedInFlightCount,
            skippedBackoffCount: skippedBackoffCount,
            attemptedCount: attemptedCount,
            succeededCount: succeededCount,
            failedCount: failedCount
        )
    }

    private func reconcilePropertyShadowWrite(
        propertyID: UUID,
        orgID: UUID,
        localUpdatedAt: Date
    ) async {
        guard let client = supabaseClient else { return }

        do {
            let rows = try await client
                .from("properties")
                .select("id, updated_at")
                .eq("id", value: propertyID.uuidString.lowercased())
                .eq("org_id", value: orgID.uuidString.lowercased())
                .limit(1)
                .execute()
                .value as [SupabaseRowUpdatedAtRecord]

            if let remote = rows.first,
               remote.updatedAt < localUpdatedAt {
                print("[SyncApply] conflictsDetected=1 reason=post_write_divergence")
            }
        } catch {
            // Intentionally fire-and-forget with no retries or UI.
        }
    }

    private func localSessionShadowWriteTimestamp(_ session: Session) -> Date {
        [
            session.startedAt,
            session.endedAt,
            session.exportedAt,
            session.firstDeliveredAt,
            session.reExportExpiresAt
        ]
        .compactMap { $0 }
        .max() ?? session.startedAt
    }

    private func reconcileSessionShadowWrite(
        sessionID: UUID,
        propertyID: UUID,
        orgID: UUID,
        localUpdatedAt: Date
    ) async {
        guard let client = supabaseClient else { return }

        do {
            let rows = try await client
                .from("sessions")
                .select("id, updated_at")
                .eq("id", value: sessionID.uuidString.lowercased())
                .eq("org_id", value: orgID.uuidString.lowercased())
                .eq("property_id", value: propertyID.uuidString.lowercased())
                .limit(1)
                .execute()
                .value as [SupabaseRowUpdatedAtRecord]

            if let remote = rows.first,
               remote.updatedAt < localUpdatedAt {
                print("[SyncApply] conflictsDetected=1 reason=post_write_divergence")
            }
        } catch {
            // Intentionally fire-and-forget with no retries or UI.
        }
    }

    private func propertyReplayIdempotencyKey(for property: Property) -> String? {
        guard let orgID = property.orgId else { return nil }
        let updatedAt = property.updatedAt.timeIntervalSinceReferenceDate
        return "property:\(orgID.uuidString.lowercased()):\(property.id.uuidString.lowercased()):\(updatedAt)"
    }

    private func sessionReplayIdempotencyKey(
        session: Session,
        metadata: SessionMetadata,
        orgID: UUID
    ) -> String {
        let shadowTimestamp = localSessionShadowWriteTimestamp(session).timeIntervalSinceReferenceDate
        return [
            "session",
            orgID.uuidString.lowercased(),
            session.id.uuidString.lowercased(),
            String(session.startedAt.timeIntervalSinceReferenceDate),
            metadata.status.rawValue,
            String(shadowTimestamp)
        ]
        .joined(separator: ":")
    }

    private func makeQueuedPropertyMutation(for property: Property) throws -> LocalStore.QueuedMutation? {
        guard let orgID = property.orgId,
              let idempotencyKey = propertyReplayIdempotencyKey(for: property) else {
            return nil
        }

        let payload = QueuedPropertyMutationPayload(
            property: makeSupabasePropertyPayload(
                propertyID: property.id,
                orgID: orgID,
                property: property,
                metadata: nil
            )
        )

        return LocalStore.QueuedMutation(
            entityType: "property",
            entityID: property.id,
            organizationID: orgID,
            propertyID: property.id,
            sessionID: nil,
            operation: "upsert_property",
            payloadData: try JSONEncoder().encode(payload),
            idempotencyKey: idempotencyKey
        )
    }

    private func makeQueuedSessionMutation(
        property: Property,
        session: Session,
        metadata: SessionMetadata
    ) throws -> LocalStore.QueuedMutation? {
        guard let orgID = property.orgId else { return nil }

        let payload = QueuedSessionMutationPayload(
            property: makeSupabasePropertyPayload(
                propertyID: property.id,
                orgID: orgID,
                property: property,
                metadata: metadata
            ),
            session: makeSupabaseSessionPayload(
                sessionID: session.id,
                propertyID: property.id,
                orgID: orgID,
                property: property,
                metadata: metadata
            )
        )

        return LocalStore.QueuedMutation(
            entityType: "session",
            entityID: session.id,
            organizationID: orgID,
            propertyID: property.id,
            sessionID: session.id,
            operation: "upsert_session",
            payloadData: try JSONEncoder().encode(payload),
            idempotencyKey: sessionReplayIdempotencyKey(session: session, metadata: metadata, orgID: orgID)
        )
    }

    private func enqueueOfflineMutation(
        _ mutation: LocalStore.QueuedMutation,
        reason: String
    ) {
        do {
            let beforeCount = try localStore.fetchQueuedMutations().count
            let persisted = try localStore.appendQueuedMutation(mutation)
            let afterCount = try localStore.fetchQueuedMutations().count
            let result = afterCount == beforeCount ? "deduplicated" : "enqueued"
            print(
                "[OfflineQueue] result=\(result) " +
                "reason=\(reason) " +
                "orgID=\(persisted.organizationID.uuidString) " +
                "queueItemID=\(persisted.id.uuidString) " +
                "entityType=\(persisted.entityType) " +
                "entityID=\(persisted.entityID.uuidString) " +
                "operation=\(persisted.operation) " +
                "idempotencyKey=\(persisted.idempotencyKey)"
            )
        } catch {
            print(
                "[OfflineQueue] result=failed " +
                "reason=\(reason) " +
                "entityType=\(mutation.entityType) " +
                "entityID=\(mutation.entityID.uuidString) " +
                "operation=\(mutation.operation) " +
                "error=\(error.localizedDescription)"
            )
        }
    }

    private func removeQueuedMutationIfPresent(
        idempotencyKey: String,
        reason: String
    ) {
        do {
            let queuedMutations = try localStore.fetchQueuedMutations()
            guard let existing = queuedMutations.first(where: {
                $0.idempotencyKey == idempotencyKey && $0.status != .completed
            }) else {
                return
            }

            try localStore.removeQueuedMutation(id: existing.id)
            print(
                "[OfflineQueue] result=removed_after_direct_success " +
                "reason=\(reason) " +
                "queueItemID=\(existing.id.uuidString) " +
                "entityType=\(existing.entityType) " +
                "entityID=\(existing.entityID.uuidString) " +
                "operation=\(existing.operation) " +
                "idempotencyKey=\(existing.idempotencyKey)"
            )
        } catch {
            print(
                "[OfflineQueue] result=remove_failed " +
                "reason=\(reason) " +
                "idempotencyKey=\(idempotencyKey) " +
                "error=\(error.localizedDescription)"
            )
        }
    }

    private func remoteMutationPathAvailable(for orgID: UUID) -> Bool {
        guard isPhaseBMetadataShadowWriteEnabled,
              backendFeatureFlags.supabaseEnabled,
              backendFeatureFlags.shadowWriteEnabled,
              supabaseClient != nil,
              isOrganizationContextReady,
              activeOrganizationID == orgID else {
            return false
        }

        if requiresAuthentication {
            return isAuthenticationReady && authenticatedSupabaseUser != nil
        }

        return true
    }

    private func offlineReplayBackoffInterval(forAttemptCount attemptCount: Int) -> TimeInterval {
        switch attemptCount {
        case ...0:
            return 0
        case 1:
            return 30
        case 2:
            return 120
        case 3:
            return 600
        default:
            return 1800
        }
    }

    private func beginOfflineReplayRun() -> Bool {
        offlineReplayStateQueue.sync {
            if isOfflineReplayInFlight {
                return false
            }
            isOfflineReplayInFlight = true
            return true
        }
    }

    private func endOfflineReplayRun() {
        let _: Void = offlineReplayStateQueue.sync {
            isOfflineReplayInFlight = false
        }
    }

    private func shouldReplayMutation(_ mutation: LocalStore.QueuedMutation, now: Date) -> Bool {
        switch mutation.status {
        case .pending:
            return true
        case .failed:
            return mutation.nextAttemptAt.map { now >= $0 } ?? true
        case .inFlight, .completed:
            return false
        }
    }

    private func performQueuedPropertyRemoteWrite(
        property: Property,
        payload: SupabasePropertyPayload
    ) async throws {
        if let propertyShadowWriteOverride {
            try await propertyShadowWriteOverride(property)
        } else {
            try await upsertPropertyRowToSupabase(payload)
        }
    }

    private func performQueuedSessionRemoteWrite(
        property: Property,
        session: Session,
        metadata: SessionMetadata,
        payload: QueuedSessionMutationPayload
    ) async throws {
        print(
            "[SessionCoordinationWrite] event=begin " +
            "entityType=session " +
            "entityID=\(session.id.uuidString) " +
            "operation=upsert_session " +
            "orgID=\(property.orgId?.uuidString ?? "nil")"
        )
        if let sessionShadowWriteOverride {
            try await sessionShadowWriteOverride(property, session, metadata)
        } else {
            do {
                try await upsertPropertyRowToSupabase(payload.property)
                print(
                    "[SessionCoordinationWrite] event=session_upsert_attempt " +
                    "entityID=\(session.id.uuidString)"
                )
                try await upsertSessionRowToSupabase(payload.session)
                print(
                    "[SessionCoordinationWrite] event=session_upsert_success " +
                    "entityID=\(session.id.uuidString)"
                )
            } catch {
                print(
                    "[SessionCoordinationWrite] event=failed " +
                    "entityID=\(session.id.uuidString) " +
                    "error=\(error.localizedDescription)"
                )
                throw error
            }
        }
    }

    private func performSessionCoordinationRemoteWrite(
        property: Property,
        session: Session,
        metadata: SessionMetadata,
        payload: SupabaseSessionPayload
    ) async throws {
        if let sessionShadowWriteOverride {
            try await sessionShadowWriteOverride(property, session, metadata)
        } else {
            try await upsertSessionRowToSupabase(payload)
        }
    }

    private func queuedPropertyFromPayload(
        _ payload: SupabasePropertyPayload,
        queueItem: LocalStore.QueuedMutation
    ) -> Property {
        return Property(
            id: payload.id,
            orgId: queueItem.organizationID,
            folderId: nil,
            clientName: nil,
            clientPhone: nil,
            clientEmail: nil,
            name: payload.name,
            address: payload.addressLine1,
            street: payload.addressLine1,
            city: payload.city,
            state: payload.state,
            zip: payload.postalCode,
            baselineSessionID: nil,
            isArchived: false,
            createdAt: queueItem.createdAt,
            updatedAt: queueItem.updatedAt
        )
    }

    private func canonicalQueuedPropertyPayload(
        _ payload: SupabasePropertyPayload,
        queueItem: LocalStore.QueuedMutation
    ) -> QueuedPropertyMutationPayload {
        QueuedPropertyMutationPayload(
            property: SupabasePropertyPayload(
                id: queueItem.entityID,
                orgID: queueItem.organizationID,
                clientName: payload.clientName,
                clientEmail: payload.clientEmail,
                clientPhone: payload.clientPhone,
                name: payload.name,
                addressLine1: payload.addressLine1,
                city: payload.city,
                state: payload.state,
                postalCode: payload.postalCode
            )
        )
    }

    private func queuedSessionFromPayload(
        _ payload: QueuedSessionMutationPayload,
        queueItem: LocalStore.QueuedMutation
    ) -> Session {
        Session(
            id: queueItem.sessionID ?? queueItem.entityID,
            propertyID: queueItem.propertyID ?? payload.session.propertyID,
            startedAt: parseSupabaseDateString(payload.session.startedAt) ?? Date(),
            status: Session.Status(rawValue: payload.session.status) ?? .draft,
            endedAt: payload.session.completedAt.flatMap(parseSupabaseDateString),
            exportedAt: nil,
            isSealed: payload.session.status == Session.Status.completed.rawValue
        )
    }

    private func queuedSessionMetadataFromPayload(
        _ payload: QueuedSessionMutationPayload,
        session: Session
    ) -> SessionMetadata {
        SessionMetadata(
            schemaVersion: 12,
            propertyID: payload.session.propertyID,
            sessionID: payload.session.id,
            orgID: payload.property.orgID,
            propertyNameAtCapture: payload.property.name,
            propertyNameAtExport: nil,
            startedAt: session.startedAt,
            endedAt: session.endedAt,
            status: session.status,
            isBaselineSession: false,
            exportedAt: nil,
            isSealed: session.isSealed,
            appVersion: "offline-replay",
            deviceModel: "offline-replay",
            osVersion: "offline-replay",
            shots: [],
            issues: []
        )
    }

    private func schedulePhaseBPropertyShadowWrite(for property: Property) {
        guard isPhaseBMetadataShadowWriteEnabled else { return }
        guard let orgID = property.orgId else {
            print("[CutoverShadowWrite] skipped entity=property propertyID=\(property.id.uuidString) reason=missing_org_id")
            return
        }
        guard canAccessOrganization(orgID) else {
            print("[CutoverShadowWrite] skipped entity=property propertyID=\(property.id.uuidString) reason=inactive_org")
            return
        }
        Task(priority: .utility) { [weak self] in
            guard let self else { return }
            let queuedMutation: LocalStore.QueuedMutation
            do {
                guard let built = try self.makeQueuedPropertyMutation(for: property) else {
                    print("[OfflineQueue] skipped entityType=property entityID=\(property.id.uuidString) reason=payload_build_failed")
                    return
                }
                queuedMutation = built
            } catch {
                print(
                    "[OfflineQueue] skipped entityType=property entityID=\(property.id.uuidString) " +
                    "reason=payload_encode_failed error=\(error.localizedDescription)"
                )
                return
            }

            let canAttemptRemoteWrite =
                self.propertyShadowWriteOverride != nil ||
                self.remoteMutationPathAvailable(for: orgID)
            guard canAttemptRemoteWrite else {
                self.enqueueOfflineMutation(queuedMutation, reason: "remote_unavailable")
                return
            }

            do {
                let payload = try JSONDecoder().decode(
                    QueuedPropertyMutationPayload.self,
                    from: queuedMutation.payloadData
                )
                try await self.performQueuedPropertyRemoteWrite(
                    property: property,
                    payload: payload.property
                )

                print(
                    "[CutoverShadowWrite] result=success entity=property " +
                    "phase=\(self.cutoverPhase.rawValue) propertyID=\(property.id.uuidString)"
                )
                self.removeQueuedMutationIfPresent(
                    idempotencyKey: queuedMutation.idempotencyKey,
                    reason: "direct_property_success"
                )

                Task(priority: .background) { [weak self] in
                    await self?.reconcilePropertyShadowWrite(
                        propertyID: property.id,
                        orgID: orgID,
                        localUpdatedAt: property.updatedAt
                    )
                }
            } catch {
                print(
                    "[CutoverShadowWrite] result=failed entity=property " +
                    "phase=\(self.cutoverPhase.rawValue) propertyID=\(property.id.uuidString) " +
                    "error=\(error.localizedDescription)"
                )
                self.enqueueOfflineMutation(queuedMutation, reason: "remote_write_failed")
            }
        }
    }

    private func schedulePhaseBSessionShadowWrite(for session: Session) {
        guard isPhaseBMetadataShadowWriteEnabled else { return }
        guard let property = allProperties.first(where: { $0.id == session.propertyID }) ??
            properties.first(where: { $0.id == session.propertyID }) else {
            print("[CutoverShadowWrite] skipped entity=session sessionID=\(session.id.uuidString) reason=missing_property")
            return
        }
        guard let orgID = property.orgId else {
            print("[CutoverShadowWrite] skipped entity=session sessionID=\(session.id.uuidString) reason=missing_org_id")
            return
        }
        guard canAccessOrganization(orgID) else {
            print("[CutoverShadowWrite] skipped entity=session sessionID=\(session.id.uuidString) reason=inactive_org")
            return
        }
        guard let metadata = try? localStore.loadSessionMetadata(propertyID: session.propertyID, sessionID: session.id) else {
            print("[CutoverShadowWrite] skipped entity=session sessionID=\(session.id.uuidString) reason=missing_metadata")
            return
        }

        Task(priority: .utility) { [weak self] in
            guard let self else { return }
            let queuedMutation: LocalStore.QueuedMutation
            do {
                guard let built = try self.makeQueuedSessionMutation(
                    property: property,
                    session: session,
                    metadata: metadata
                ) else {
                    print("[OfflineQueue] skipped entityType=session entityID=\(session.id.uuidString) reason=payload_build_failed")
                    return
                }
                queuedMutation = built
            } catch {
                print(
                    "[OfflineQueue] skipped entityType=session entityID=\(session.id.uuidString) " +
                    "reason=payload_encode_failed error=\(error.localizedDescription)"
                )
                return
            }

            guard self.remoteMutationPathAvailable(for: orgID) else {
                self.enqueueOfflineMutation(queuedMutation, reason: "remote_unavailable")
                return
            }

            do {
                let payload = try JSONDecoder().decode(
                    QueuedSessionMutationPayload.self,
                    from: queuedMutation.payloadData
                )
                try await self.performQueuedSessionRemoteWrite(
                    property: property,
                    session: session,
                    metadata: metadata,
                    payload: payload
                )

                print(
                    "[CutoverShadowWrite] result=success entity=session " +
                    "phase=\(self.cutoverPhase.rawValue) propertyID=\(property.id.uuidString) " +
                    "sessionID=\(session.id.uuidString)"
                )
                self.removeQueuedMutationIfPresent(
                    idempotencyKey: queuedMutation.idempotencyKey,
                    reason: "direct_session_success"
                )

                Task(priority: .background) { [weak self] in
                    await self?.reconcileSessionShadowWrite(
                        sessionID: session.id,
                        propertyID: property.id,
                        orgID: orgID,
                        localUpdatedAt: self?.localSessionShadowWriteTimestamp(session) ?? session.startedAt
                    )
                }
            } catch {
                print(
                    "[CutoverShadowWrite] result=failed entity=session " +
                    "phase=\(self.cutoverPhase.rawValue) propertyID=\(property.id.uuidString) " +
                    "sessionID=\(session.id.uuidString) error=\(error.localizedDescription)"
                )
                self.enqueueOfflineMutation(queuedMutation, reason: "remote_write_failed")
            }
        }
    }

    private func performOperationalMediaUpload(
        propertyID: UUID,
        sessionID: UUID,
        shotID: UUID
    ) async {
        guard let client = supabaseClient else { return }
        guard let metadata = try? localStore.loadSessionMetadata(propertyID: propertyID, sessionID: sessionID),
              let shot = metadata.shots.first(where: { $0.shotID == shotID }) else {
            return
        }
        guard canAccessProperty(propertyID) else {
            print("[SupabaseMediaUpload] skipped reason=inactiveOrg propertyID=\(propertyID.uuidString)")
            return
        }
        let orgID = metadata.orgID ?? properties.first(where: { $0.id == propertyID })?.orgId

        let localFileURL: URL
        if let resolved = localStore.resolveSessionRelativeFileURL(
            propertyID: propertyID,
            sessionID: sessionID,
            relativePath: shot.originalRelativePath
        ) {
            localFileURL = resolved
        } else {
            localFileURL = localStore
                .sessionFolderURL(propertyID: propertyID, sessionID: sessionID)
                .appendingPathComponent(shot.originalRelativePath, isDirectory: false)
        }

        guard FileManager.default.fileExists(atPath: localFileURL.path) else {
            print("[SupabaseMediaUpload] skipped missingLocalFile shotID=\(shotID.uuidString) path=\(localFileURL.path)")
            return
        }

        let storagePath = operationalMediaStoragePath(
            sessionID: sessionID,
            shotID: shotID,
            originalFilename: shot.originalFilename
        )
        var checksum: String?
        var byteSize: Int?
        var failurePhase = "localRead"

        do {
            let fileData = try Data(contentsOf: localFileURL, options: [.mappedIfSafe])
            checksum = sha256Hex(for: fileData)
            byteSize = fileData.count
            try? localStore.updateShotStorageMetadata(propertyID: propertyID, sessionID: sessionID, shotID: shotID) { shot in
                shot.storageBucket = self.supabaseOperationalMediaBucket
                shot.storagePath = storagePath
                shot.checksumSHA256 = checksum
                shot.byteSize = byteSize
                shot.uploadState = "uploading"
                shot.uploadAttempts += 1
                shot.lastUploadError = nil
                shot.updatedAt = Date()
            }

            failurePhase = "blobUpload"
            _ = try await client.storage.from(supabaseOperationalMediaBucket).upload(
                storagePath,
                fileURL: localFileURL,
                options: FileOptions(
                    cacheControl: "31536000",
                    contentType: contentType(for: localFileURL),
                    upsert: true
                )
            )

            guard let orgID else {
                throw NSError(domain: "ScoutCapture.SupabaseMedia", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Missing orgID for shot \(shotID.uuidString)"
                ])
            }

            failurePhase = "sessionPrereq"
            try await ensureSupabaseSessionPrerequisites(
                propertyID: propertyID,
                sessionID: sessionID,
                metadata: metadata,
                orgID: orgID
            )

            failurePhase = "shotMetadataWrite"
            try await persistShotStorageMetadataToSupabase(
                orgID: orgID,
                sessionID: sessionID,
                shotID: shotID,
                storageBucket: supabaseOperationalMediaBucket,
                storagePath: storagePath,
                checksumSHA256: checksum,
                byteSize: byteSize,
                uploadState: "uploaded",
                uploadAttempts: shot.uploadAttempts + 1,
                lastUploadError: nil
            )

            try? localStore.updateShotStorageMetadata(propertyID: propertyID, sessionID: sessionID, shotID: shotID) { shot in
                shot.storageBucket = self.supabaseOperationalMediaBucket
                shot.storagePath = storagePath
                shot.checksumSHA256 = checksum
                shot.byteSize = byteSize
                shot.uploadState = "uploaded"
                shot.lastUploadError = nil
                shot.updatedAt = Date()
            }

            print(
                "[SupabaseMediaUpload] result=success " +
                "shotID=\(shotID.uuidString) " +
                "bucket=\(supabaseOperationalMediaBucket) " +
                "path=\(storagePath)"
            )
        } catch {
            try? localStore.updateShotStorageMetadata(propertyID: propertyID, sessionID: sessionID, shotID: shotID) { shot in
                shot.storageBucket = self.supabaseOperationalMediaBucket
                shot.storagePath = storagePath
                shot.checksumSHA256 = checksum
                shot.byteSize = byteSize
                shot.uploadState = "failed"
                shot.lastUploadError = "Supabase \(failurePhase) error: \(error.localizedDescription)"
                shot.updatedAt = Date()
            }

            print(
                "[SupabaseMediaUpload] result=failed " +
                "shotID=\(shotID.uuidString) " +
                "bucket=\(supabaseOperationalMediaBucket) " +
                "path=\(storagePath) " +
                "phase=\(failurePhase) " +
                "error=\(error.localizedDescription)"
            )
        }
    }

    private func performOperationalMediaHydration(
        propertyID: UUID,
        sessionID: UUID,
        shotID: UUID
    ) async {
        guard let client = supabaseClient else { return }
        guard let metadata = try? localStore.loadSessionMetadata(propertyID: propertyID, sessionID: sessionID),
              let shot = metadata.shots.first(where: { $0.shotID == shotID }) else {
            return
        }
        guard canAccessProperty(propertyID) else {
            print("[SupabaseMediaDownload] skipped reason=inactiveOrg propertyID=\(propertyID.uuidString)")
            return
        }

        let resolvedShot = await resolveShotStorageMetadata(
            propertyID: propertyID,
            sessionID: sessionID,
            shot: shot
        )

        let relativePath = resolvedShot.originalRelativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !relativePath.isEmpty,
              let bucket = resolvedShot.storageBucket?.trimmingCharacters(in: .whitespacesAndNewlines),
              let path = resolvedShot.storagePath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !bucket.isEmpty,
              !path.isEmpty else {
            return
        }

        let destinationURL = localStore
            .sessionFolderURL(propertyID: propertyID, sessionID: sessionID)
            .appendingPathComponent(relativePath, isDirectory: false)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            return
        }

        do {
            let data = try await client.storage.from(bucket).download(path: path)

            if let expectedChecksum = resolvedShot.checksumSHA256?.trimmingCharacters(in: .whitespacesAndNewlines),
               !expectedChecksum.isEmpty,
               sha256Hex(for: data) != expectedChecksum.lowercased() {
                print(
                    "[SupabaseMediaDownload] result=failed " +
                    "shotID=\(shotID.uuidString) " +
                    "reason=checksumMismatch " +
                    "bucket=\(bucket) path=\(path)"
                )
                return
            }

            try FileManager.default.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: destinationURL, options: [.atomic])

            try? localStore.updateShotStorageMetadata(propertyID: propertyID, sessionID: sessionID, shotID: shotID) { shot in
                shot.byteSize = data.count
                if shot.checksumSHA256 == nil {
                    shot.checksumSHA256 = self.sha256Hex(for: data)
                }
                if shot.storageBucket == nil {
                    shot.storageBucket = bucket
                }
                if shot.storagePath == nil {
                    shot.storagePath = path
                }
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                NotificationCenter.default.post(name: .scoutClearLocalUICache, object: nil)
            }

            print(
                "[SupabaseMediaDownload] result=success " +
                "shotID=\(shotID.uuidString) " +
                "bucket=\(bucket) " +
                "path=\(path) " +
                "destination=\(destinationURL.path)"
            )
        } catch {
            print(
                "[SupabaseMediaDownload] result=failed " +
                "shotID=\(shotID.uuidString) " +
                "bucket=\(bucket) " +
                "path=\(path) " +
                "error=\(error.localizedDescription)"
            )
        }
    }

    private func ensureSupabaseSessionPrerequisites(
        propertyID: UUID,
        sessionID: UUID,
        metadata: SessionMetadata,
        orgID: UUID
    ) async throws {
        guard let client = supabaseClient else { return }
        guard canAccessOrganization(orgID) else {
            throw NSError(domain: "ScoutCapture.SupabaseMedia", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Blocked Supabase session write outside the active organization."
            ])
        }

        let property = properties.first(where: { $0.id == propertyID })
        let propertyPayload = makeSupabasePropertyPayload(
            propertyID: propertyID,
            orgID: orgID,
            property: property,
            metadata: metadata
        )

        let sessionPayload = makeSupabaseSessionPayload(
            sessionID: sessionID,
            propertyID: propertyID,
            orgID: orgID,
            property: property,
            metadata: metadata
        )

        do {
            try await upsertPropertyRowToSupabase(propertyPayload)
            try await upsertSessionRowToSupabase(sessionPayload)
        } catch {
            print(
                "[SupabaseSessionEnsure] result=failed " +
                "orgID=\(orgID.uuidString) " +
                "propertyID=\(propertyID.uuidString) " +
                "sessionID=\(sessionID.uuidString) " +
                "error=\(error.localizedDescription)"
            )
            throw NSError(domain: "ScoutCapture.SupabaseMedia", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Failed to ensure property/session rows before shot metadata write: \(error.localizedDescription)"
            ])
        }
    }

    private func persistShotStorageMetadataToSupabase(
        orgID: UUID,
        sessionID: UUID,
        shotID: UUID,
        storageBucket: String?,
        storagePath: String?,
        checksumSHA256: String?,
        byteSize: Int?,
        uploadState: String,
        uploadAttempts: Int,
        lastUploadError: String?
    ) async throws {
        guard let client = supabaseClient else { return }
        guard canAccessOrganization(orgID) else {
            throw NSError(domain: "ScoutCapture.SupabaseMedia", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "Blocked Supabase shot metadata write outside the active organization."
            ])
        }

        let payload = SupabaseShotStoragePayload(
            id: shotID,
            orgID: orgID,
            sessionID: sessionID,
            storageBucket: storageBucket,
            storagePath: storagePath,
            checksumSHA256: checksumSHA256,
            byteSize: byteSize,
            uploadState: uploadState,
            uploadAttempts: max(0, uploadAttempts),
            lastUploadError: lastUploadError
        )

        try await client
            .from("shots")
            .upsert(payload, onConflict: "id", returning: .minimal)
            .execute()
    }

    private func makeSupabasePropertyPayload(
        propertyID: UUID,
        orgID: UUID,
        property: Property?,
        metadata: SessionMetadata?
    ) -> SupabasePropertyPayload {
        let propertyName = normalizedSupabaseText(
            property?.name ?? metadata?.propertyNameAtCapture
        ) ?? "Property \(propertyID.uuidString)"

        return SupabasePropertyPayload(
            id: propertyID,
            orgID: orgID,
            clientName: normalizedSupabaseText(property?.clientName),
            clientEmail: normalizedSupabaseText(property?.clientEmail),
            clientPhone: normalizedSupabaseText(property?.clientPhone),
            name: propertyName,
            addressLine1: normalizedSupabaseText(property?.street ?? metadata?.propertyStreetAtCapture),
            city: normalizedSupabaseText(property?.city ?? metadata?.propertyCityAtCapture),
            state: normalizedSupabaseText(property?.state ?? metadata?.propertyStateAtCapture),
            postalCode: normalizedSupabaseText(property?.zip ?? metadata?.propertyZipAtCapture)
        )
    }

    private func makeSupabaseSessionPayload(
        sessionID: UUID,
        propertyID: UUID,
        orgID: UUID,
        property: Property?,
        metadata: SessionMetadata
    ) -> SupabaseSessionPayload {
        let coordinationState = sessionCoordinationStateBySessionID[sessionID]
        return SupabaseSessionPayload(
            id: sessionID,
            orgID: orgID,
            propertyID: propertyID,
            title: normalizedSupabaseText(metadata.propertyNameAtCapture ?? property?.name),
            status: metadata.status.rawValue,
            startedAt: metadata.startedAt.ISO8601Format(),
            completedAt: metadata.endedAt?.ISO8601Format(),
            lockedByUserID: coordinationState?.lockedByUserID,
            lockedByDeviceID: normalizedSupabaseText(coordinationState?.lockedByDeviceID),
            lockedAt: coordinationState?.lockedAt?.ISO8601Format(),
            coordinationTier1Snapshot: sessionCoordinationTier1SnapshotString(metadata: metadata)
        )
    }

    private func upsertPropertyRowToSupabase(_ payload: SupabasePropertyPayload) async throws {
        guard let client = supabaseClient else { return }
        try await client
            .from("properties")
            .upsert(payload, onConflict: "id", returning: .minimal)
            .execute()
    }

    private func upsertSessionRowToSupabase(_ payload: SupabaseSessionPayload) async throws {
        guard let client = supabaseClient else { return }
        try await client
            .from("sessions")
            .upsert(payload, onConflict: "id", returning: .minimal)
            .execute()
    }

    private func upsertPropertySessionOccupancyRowToSupabase(_ payload: PropertySessionOccupancyPayload) async throws {
        guard let client = supabaseClient else { return }
        try await client
            .from("property_session_occupancy")
            .upsert(payload, onConflict: "property_id", returning: .minimal)
            .execute()
    }

    private func deletePropertySessionOccupancyRowFromSupabase(
        orgID: UUID,
        propertyID: UUID
    ) async throws {
        guard let client = supabaseClient else { return }
        try await client
            .from("property_session_occupancy")
            .delete(returning: .minimal)
            .eq("org_id", value: orgID.uuidString.lowercased())
            .eq("property_id", value: propertyID.uuidString.lowercased())
            .execute()
    }

    private func fetchRemoteSessionCoordinationRecord(
        orgID: UUID,
        propertyID: UUID,
        sessionID: UUID
    ) async throws -> RemoteSessionCoordinationRecord? {
#if DEBUG
        if let cached = sessionCoordinationDebugRemoteRecords[sessionID],
           cached.propertyID == propertyID {
            return cached
        }
        if let sessionCoordinationFetchOverride {
            return try await sessionCoordinationFetchOverride(orgID, propertyID, sessionID)
        }
        if AppStateTestEnvironment.isRunningUnderXCTest {
            return nil
        }
#endif
        guard let client = supabaseClient else { return nil }

        let rows = try await client
            .from("sessions")
            .select("id, org_id, property_id, locked_by_user_id, locked_by_device_id, locked_at, coordination_tier1_snapshot, updated_at")
            .eq("org_id", value: orgID.uuidString.lowercased())
            .eq("property_id", value: propertyID.uuidString.lowercased())
            .eq("id", value: sessionID.uuidString.lowercased())
            .limit(1)
            .execute()
            .value as [RemoteSessionCoordinationRecord]

        return rows.first
    }

    private func fetchRemotePropertySessionOccupancyRecord(
        orgID: UUID,
        propertyID: UUID
    ) async throws -> RemotePropertySessionOccupancyRecord? {
#if DEBUG
        if let cached = propertySessionOccupancyDebugRemoteRecords[propertyID],
           cached.propertyID == propertyID {
            return cached
        }
        if AppStateTestEnvironment.isRunningUnderXCTest {
            return nil
        }
#endif
        guard let client = supabaseClient else { return nil }

        let rows = try await client
            .from("property_session_occupancy")
            .select("property_id, org_id, occupied_by_user_id, occupied_by_device_id, occupied_at")
            .eq("org_id", value: orgID.uuidString.lowercased())
            .eq("property_id", value: propertyID.uuidString.lowercased())
            .limit(1)
            .execute()
            .value as [RemotePropertySessionOccupancyRecord]

        return rows.first
    }

    private func fetchRemotePropertySessionOccupancyRecords(
        activeOrganizationID: UUID
    ) async throws -> [RemotePropertySessionOccupancyRecord] {
#if DEBUG
        if AppStateTestEnvironment.isRunningUnderXCTest {
            return Array(propertySessionOccupancyDebugRemoteRecords.values)
        }
#endif
        guard let client = supabaseClient else { return [] }

        return try await client
            .from("property_session_occupancy")
            .select("property_id, org_id, occupied_by_user_id, occupied_by_device_id, occupied_at")
            .eq("org_id", value: activeOrganizationID.uuidString.lowercased())
            .execute()
            .value
    }

    private func ownerDescription(
        for lockedByUserID: UUID?,
        lockedByDeviceID: String?
    ) async -> String {
        if let lockedByUserID, lockedByUserID == authenticatedSupabaseUser?.id {
            return "You"
        }
        guard let lockedByUserID else {
            if normalizedSupabaseText(lockedByDeviceID) != nil {
                return "Another device"
            }
            return "Another user"
        }
        guard let client = supabaseClient else {
            return "User \(lockedByUserID.uuidString.prefix(8))"
        }

        struct OwnerRecord: Decodable {
            let fullName: String?
            let email: String?

            enum CodingKeys: String, CodingKey {
                case fullName = "full_name"
                case email
            }
        }

        let rows: [OwnerRecord]
        do {
            rows = try await client
                .from("users_profile")
                .select("full_name, email")
                .eq("id", value: lockedByUserID.uuidString.lowercased())
                .limit(1)
                .execute()
                .value
        } catch {
            rows = []
        }
        if let first = rows.first {
            if let fullName = normalizedSupabaseText(first.fullName) {
                return fullName
            }
            if let email = normalizedSupabaseText(first.email) {
                return email
            }
        }

        return "User \(lockedByUserID.uuidString.prefix(8))"
    }

    private func setSessionCoordinationState(
        sessionID: UUID,
        lockedByUserID: UUID?,
        lockedByDeviceID: String?,
        lockedAt: Date?
    ) {
        sessionCoordinationStateBySessionID[sessionID] = SessionCoordinationState(
            lockedByUserID: lockedByUserID,
            lockedByDeviceID: lockedByDeviceID,
            lockedAt: lockedAt
        )
    }

    private func setPropertySessionOccupancyState(
        propertyID: UUID,
        occupiedByUserID: UUID?,
        occupiedByDeviceID: String?,
        occupiedAt: Date?
    ) {
        if occupiedByUserID == nil,
           normalizedSupabaseText(occupiedByDeviceID) == nil,
           occupiedAt == nil {
            propertySessionOccupancyByPropertyID.removeValue(forKey: propertyID)
            return
        }

        propertySessionOccupancyByPropertyID[propertyID] = PropertySessionOccupancyState(
            occupiedByUserID: occupiedByUserID,
            occupiedByDeviceID: occupiedByDeviceID,
            occupiedAt: occupiedAt
        )
    }

    private func refreshRemotePropertySessionOccupancyState(
        orgID: UUID
    ) async throws {
        let records = try await fetchRemotePropertySessionOccupancyRecords(activeOrganizationID: orgID)
        var nextState: [UUID: PropertySessionOccupancyState] = [:]
        for record in records {
            nextState[record.propertyID] = PropertySessionOccupancyState(
                occupiedByUserID: record.occupiedByUserID,
                occupiedByDeviceID: normalizedSupabaseText(record.occupiedByDeviceID),
                occupiedAt: record.occupiedAt.flatMap(parseSupabaseDateString)
            )
        }
        propertySessionOccupancyByPropertyID = nextState
    }

    private func hydratePreTapLockVisibility(
        orgID: UUID,
        propertyIDs: [UUID]
    ) async {
        try? await refreshRemotePropertySessionOccupancyState(orgID: orgID)

        for propertyID in propertyIDs {
            guard let session = canonicalLockSession(for: propertyID) else { continue }

            let remoteRecord = try? await fetchRemoteSessionCoordinationRecord(
                orgID: orgID,
                propertyID: propertyID,
                sessionID: session.id
            )
            let remoteLockedAt = remoteRecord?.lockedAt.flatMap(parseSupabaseDateString)
            let remoteHasLockFields =
                remoteRecord?.lockedByUserID != nil ||
                normalizedSupabaseText(remoteRecord?.lockedByDeviceID) != nil

            if remoteRecord != nil, remoteHasLockFields {
                setSessionCoordinationState(
                    sessionID: session.id,
                    lockedByUserID: remoteRecord?.lockedByUserID,
                    lockedByDeviceID: normalizedSupabaseText(remoteRecord?.lockedByDeviceID),
                    lockedAt: remoteLockedAt
                )
            } else {
                setSessionCoordinationState(
                    sessionID: session.id,
                    lockedByUserID: nil,
                    lockedByDeviceID: nil,
                    lockedAt: nil
                )
            }
        }
    }

    private func persistPropertySessionOccupancyMutation(
        propertyID: UUID,
        orgID: UUID,
        desiredState: PropertySessionOccupancyState
    ) async -> Bool {
        setPropertySessionOccupancyState(
            propertyID: propertyID,
            occupiedByUserID: desiredState.occupiedByUserID,
            occupiedByDeviceID: desiredState.occupiedByDeviceID,
            occupiedAt: desiredState.occupiedAt
        )
#if DEBUG
        propertySessionOccupancyDebugRemoteRecords[propertyID] = RemotePropertySessionOccupancyRecord(
            propertyID: propertyID,
            orgID: orgID,
            occupiedByUserID: desiredState.occupiedByUserID,
            occupiedByDeviceID: desiredState.occupiedByDeviceID,
            occupiedAt: desiredState.occupiedAt?.ISO8601Format()
        )
        if AppStateTestEnvironment.isRunningUnderXCTest {
            return true
        }
#endif

        let payload = PropertySessionOccupancyPayload(
            propertyID: propertyID,
            orgID: orgID,
            occupiedByUserID: desiredState.occupiedByUserID,
            occupiedByDeviceID: normalizedSupabaseText(desiredState.occupiedByDeviceID),
            occupiedAt: desiredState.occupiedAt?.ISO8601Format(),
            updatedBy: authenticatedSupabaseUser?.id
        )

        do {
            try await upsertPropertySessionOccupancyRowToSupabase(payload)
            return true
        } catch {
            setPropertySessionOccupancyState(
                propertyID: propertyID,
                occupiedByUserID: nil,
                occupiedByDeviceID: nil,
                occupiedAt: nil
            )
#if DEBUG
            propertySessionOccupancyDebugRemoteRecords.removeValue(forKey: propertyID)
#endif
            return false
        }
    }

    private func releasePropertySessionOccupancyIfOwned(propertyID: UUID) async {
        guard backendFeatureFlags.sessionCoordinationEnabled,
              let property = properties.first(where: { $0.id == propertyID }) ?? allProperties.first(where: { $0.id == propertyID }),
              let orgID = property.orgId else {
            return
        }

        let state = propertySessionOccupancyByPropertyID[propertyID]
        let currentUserID = authenticatedSupabaseUser?.id
        let currentDeviceID = currentDeviceIdentifier()
        let ownsOccupancy =
            state?.occupiedByUserID == currentUserID &&
            normalizedSupabaseText(state?.occupiedByDeviceID) == currentDeviceID
        guard ownsOccupancy else { return }

        setPropertySessionOccupancyState(
            propertyID: propertyID,
            occupiedByUserID: nil,
            occupiedByDeviceID: nil,
            occupiedAt: nil
        )
#if DEBUG
        propertySessionOccupancyDebugRemoteRecords.removeValue(forKey: propertyID)
        if AppStateTestEnvironment.isRunningUnderXCTest {
            return
        }
#endif

        try? await deletePropertySessionOccupancyRowFromSupabase(
            orgID: orgID,
            propertyID: propertyID
        )
    }

    private func persistSessionCoordinationMutation(
        property: Property,
        session: Session,
        metadata: SessionMetadata,
        desiredState: SessionCoordinationState
    ) async -> Bool {
        print(
            "[SessionCoordinationPersist] event=begin " +
            "sessionID=\(session.id.uuidString) " +
            "lockedByUserID=\(desiredState.lockedByUserID?.uuidString ?? "nil") " +
            "lockedByDeviceID=\(desiredState.lockedByDeviceID ?? "nil") " +
            "lockedAt=\(desiredState.lockedAt?.ISO8601Format() ?? "nil")"
        )
        setSessionCoordinationState(
            sessionID: session.id,
            lockedByUserID: desiredState.lockedByUserID,
            lockedByDeviceID: desiredState.lockedByDeviceID,
            lockedAt: desiredState.lockedAt
        )
#if DEBUG
        sessionCoordinationDebugRemoteRecords[session.id] = RemoteSessionCoordinationRecord(
            id: session.id,
            orgID: property.orgId ?? UUID(),
            propertyID: property.id,
            lockedByUserID: desiredState.lockedByUserID,
            lockedByDeviceID: desiredState.lockedByDeviceID,
            lockedAt: desiredState.lockedAt?.ISO8601Format(),
            coordinationTier1Snapshot: sessionCoordinationTier1SnapshotString(metadata: metadata),
            updatedAt: Date()
        )
#endif

        let queuedMutation: LocalStore.QueuedMutation
        do {
            guard let built = try makeQueuedSessionMutation(property: property, session: session, metadata: metadata) else {
                return false
            }
            queuedMutation = built
        } catch {
            return false
        }

        do {
            let payload = try JSONDecoder().decode(QueuedSessionMutationPayload.self, from: queuedMutation.payloadData)
            print(
                "[SessionCoordinationPersist] event=remote_write_attempt " +
                "sessionID=\(session.id.uuidString)"
            )
            try await performSessionCoordinationRemoteWrite(
                property: property,
                session: session,
                metadata: metadata,
                payload: payload.session
            )
            print(
                "[SessionCoordinationPersist] event=remote_write_success " +
                "sessionID=\(session.id.uuidString)"
            )
            removeQueuedMutationIfPresent(
                idempotencyKey: queuedMutation.idempotencyKey,
                reason: "session_coordination_direct_success"
            )
            return true
        } catch {
            print(
                "[SessionCoordinationPersist] event=remote_write_failed " +
                "sessionID=\(session.id.uuidString) " +
                "error=\(error.localizedDescription)"
            )
            enqueueOfflineMutation(queuedMutation, reason: "session_coordination_write_failed")
            return false
        }
    }

    @MainActor
    func evaluateSessionEntryCoordination(
        propertyID: UUID,
        sessionID: UUID,
        forceClaim: Bool = false
    ) async -> SessionEntryCoordinationStatus {
        let property = properties.first(where: { $0.id == propertyID }) ?? allProperties.first(where: { $0.id == propertyID })
        let session = sessions(for: propertyID).first(where: { $0.id == sessionID }) ?? currentSession
        let metadata = try? localStore.loadSessionMetadata(propertyID: propertyID, sessionID: sessionID)
        print(
            "[SessionCoordinationEval] event=begin " +
            "propertyID=\(propertyID.uuidString) " +
            "sessionID=\(sessionID.uuidString) " +
            "sessionStatus=\(session?.status.rawValue ?? "nil") " +
            "sessionCoordinationEnabled=\(backendFeatureFlags.sessionCoordinationEnabled) " +
            "supabaseEnabled=\(backendFeatureFlags.supabaseEnabled) " +
            "shadowWriteEnabled=\(backendFeatureFlags.shadowWriteEnabled) " +
            "propertyFound=\(property != nil) " +
            "sessionFound=\(session != nil) " +
            "metadataLoaded=\(metadata != nil) " +
            "authenticated=\(authenticatedSupabaseUser != nil) " +
            "clientAvailable=\(supabaseClient != nil)"
        )
    guard backendFeatureFlags.sessionCoordinationEnabled,
          backendFeatureFlags.supabaseEnabled,
          backendFeatureFlags.shadowWriteEnabled,
          let property,
          let orgID = property.orgId,
          let session else {
        print("[SessionCoordinationEval] event=early_return result=allowed reason=prereq_guard_failed")
        return .allowed
    }

        guard authenticatedSupabaseUser != nil,
              supabaseClient != nil else {
            print("[SessionCoordinationEval] event=early_return result=blocked reason=coordination_unavailable ownerDescription=Session coordination unavailable lockedAt=nil")
            return .blocked(
                SessionEntryCoordinationBlock(
                    ownerDescription: "Session coordination unavailable",
                    lockedAt: nil
                )
            )
        }

        let currentUserID = authenticatedSupabaseUser?.id
        let currentDeviceID = currentDeviceIdentifier()
        let propertyOccupancy = try? await fetchRemotePropertySessionOccupancyRecord(
            orgID: orgID,
            propertyID: propertyID
        )
        setPropertySessionOccupancyState(
            propertyID: propertyID,
            occupiedByUserID: propertyOccupancy?.occupiedByUserID,
            occupiedByDeviceID: normalizedSupabaseText(propertyOccupancy?.occupiedByDeviceID),
            occupiedAt: propertyOccupancy?.occupiedAt.flatMap(parseSupabaseDateString)
        )
        print(
            "[SessionCoordinationEval] event=fetch_remote " +
            "propertyID=\(propertyID.uuidString) " +
            "sessionID=\(sessionID.uuidString)"
        )
        let remoteRecord = try? await fetchRemoteSessionCoordinationRecord(
            orgID: orgID,
            propertyID: propertyID,
            sessionID: sessionID
        )
        print(
            "[SessionCoordinationEval] event=fetch_result " +
            "found=\(remoteRecord != nil) " +
            "lockedByUserID=\(remoteRecord?.lockedByUserID?.uuidString ?? "nil") " +
            "lockedByDeviceID=\(remoteRecord?.lockedByDeviceID ?? "nil") " +
            "lockedAt=\(remoteRecord?.lockedAt ?? "nil")"
        )
        if remoteRecord == nil {
            print("[SessionCoordinationEval] DEBUG: remoteRecord is NIL")
        } else if remoteRecord?.lockedByUserID == nil && normalizedSupabaseText(remoteRecord?.lockedByDeviceID) == nil {
            print("[SessionCoordinationEval] DEBUG: remoteRecord has NO LOCK")
        } else {
            print("[SessionCoordinationEval] DEBUG: remoteRecord HAS LOCK")
        }

        if let propertyOccupancy,
           propertyOccupancy.occupiedByUserID != nil || normalizedSupabaseText(propertyOccupancy.occupiedByDeviceID) != nil {
            let isOwnedByCurrentActor =
                propertyOccupancy.occupiedByUserID == currentUserID &&
                normalizedSupabaseText(propertyOccupancy.occupiedByDeviceID) == currentDeviceID

            if !forceClaim && !isOwnedByCurrentActor {
                let owner = await ownerDescription(
                    for: propertyOccupancy.occupiedByUserID,
                    lockedByDeviceID: propertyOccupancy.occupiedByDeviceID
                )
                self.locallyLockedPropertyIDs.insert(propertyID)
                return .blocked(
                    SessionEntryCoordinationBlock(
                        ownerDescription: owner,
                        lockedAt: propertyOccupancy.occupiedAt.flatMap(parseSupabaseDateString)
                    )
                )
            }
        }

        if let remoteRecord,
           remoteRecord.lockedByUserID != nil || normalizedSupabaseText(remoteRecord.lockedByDeviceID) != nil {
            let isOwnedByCurrentActor =
                remoteRecord.lockedByUserID == currentUserID &&
                normalizedSupabaseText(remoteRecord.lockedByDeviceID) == currentDeviceID

            if !forceClaim && !isOwnedByCurrentActor {
                let owner = await ownerDescription(
                    for: remoteRecord.lockedByUserID,
                    lockedByDeviceID: remoteRecord.lockedByDeviceID
                )
                self.locallyLockedPropertyIDs.insert(propertyID)
                let blockedAt = remoteRecord.lockedAt ?? "nil"
                print(
                    "[SessionCoordinationEval] event=return result=blocked " +
                    "reason=other_owner_lock ownerDescription=\(owner) lockedAt=\(blockedAt)"
                )
                return .blocked(
                    SessionEntryCoordinationBlock(
                        ownerDescription: owner,
                        lockedAt: remoteRecord.lockedAt.flatMap(parseSupabaseDateString)
                    )
                )
            }
        }

        let baselineSnapshot = remoteRecord?.coordinationTier1Snapshot ??
            (metadata != nil ? sessionCoordinationTier1SnapshotString(metadata: metadata!) : "") ?? ""
        sessionCoordinationEntrySnapshotBySessionID[sessionID] = baselineSnapshot

        let isMateriallyRealSession = sessionHasCaptures(session)
        if remoteRecord == nil && !isMateriallyRealSession {
            let desiredState = SessionCoordinationState(
                lockedByUserID: currentUserID,
                lockedByDeviceID: currentDeviceID,
                lockedAt: Date()
            )
            setSessionCoordinationState(
                sessionID: sessionID,
                lockedByUserID: desiredState.lockedByUserID,
                lockedByDeviceID: desiredState.lockedByDeviceID,
                lockedAt: desiredState.lockedAt
            )
            let didPersistOccupancy = await persistPropertySessionOccupancyMutation(
                propertyID: propertyID,
                orgID: orgID,
                desiredState: PropertySessionOccupancyState(
                    occupiedByUserID: desiredState.lockedByUserID,
                    occupiedByDeviceID: desiredState.lockedByDeviceID,
                    occupiedAt: desiredState.lockedAt
                )
            )
            guard didPersistOccupancy else {
                setSessionCoordinationState(
                    sessionID: sessionID,
                    lockedByUserID: nil,
                    lockedByDeviceID: nil,
                    lockedAt: nil
                )
                return .blocked(
                    SessionEntryCoordinationBlock(
                        ownerDescription: "Session coordination unavailable",
                        lockedAt: nil
                    )
                )
            }
            print("[SessionCoordinationEval] event=return result=allowed reason=untouched_local_session_occupancy_claimed")
            return .allowed
        }

        let desiredState = SessionCoordinationState(
            lockedByUserID: currentUserID,
            lockedByDeviceID: currentDeviceID,
            lockedAt: Date()
        )
        print(
            "[SessionCoordinationEval] event=persist_claim " +
            "sessionID=\(sessionID.uuidString) " +
            "lockedByUserID=\(currentUserID?.uuidString ?? "nil") " +
            "lockedByDeviceID=\(currentDeviceID) " +
            "lockedAt=\(desiredState.lockedAt?.ISO8601Format() ?? "nil")"
        )
        let didPersistClaim = await persistSessionCoordinationMutation(
            property: property,
            session: session,
            metadata: metadata ?? SessionMetadata.empty,
            desiredState: desiredState
        )
        guard didPersistClaim else {
            print("[SessionCoordinationEval] event=return result=blocked reason=claim_persist_failed ownerDescription=Session coordination unavailable lockedAt=nil")
            return .blocked(
                SessionEntryCoordinationBlock(
                    ownerDescription: "Session coordination unavailable",
                    lockedAt: nil
                )
            )
        }
        print("[SessionCoordinationEval] event=return result=allowed sessionID=\(sessionID.uuidString)")
        return .allowed
    }

    @MainActor
    func preCompletionConflictReview(
        propertyID: UUID,
        sessionID: UUID
    ) async -> SessionCoordinationConflictReview? {
        guard backendFeatureFlags.sessionCoordinationEnabled,
              backendFeatureFlags.supabaseEnabled,
              let property = properties.first(where: { $0.id == propertyID }) ?? allProperties.first(where: { $0.id == propertyID }),
              let orgID = property.orgId,
              let baselineSnapshot = sessionCoordinationEntrySnapshotBySessionID[sessionID],
              let metadata = try? localStore.loadSessionMetadata(propertyID: propertyID, sessionID: sessionID) else {
            return nil
        }

        guard let remoteRecord = try? await fetchRemoteSessionCoordinationRecord(
            orgID: orgID,
            propertyID: propertyID,
            sessionID: sessionID
        ) else {
            return nil
        }

        guard normalizedSupabaseText(remoteRecord.coordinationTier1Snapshot) != normalizedSupabaseText(baselineSnapshot) else {
            return nil
        }

        let diffs = sessionCoordinationDiffs(
            remoteSnapshotString: remoteRecord.coordinationTier1Snapshot,
            localMetadata: metadata
        )
        guard !diffs.isEmpty else { return nil }
        return SessionCoordinationConflictReview(sessionID: sessionID, diffs: diffs)
    }

    @MainActor
    func releaseCurrentSessionCoordinationLockIfOwned() async {
        guard let propertyID = selectedPropertyID,
              let sessionID = currentSession?.id else {
            return
        }
        await releasePropertySessionOccupancyIfOwned(propertyID: propertyID)
        await releaseSessionCoordinationLockIfOwned(propertyID: propertyID, sessionID: sessionID)
    }

    @MainActor
    func releaseSessionCoordinationLockIfOwned(
        propertyID: UUID,
        sessionID: UUID
    ) async {
        let persistedSession = sessions(for: propertyID).first(where: { $0.id == sessionID })
        if persistedSession == nil {
            setSessionCoordinationState(
                sessionID: sessionID,
                lockedByUserID: nil,
                lockedByDeviceID: nil,
                lockedAt: nil
            )
            return
        }

        guard backendFeatureFlags.sessionCoordinationEnabled,
              let session = persistedSession,
              let property = properties.first(where: { $0.id == propertyID }) ?? allProperties.first(where: { $0.id == propertyID }),
              let metadata = try? localStore.loadSessionMetadata(propertyID: propertyID, sessionID: sessionID) else {
            return
        }

        let sessionID = session.id
        let releasedSession = session
        let clearedState = SessionCoordinationState(
            lockedByUserID: nil,
            lockedByDeviceID: nil,
            lockedAt: nil
        )

        let state = sessionCoordinationStateBySessionID[sessionID]
        let lockedByDeviceID = state?.lockedByDeviceID ?? nil
        let ownsByAuthenticatedUser =
            state?.lockedByUserID == authenticatedSupabaseUser?.id &&
            normalizedSupabaseText(lockedByDeviceID) == currentDeviceIdentifier()
#if DEBUG
        let ownsByCurrentTestProcess =
            AppStateTestEnvironment.isRunningUnderXCTest &&
            normalizedSupabaseText(lockedByDeviceID) == currentDeviceIdentifier()
        #else
        let ownsByCurrentTestProcess = false
        #endif
        guard ownsByAuthenticatedUser || ownsByCurrentTestProcess else {
            return
        }

        if currentSession?.id == sessionID {
            currentSession = releasedSession
        }
        if var indexedSessions = sessionIndexByProperty[propertyID],
           let index = indexedSessions.firstIndex(where: { $0.id == sessionID }) {
            indexedSessions[index] = releasedSession
            sessionIndexByProperty[propertyID] = indexedSessions
        }
        if var indexedSessions = allSessionIndexByProperty[propertyID],
           let index = indexedSessions.firstIndex(where: { $0.id == sessionID }) {
            indexedSessions[index] = releasedSession
            allSessionIndexByProperty[propertyID] = indexedSessions
        }

        setSessionCoordinationState(
            sessionID: sessionID,
            lockedByUserID: clearedState.lockedByUserID,
            lockedByDeviceID: clearedState.lockedByDeviceID,
            lockedAt: clearedState.lockedAt
        )
#if DEBUG
        let cached = sessionCoordinationDebugRemoteRecords[sessionID]
        sessionCoordinationDebugRemoteRecords[sessionID] = RemoteSessionCoordinationRecord(
            id: sessionID,
            orgID: cached?.orgID ?? property.orgId ?? UUID(),
            propertyID: cached?.propertyID ?? property.id,
            lockedByUserID: clearedState.lockedByUserID,
            lockedByDeviceID: clearedState.lockedByDeviceID,
            lockedAt: clearedState.lockedAt?.ISO8601Format(),
            coordinationTier1Snapshot: cached?.coordinationTier1Snapshot ?? sessionCoordinationTier1SnapshotString(metadata: metadata),
            updatedAt: Date()
        )
        if AppStateTestEnvironment.isRunningUnderXCTest {
            return
        }
#endif

        _ = await persistSessionCoordinationMutation(
            property: property,
            session: session,
            metadata: metadata,
            desiredState: clearedState
        )
        setSessionCoordinationState(
            sessionID: sessionID,
            lockedByUserID: clearedState.lockedByUserID,
            lockedByDeviceID: clearedState.lockedByDeviceID,
            lockedAt: clearedState.lockedAt
        )
    }

    private func normalizedSupabaseText(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func currentDeviceIdentifier() -> String {
        if let existing = normalizedSupabaseText(userDefaults.string(forKey: deviceIdentifierDefaultsKey)) {
            return existing
        }
        let generated = UUID().uuidString.lowercased()
        userDefaults.set(generated, forKey: deviceIdentifierDefaultsKey)
        return generated
    }

    private func sessionCoordinationTier1Snapshot(metadata: SessionMetadata) -> SessionCoordinationTier1Snapshot {
        let priorities = metadata.shots
            .compactMap { shot -> SessionCoordinationTier1Snapshot.Entry? in
                guard let value = normalizedSessionPriority(shot.priority) else { return nil }
                return SessionCoordinationTier1Snapshot.Entry(id: shot.shotID, value: value)
            }
            .sorted { $0.id.uuidString < $1.id.uuidString }

        let trades = metadata.shots
            .compactMap { shot -> SessionCoordinationTier1Snapshot.Entry? in
                guard let value = normalizedSupabaseText(shot.trade) else { return nil }
                return SessionCoordinationTier1Snapshot.Entry(id: shot.shotID, value: value)
            }
            .sorted { $0.id.uuidString < $1.id.uuidString }

        let flaggedReasons = metadata.flaggedIssues
            .compactMap { issue -> SessionCoordinationTier1Snapshot.Entry? in
                guard let value = normalizedSupabaseText(issue.currentReason) else { return nil }
                return SessionCoordinationTier1Snapshot.Entry(id: issue.issueID, value: value)
            }
            .sorted { $0.id.uuidString < $1.id.uuidString }

        return SessionCoordinationTier1Snapshot(
            priorities: priorities,
            trades: trades,
            flaggedReasons: flaggedReasons
        )
    }

    private func normalizedSessionPriority(_ value: String?) -> String? {
        let trimmed = normalizedSupabaseText(value)
        switch trimmed?.lowercased() {
        case "low":
            return "Low"
        case "medium":
            return "Medium"
        case "high":
            return "High"
        case "critical":
            return "Critical"
        default:
            return nil
        }
    }

    private func sessionCoordinationTier1SnapshotString(metadata: SessionMetadata) -> String? {
        let snapshot = sessionCoordinationTier1Snapshot(metadata: metadata)
        guard !snapshot.priorities.isEmpty || !snapshot.trades.isEmpty || !snapshot.flaggedReasons.isEmpty else {
            return nil
        }
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(snapshot) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func decodeSessionCoordinationTier1Snapshot(_ value: String?) -> SessionCoordinationTier1Snapshot? {
        guard let value = normalizedSupabaseText(value), let data = value.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SessionCoordinationTier1Snapshot.self, from: data)
    }

    private func sessionCoordinationDiffs(
        remoteSnapshotString: String?,
        localMetadata: SessionMetadata
    ) -> [SessionCoordinationDiff] {
        guard let remote = decodeSessionCoordinationTier1Snapshot(remoteSnapshotString) else { return [] }
        let local = sessionCoordinationTier1Snapshot(metadata: localMetadata)

        let remotePriorities = Dictionary(uniqueKeysWithValues: remote.priorities.map { ($0.id, $0.value) })
        let localPriorities = Dictionary(uniqueKeysWithValues: local.priorities.map { ($0.id, $0.value) })
        let remoteTrades = Dictionary(uniqueKeysWithValues: remote.trades.map { ($0.id, $0.value) })
        let localTrades = Dictionary(uniqueKeysWithValues: local.trades.map { ($0.id, $0.value) })
        let remoteReasons = Dictionary(uniqueKeysWithValues: remote.flaggedReasons.map { ($0.id, $0.value) })
        let localReasons = Dictionary(uniqueKeysWithValues: local.flaggedReasons.map { ($0.id, $0.value) })

        var diffs: [SessionCoordinationDiff] = []
        for id in Set(remotePriorities.keys).union(localPriorities.keys).sorted(by: { $0.uuidString < $1.uuidString }) {
            let remoteValue = remotePriorities[id] ?? ""
            let localValue = localPriorities[id] ?? ""
            guard remoteValue != localValue else { continue }
            diffs.append(SessionCoordinationDiff(
                id: "priority|\(id.uuidString)",
                label: "Priority \(id.uuidString.prefix(8))",
                remoteValue: remoteValue,
                localValue: localValue
            ))
        }
        for id in Set(remoteTrades.keys).union(localTrades.keys).sorted(by: { $0.uuidString < $1.uuidString }) {
            let remoteValue = remoteTrades[id] ?? ""
            let localValue = localTrades[id] ?? ""
            guard remoteValue != localValue else { continue }
            diffs.append(SessionCoordinationDiff(
                id: "trade|\(id.uuidString)",
                label: "Trade \(id.uuidString.prefix(8))",
                remoteValue: remoteValue,
                localValue: localValue
            ))
        }
        for id in Set(remoteReasons.keys).union(localReasons.keys).sorted(by: { $0.uuidString < $1.uuidString }) {
            let remoteValue = remoteReasons[id] ?? ""
            let localValue = localReasons[id] ?? ""
            guard remoteValue != localValue else { continue }
            diffs.append(SessionCoordinationDiff(
                id: "reason|\(id.uuidString)",
                label: "Flagged Reason \(id.uuidString.prefix(8))",
                remoteValue: remoteValue,
                localValue: localValue
            ))
        }

        return diffs
    }

    private struct RemoteLegacyMigrationSnapshot {
        let properties: [SupabasePropertyIdentityRecord]
        let sessions: [SupabaseSessionIdentityRecord]
        let shots: [SupabaseShotIdentityRecord]
    }

    enum LegacyMigrationPreflightError: LocalizedError {
        case missingSupabaseClient
        case missingActiveOrganization

        var errorDescription: String? {
            switch self {
            case .missingSupabaseClient:
                return "Supabase must be configured before running the migration preflight."
            case .missingActiveOrganization:
                return "An active organization must be selected before running the migration preflight."
            }
        }
    }

    enum LegacyMigrationStep2AError: LocalizedError {
        case missingSupabaseClient
        case missingActiveOrganization
        case missingLedger
        case unsupportedLedgerSchema(Int)
        case activeOrgDrift(expected: UUID, actual: UUID)
        case missingRemoteActiveOrg(UUID)
        case localPropertyMissing(UUID)
        case localSessionMissing(UUID)
        case localSessionMetadataMissing(UUID)
        case localShotMissing(UUID)
        case verificationFailed(String)

        var errorDescription: String? {
            switch self {
            case .missingSupabaseClient:
                return "Supabase must be configured before running Step 2A."
            case .missingActiveOrganization:
                return "An active organization must be selected before running Step 2A."
            case .missingLedger:
                return "Run the legacy migration preflight before Step 2A."
            case .unsupportedLedgerSchema(let version):
                return "Legacy migration ledger schema version \(version) is not supported by this app."
            case .activeOrgDrift(let expected, let actual):
                return "Legacy migration ledger is pinned to org \(expected.uuidString), but the active org is \(actual.uuidString)."
            case .missingRemoteActiveOrg(let orgID):
                return "Remote active org \(orgID.uuidString) does not exist. Step 2A cannot proceed."
            case .localPropertyMissing(let propertyID):
                return "Local property \(propertyID.uuidString) could not be loaded for Step 2A."
            case .localSessionMissing(let sessionID):
                return "Local session \(sessionID.uuidString) could not be loaded for Step 2A."
            case .localSessionMetadataMissing(let sessionID):
                return "Local session metadata \(sessionID.uuidString) could not be loaded for Step 2A."
            case .localShotMissing(let shotID):
                return "Local shot \(shotID.uuidString) could not be loaded for Step 2B Slice 1."
            case .verificationFailed(let description):
                return description
            }
        }
    }

    func runLegacyMigrationPreflight() async throws -> LegacyMigrationPreflightResult {
        guard let client = supabaseClient else {
            throw LegacyMigrationPreflightError.missingSupabaseClient
        }
        guard let activeOrganizationID else {
            throw LegacyMigrationPreflightError.missingActiveOrganization
        }

        let generatedAt = Date()
        let remoteSnapshot = try await fetchLegacyMigrationRemoteSnapshot(
            client: client,
            activeOrganizationID: activeOrganizationID
        )
        let remotePropertiesByID = Dictionary(uniqueKeysWithValues: remoteSnapshot.properties.map { ($0.id, $0) })
        let remoteSessionsByID = Dictionary(uniqueKeysWithValues: remoteSnapshot.sessions.map { ($0.id, $0) })
        let remoteShotsByID = Dictionary(uniqueKeysWithValues: remoteSnapshot.shots.map { ($0.id, $0) })
        let remotePropertiesByName = Dictionary(grouping: remoteSnapshot.properties, by: { legacyMigrationToken($0.name) })
        let remoteSessionsByProperty = Dictionary(grouping: remoteSnapshot.sessions, by: \.propertyID)
        let remoteShotsBySession = Dictionary(grouping: remoteSnapshot.shots, by: \.sessionID)

        let localProperties = try localStore.fetchProperties()
            .sorted { $0.createdAt < $1.createdAt }

        var propertyEntries: [LegacyMigrationPreflightLedger.EntityEntry] = []
        var sessionEntries: [LegacyMigrationPreflightLedger.EntityEntry] = []
        var shotEntries: [LegacyMigrationPreflightLedger.EntityEntry] = []
        var mediaEntries: [LegacyMigrationPreflightLedger.MediaEntry] = []

        let iso8601 = ISO8601DateFormatter()

        for property in localProperties {
            let propertyName = normalizedSupabaseText(property.name) ?? ""
            var propertyReasons: [String] = []
            if property.orgId != activeOrganizationID {
                propertyReasons.append("propertyOrgMismatch")
            }
            if propertyName.isEmpty {
                propertyReasons.append("propertyNameMissing")
            }

            let propertyB1Remote = remotePropertiesByID[property.id]
            let propertyB2WarningIDs: [UUID] = {
                guard propertyB1Remote == nil else { return [] }
                return (remotePropertiesByName[legacyMigrationToken(property.name)] ?? [])
                    .map(\.id)
                    .filter { $0 != property.id }
                    .sorted { $0.uuidString < $1.uuidString }
            }()
            if !propertyB2WarningIDs.isEmpty {
                propertyReasons.append("possibleRemoteDuplicateByExactName")
            }

            let propertyEligible = propertyReasons.isEmpty
            propertyEntries.append(
                LegacyMigrationPreflightLedger.EntityEntry(
                    entityType: "property",
                    localID: property.id,
                    parentLocalID: nil,
                    propertyID: property.id,
                    sessionID: nil,
                    activeOrganizationID: activeOrganizationID,
                    eligible: propertyEligible,
                    b1RemoteExists: propertyB1Remote != nil,
                    b2WarningRemoteIDs: propertyB2WarningIDs,
                    reasons: propertyReasons.sorted(),
                    attributes: [
                        "name": propertyName,
                        "folderID": property.folderId ?? "",
                        "address": normalizedSupabaseText(property.address) ?? "",
                        "city": normalizedSupabaseText(property.city) ?? "",
                        "state": normalizedSupabaseText(property.state) ?? "",
                        "postalCode": normalizedSupabaseText(property.zip) ?? ""
                    ]
                )
            )

            guard property.orgId == activeOrganizationID else {
                continue
            }

            let localSessions = try localStore.fetchSessions(propertyID: property.id)
                .sorted { $0.startedAt < $1.startedAt }
            for session in localSessions {
                let metadata = try localStore.loadSessionMetadata(propertyID: property.id, sessionID: session.id)
                let sessionTitle = normalizedSupabaseText(metadata.propertyNameAtCapture ?? property.name) ?? ""
                var sessionReasons: [String] = []
                if !propertyEligible {
                    sessionReasons.append("parentPropertyIneligible")
                }
                if session.propertyID != property.id {
                    sessionReasons.append("sessionPropertyMismatch")
                }
                if metadata.propertyID != property.id {
                    sessionReasons.append("sessionMetadataPropertyMismatch")
                }
                if metadata.sessionID != session.id {
                    sessionReasons.append("sessionMetadataIDMismatch")
                }
                if let metadataOrgID = metadata.orgID, metadataOrgID != activeOrganizationID {
                    sessionReasons.append("sessionMetadataOrgMismatch")
                }

                let sessionB1Remote = remoteSessionsByID[session.id]
                let sessionB2WarningIDs: [UUID] = {
                    guard sessionB1Remote == nil else { return [] }
                    let localStartedAt = session.startedAt
                    return (remoteSessionsByProperty[property.id] ?? [])
                        .filter { remote in
                            remote.status == session.status.rawValue &&
                            legacyMigrationToken(remote.title) == legacyMigrationToken(sessionTitle) &&
                            legacyMigrationDate(from: remote.startedAt) == localStartedAt
                        }
                        .map(\.id)
                        .filter { $0 != session.id }
                        .sorted { $0.uuidString < $1.uuidString }
                }()
                if !sessionB2WarningIDs.isEmpty {
                    sessionReasons.append("possibleRemoteDuplicateByExactStartedAtStatusTitle")
                }
                if let remoteSession = sessionB1Remote, remoteSession.propertyID != property.id {
                    sessionReasons.append("remoteSessionParentMismatch")
                }

                let sessionEligible = sessionReasons.isEmpty
                sessionEntries.append(
                    LegacyMigrationPreflightLedger.EntityEntry(
                        entityType: "session",
                        localID: session.id,
                        parentLocalID: property.id,
                        propertyID: property.id,
                        sessionID: session.id,
                        activeOrganizationID: activeOrganizationID,
                        eligible: sessionEligible,
                        b1RemoteExists: sessionB1Remote != nil,
                        b2WarningRemoteIDs: sessionB2WarningIDs,
                        reasons: sessionReasons.sorted(),
                        attributes: [
                            "title": sessionTitle,
                            "status": session.status.rawValue,
                            "startedAt": iso8601.string(from: session.startedAt),
                            "completedAt": session.endedAt.map { iso8601.string(from: $0) } ?? ""
                        ]
                    )
                )

                for shot in metadata.shots {
                    let trimmedOriginalPath = shot.originalRelativePath.trimmingCharacters(in: .whitespacesAndNewlines)
                    let resolvedOriginalURL = localStore.resolveSessionRelativeFileURL(
                        propertyID: property.id,
                        sessionID: session.id,
                        relativePath: trimmedOriginalPath
                    )
                    let fileExists = resolvedOriginalURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false

                    var checksumSHA256: String?
                    var fileSizeBytes: Int64?
                    if let resolvedOriginalURL, fileExists {
                        if let attributes = try? FileManager.default.attributesOfItem(atPath: resolvedOriginalURL.path),
                           let fileSize = attributes[.size] as? NSNumber {
                            fileSizeBytes = fileSize.int64Value
                        }
                        if let data = try? Data(contentsOf: resolvedOriginalURL, options: [.mappedIfSafe]) {
                            checksumSHA256 = sha256Hex(for: data)
                        }
                    }

                    var shotReasons: [String] = []
                    if !sessionEligible {
                        shotReasons.append("parentSessionIneligible")
                    }
                    if shot.propertyID != property.id {
                        shotReasons.append("shotPropertyMismatch")
                    }
                    if shot.sessionID != session.id {
                        shotReasons.append("shotSessionMismatch")
                    }
                    if trimmedOriginalPath.isEmpty {
                        shotReasons.append("shotOriginalRelativePathMissing")
                    }

                    let shotB1Remote = remoteShotsByID[shot.shotID]
                    let shotB2WarningIDs: [UUID] = {
                        guard shotB1Remote == nil else { return [] }
                        return (remoteShotsBySession[session.id] ?? [])
                            .filter { remote in
                                if let checksumSHA256 {
                                    return remote.checksumSHA256?.lowercased() == checksumSHA256.lowercased()
                                }
                                if let localStoragePath = normalizedSupabaseText(shot.storagePath) {
                                    return legacyMigrationToken(remote.storagePath) == legacyMigrationToken(localStoragePath)
                                }
                                return false
                            }
                            .map(\.id)
                            .filter { $0 != shot.shotID }
                            .sorted { $0.uuidString < $1.uuidString }
                    }()
                    if !shotB2WarningIDs.isEmpty {
                        shotReasons.append("possibleRemoteDuplicateByExactChecksumOrStoragePath")
                    }
                    if let remoteShot = shotB1Remote, remoteShot.sessionID != session.id {
                        shotReasons.append("remoteShotParentMismatch")
                    }

                    let shotEligible = shotReasons.isEmpty
                    shotEntries.append(
                        LegacyMigrationPreflightLedger.EntityEntry(
                            entityType: "shot",
                            localID: shot.shotID,
                            parentLocalID: session.id,
                            propertyID: property.id,
                            sessionID: session.id,
                            activeOrganizationID: activeOrganizationID,
                            eligible: shotEligible,
                            b1RemoteExists: shotB1Remote != nil,
                            b2WarningRemoteIDs: shotB2WarningIDs,
                            reasons: shotReasons.sorted(),
                            attributes: [
                                "shotKey": shot.shotKey,
                                "building": shot.building,
                                "elevation": shot.elevation,
                                "detailType": shot.detailType,
                                "angleIndex": String(shot.angleIndex),
                                "uploadState": shot.uploadState
                            ]
                        )
                    )

                    var mediaReasons: [String] = []
                    if !shotEligible {
                        mediaReasons.append("parentShotIneligible")
                    }
                    if trimmedOriginalPath.isEmpty {
                        mediaReasons.append("originalRelativePathMissing")
                    }
                    if !fileExists {
                        mediaReasons.append("originalFileMissing")
                    }
                    let remoteMediaReady = normalizedSupabaseText(shotB1Remote?.storageBucket) != nil &&
                        normalizedSupabaseText(shotB1Remote?.storagePath) != nil
                    let mediaEligible = mediaReasons.isEmpty
                    mediaEntries.append(
                        LegacyMigrationPreflightLedger.MediaEntry(
                            shotID: shot.shotID,
                            propertyID: property.id,
                            sessionID: session.id,
                            activeOrganizationID: activeOrganizationID,
                            originalRelativePath: trimmedOriginalPath,
                            resolvedFilePath: resolvedOriginalURL?.path,
                            fileExists: fileExists,
                            fileSizeBytes: fileSizeBytes,
                            checksumSHA256: checksumSHA256,
                            b1RemoteExists: remoteMediaReady,
                            b2WarningRemoteIDs: shotB2WarningIDs,
                            eligible: mediaEligible,
                            reasons: mediaReasons.sorted(),
                            attributes: [
                                "originalFilename": shot.originalFilename,
                                "storageBucket": shot.storageBucket ?? "",
                                "storagePath": shot.storagePath ?? "",
                                "uploadState": shot.uploadState
                            ]
                        )
                    )
                }
            }
        }

        let summary = LegacyMigrationPreflightLedger.Summary(
            propertyCount: propertyEntries.count,
            sessionCount: sessionEntries.count,
            shotCount: shotEntries.count,
            mediaCount: mediaEntries.count,
            eligiblePropertyCount: propertyEntries.filter(\.eligible).count,
            eligibleSessionCount: sessionEntries.filter(\.eligible).count,
            eligibleShotCount: shotEntries.filter(\.eligible).count,
            eligibleMediaCount: mediaEntries.filter(\.eligible).count,
            b1PropertyCount: propertyEntries.filter(\.b1RemoteExists).count,
            b1SessionCount: sessionEntries.filter(\.b1RemoteExists).count,
            b1ShotCount: shotEntries.filter(\.b1RemoteExists).count,
            b2WarningPropertyCount: propertyEntries.filter { !$0.b2WarningRemoteIDs.isEmpty }.count,
            b2WarningSessionCount: sessionEntries.filter { !$0.b2WarningRemoteIDs.isEmpty }.count,
            b2WarningShotCount: shotEntries.filter { !$0.b2WarningRemoteIDs.isEmpty }.count,
            missingMediaCount: mediaEntries.filter { !$0.fileExists }.count
        )
        let ledger = LegacyMigrationPreflightLedger(
            schemaVersion: 1,
            generatedAt: generatedAt,
            activeOrganizationID: activeOrganizationID,
            authenticatedUserID: authenticatedSupabaseUser?.id,
            summary: summary,
            properties: propertyEntries,
            sessions: sessionEntries,
            shots: shotEntries,
            media: mediaEntries
        )
        let reportText = makeLegacyMigrationPreflightReport(
            generatedAt: generatedAt,
            activeOrganizationID: activeOrganizationID,
            summary: summary,
            propertyEntries: propertyEntries,
            sessionEntries: sessionEntries,
            shotEntries: shotEntries,
            mediaEntries: mediaEntries
        )
        let artifacts = try localStore.writeLegacyMigrationPreflightArtifacts(
            ledger: ledger,
            reportText: reportText
        )

        return LegacyMigrationPreflightResult(
            generatedAt: generatedAt,
            activeOrganizationID: activeOrganizationID,
            ledgerURL: artifacts.ledgerURL,
            reportURL: artifacts.reportURL,
            summary: summary
        )
    }

    private func fetchLegacyMigrationRemoteSnapshot(
        client: SupabaseClient,
        activeOrganizationID: UUID
    ) async throws -> RemoteLegacyMigrationSnapshot {
        let properties = try await client
            .from("properties")
            .select("id, org_id, name")
            .eq("org_id", value: activeOrganizationID.uuidString.lowercased())
            .execute()
            .value as [SupabasePropertyIdentityRecord]

        let sessions = try await client
            .from("sessions")
            .select("id, org_id, property_id, title, status, started_at")
            .eq("org_id", value: activeOrganizationID.uuidString.lowercased())
            .execute()
            .value as [SupabaseSessionIdentityRecord]

        let shots = try await client
            .from("shots")
            .select("id, org_id, session_id, storage_bucket, storage_path, checksum_sha256, upload_state")
            .eq("org_id", value: activeOrganizationID.uuidString.lowercased())
            .execute()
            .value as [SupabaseShotIdentityRecord]

        return RemoteLegacyMigrationSnapshot(
            properties: properties,
            sessions: sessions,
            shots: shots
        )
    }

    private func makeLegacyMigrationPreflightReport(
        generatedAt: Date,
        activeOrganizationID: UUID,
        summary: LegacyMigrationPreflightLedger.Summary,
        propertyEntries: [LegacyMigrationPreflightLedger.EntityEntry],
        sessionEntries: [LegacyMigrationPreflightLedger.EntityEntry],
        shotEntries: [LegacyMigrationPreflightLedger.EntityEntry],
        mediaEntries: [LegacyMigrationPreflightLedger.MediaEntry]
    ) -> String {
        var lines: [String] = []
        let iso8601 = ISO8601DateFormatter()
        lines.append("ScoutCapture Legacy Migration Preflight")
        lines.append("generatedAt: \(iso8601.string(from: generatedAt))")
        lines.append("activeOrganizationID: \(activeOrganizationID.uuidString)")
        lines.append("")
        lines.append("Counts")
        lines.append("properties: \(summary.propertyCount) eligible=\(summary.eligiblePropertyCount) b1=\(summary.b1PropertyCount) b2Warnings=\(summary.b2WarningPropertyCount)")
        lines.append("sessions: \(summary.sessionCount) eligible=\(summary.eligibleSessionCount) b1=\(summary.b1SessionCount) b2Warnings=\(summary.b2WarningSessionCount)")
        lines.append("shots: \(summary.shotCount) eligible=\(summary.eligibleShotCount) b1=\(summary.b1ShotCount) b2Warnings=\(summary.b2WarningShotCount)")
        lines.append("media: \(summary.mediaCount) eligible=\(summary.eligibleMediaCount) missingFiles=\(summary.missingMediaCount)")

        appendLegacyMigrationReportSection(
            title: "Ineligible Properties",
            entries: propertyEntries.filter { !$0.eligible },
            lines: &lines
        )
        appendLegacyMigrationReportSection(
            title: "B2 Property Warnings",
            entries: propertyEntries.filter { !$0.b2WarningRemoteIDs.isEmpty },
            lines: &lines
        )
        appendLegacyMigrationReportSection(
            title: "Ineligible Sessions",
            entries: sessionEntries.filter { !$0.eligible },
            lines: &lines
        )
        appendLegacyMigrationReportSection(
            title: "B2 Session Warnings",
            entries: sessionEntries.filter { !$0.b2WarningRemoteIDs.isEmpty },
            lines: &lines
        )
        appendLegacyMigrationReportSection(
            title: "Ineligible Shots",
            entries: shotEntries.filter { !$0.eligible },
            lines: &lines
        )
        appendLegacyMigrationReportSection(
            title: "B2 Shot Warnings",
            entries: shotEntries.filter { !$0.b2WarningRemoteIDs.isEmpty },
            lines: &lines
        )

        let missingMediaEntries = mediaEntries.filter { !$0.fileExists }
        lines.append("")
        lines.append("Missing Original Media")
        if missingMediaEntries.isEmpty {
            lines.append("none")
        } else {
            for entry in missingMediaEntries {
                lines.append(
                    "shot=\(entry.shotID.uuidString) session=\(entry.sessionID.uuidString) property=\(entry.propertyID.uuidString) path=\(entry.originalRelativePath)"
                )
            }
        }

        return lines.joined(separator: "\n")
    }

    private func appendLegacyMigrationReportSection(
        title: String,
        entries: [LegacyMigrationPreflightLedger.EntityEntry],
        lines: inout [String]
    ) {
        lines.append("")
        lines.append(title)
        if entries.isEmpty {
            lines.append("none")
            return
        }

        for entry in entries.sorted(by: { $0.localID.uuidString < $1.localID.uuidString }) {
            let reasons = entry.reasons.joined(separator: ",")
            let b2Warnings = entry.b2WarningRemoteIDs.map(\.uuidString).joined(separator: ",")
            lines.append(
                "id=\(entry.localID.uuidString) parent=\(entry.parentLocalID?.uuidString ?? "-") b1=\(entry.b1RemoteExists) reasons=\(reasons) b2=\(b2Warnings)"
            )
        }
    }

    private func legacyMigrationToken(_ value: String?) -> String {
        normalizedSupabaseText(value)?.lowercased() ?? ""
    }

    private func legacyMigrationDate(from value: String?) -> Date? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        if let date = formatter.date(from: trimmed) {
            return date
        }

        let fallbackFormatter = ISO8601DateFormatter()
        fallbackFormatter.formatOptions = [.withInternetDateTime]
        return fallbackFormatter.date(from: trimmed)
    }

    func runLegacyMigrationStep2A() async throws -> LegacyMigrationStep2AResult {
        guard let client = supabaseClient else {
            throw LegacyMigrationStep2AError.missingSupabaseClient
        }
        guard let activeOrganizationID else {
            throw LegacyMigrationStep2AError.missingActiveOrganization
        }

        let runID = UUID()
        let now = Date()
        var ledger: LegacyMigrationPreflightLedger

        do {
            ledger = try localStore.loadLegacyMigrationLedger()
        } catch {
            throw LegacyMigrationStep2AError.missingLedger
        }

        guard ledger.schemaVersion <= LegacyMigrationPreflightLedger.currentSchemaVersion else {
            ledger.mutationRun = LegacyMigrationPreflightLedger.MutationRunStatus(
                currentRunID: runID,
                state: LegacyMigrationPreflightLedger.MutationState.failedTerminal.rawValue,
                startedAt: now,
                completedAt: Date(),
                lastErrorCategory: "unsupported_ledger_schema",
                lastErrorMessage: LegacyMigrationStep2AError.unsupportedLedgerSchema(ledger.schemaVersion).localizedDescription
            )
            try localStore.writeLegacyMigrationLedger(ledger)
            throw LegacyMigrationStep2AError.unsupportedLedgerSchema(ledger.schemaVersion)
        }

        guard ledger.activeOrganizationID == activeOrganizationID else {
            ledger.mutationRun = LegacyMigrationPreflightLedger.MutationRunStatus(
                currentRunID: runID,
                state: LegacyMigrationPreflightLedger.MutationState.failedTerminal.rawValue,
                startedAt: now,
                completedAt: Date(),
                lastErrorCategory: "active_org_drift",
                lastErrorMessage: LegacyMigrationStep2AError.activeOrgDrift(
                    expected: ledger.activeOrganizationID,
                    actual: activeOrganizationID
                ).localizedDescription
            )
            try localStore.writeLegacyMigrationLedger(ledger)
            throw LegacyMigrationStep2AError.activeOrgDrift(
                expected: ledger.activeOrganizationID,
                actual: activeOrganizationID
            )
        }

        ledger.schemaVersion = LegacyMigrationPreflightLedger.currentSchemaVersion
        ledger.mutationRun = LegacyMigrationPreflightLedger.MutationRunStatus(
            currentRunID: runID,
            state: "in_progress",
            startedAt: now,
            completedAt: nil,
            lastErrorCategory: nil,
            lastErrorMessage: nil
        )
        try localStore.writeLegacyMigrationLedger(ledger)

        let propertyIndexByID = Dictionary(uniqueKeysWithValues: ledger.properties.enumerated().map { ($0.element.localID, $0.offset) })
        let sessionIndexByID = Dictionary(uniqueKeysWithValues: ledger.sessions.enumerated().map { ($0.element.localID, $0.offset) })
        let localProperties = try localStore.fetchProperties()
        let localPropertiesByID = Dictionary(uniqueKeysWithValues: localProperties.map { ($0.id, $0) })

        do {
            let remoteOrgExists = try await verifyRemoteActiveOrganizationExists(
                client: client,
                activeOrganizationID: activeOrganizationID
            )
            guard remoteOrgExists else {
                throw LegacyMigrationStep2AError.missingRemoteActiveOrg(activeOrganizationID)
            }

            for propertyID in ledger.properties.map(\.localID) {
                guard let index = propertyIndexByID[propertyID] else { continue }
                guard ledger.properties[index].activeOrganizationID == activeOrganizationID else { continue }
                guard ledger.properties[index].eligible else { continue }
                guard ledger.properties[index].b2WarningRemoteIDs.isEmpty else { continue }
                guard ledger.properties[index].mutation.state != .verified else { continue }

                if ledger.properties[index].b1RemoteExists {
                    try await verifyExistingPropertyEntry(
                        client: client,
                        activeOrganizationID: activeOrganizationID,
                        ledger: &ledger,
                        propertyIndex: index,
                        runID: runID
                    )
                    continue
                }

                guard let localProperty = localPropertiesByID[propertyID] else {
                    let message = LegacyMigrationStep2AError.localPropertyMissing(propertyID).localizedDescription
                    try markEntityFailure(
                        ledger: &ledger,
                        entityType: "property",
                        index: index,
                        state: .failedTerminal,
                        category: "local_property_missing",
                        message: message,
                        runID: runID
                    )
                    throw LegacyMigrationStep2AError.localPropertyMissing(propertyID)
                }

                try markEntityMutationState(
                    ledger: &ledger,
                    entityType: "property",
                    index: index,
                    state: .rowUpsertStarted,
                    runID: runID
                )

                let payload = makeSupabasePropertyPayload(
                    propertyID: localProperty.id,
                    orgID: activeOrganizationID,
                    property: localProperty,
                    metadata: nil
                )

                do {
                    try await upsertPropertyRowToSupabase(payload)
                } catch {
                    let category = legacyMigrationStep2AErrorCategory(for: error, fallback: "property_row_upsert_failed")
                    let state: LegacyMigrationPreflightLedger.MutationState = category == "transient_transport_failure" ? .failedRetryable : .failedTerminal
                    try markEntityFailure(
                        ledger: &ledger,
                        entityType: "property",
                        index: index,
                        state: state,
                        category: category,
                        message: error.localizedDescription,
                        runID: runID
                    )
                    throw error
                }

                try markEntityMutationState(
                    ledger: &ledger,
                    entityType: "property",
                    index: index,
                    state: .rowUpsertSucceeded,
                    runID: runID
                )

                let propertyVerified = try await verifyRemoteProperty(
                    client: client,
                    propertyID: localProperty.id,
                    activeOrganizationID: activeOrganizationID
                )
                guard propertyVerified else {
                    let message = "Property \(localProperty.id.uuidString) could not be verified remotely after upsert."
                    try markEntityFailure(
                        ledger: &ledger,
                        entityType: "property",
                        index: index,
                        state: .failedTerminal,
                        category: "property_verify_after_upsert_failed",
                        message: message,
                        runID: runID
                    )
                    throw LegacyMigrationStep2AError.verificationFailed(message)
                }

                try markEntityVerified(
                    ledger: &ledger,
                    entityType: "property",
                    index: index,
                    runID: runID
                )
            }

            for sessionID in ledger.sessions.map(\.localID) {
                guard let index = sessionIndexByID[sessionID] else { continue }
                let sessionEntry = ledger.sessions[index]
                guard sessionEntry.activeOrganizationID == activeOrganizationID else { continue }
                guard sessionEntry.eligible else { continue }
                guard sessionEntry.b2WarningRemoteIDs.isEmpty else { continue }
                guard sessionEntry.mutation.state != .verified else { continue }
                guard let propertyID = sessionEntry.propertyID else {
                    let message = "Session \(sessionID.uuidString) is missing property linkage in the ledger."
                    try markEntityFailure(
                        ledger: &ledger,
                        entityType: "session",
                        index: index,
                        state: .failedTerminal,
                        category: "session_missing_property_linkage",
                        message: message,
                        runID: runID
                    )
                    throw LegacyMigrationStep2AError.verificationFailed(message)
                }
                guard let parentPropertyIndex = propertyIndexByID[propertyID],
                      ledger.properties[parentPropertyIndex].mutation.state == .verified else {
                    continue
                }

                if sessionEntry.b1RemoteExists {
                    try await verifyExistingSessionEntry(
                        client: client,
                        activeOrganizationID: activeOrganizationID,
                        propertyID: propertyID,
                        ledger: &ledger,
                        sessionIndex: index,
                        runID: runID
                    )
                    continue
                }

                guard let localProperty = localPropertiesByID[propertyID] else {
                    let message = LegacyMigrationStep2AError.localPropertyMissing(propertyID).localizedDescription
                    try markEntityFailure(
                        ledger: &ledger,
                        entityType: "session",
                        index: index,
                        state: .failedTerminal,
                        category: "local_property_missing",
                        message: message,
                        runID: runID
                    )
                    throw LegacyMigrationStep2AError.localPropertyMissing(propertyID)
                }

                let localSessions = try localStore.fetchSessions(propertyID: propertyID)
                guard let localSession = localSessions.first(where: { $0.id == sessionID }) else {
                    let message = LegacyMigrationStep2AError.localSessionMissing(sessionID).localizedDescription
                    try markEntityFailure(
                        ledger: &ledger,
                        entityType: "session",
                        index: index,
                        state: .failedTerminal,
                        category: "local_session_missing",
                        message: message,
                        runID: runID
                    )
                    throw LegacyMigrationStep2AError.localSessionMissing(sessionID)
                }
                guard let metadata = try? localStore.loadSessionMetadata(propertyID: propertyID, sessionID: sessionID) else {
                    throw LegacyMigrationStep2AError.localSessionMetadataMissing(sessionID)
                }

                try markEntityMutationState(
                    ledger: &ledger,
                    entityType: "session",
                    index: index,
                    state: .rowUpsertStarted,
                    runID: runID
                )

                let payload = makeSupabaseSessionPayload(
                    sessionID: localSession.id,
                    propertyID: propertyID,
                    orgID: activeOrganizationID,
                    property: localProperty,
                    metadata: metadata
                )

                do {
                    try await upsertSessionRowToSupabase(payload)
                } catch {
                    let category = legacyMigrationStep2AErrorCategory(for: error, fallback: "session_row_upsert_failed")
                    let state: LegacyMigrationPreflightLedger.MutationState = category == "transient_transport_failure" ? .failedRetryable : .failedTerminal
                    try markEntityFailure(
                        ledger: &ledger,
                        entityType: "session",
                        index: index,
                        state: state,
                        category: category,
                        message: error.localizedDescription,
                        runID: runID
                    )
                    throw error
                }

                try markEntityMutationState(
                    ledger: &ledger,
                    entityType: "session",
                    index: index,
                    state: .rowUpsertSucceeded,
                    runID: runID
                )

                let sessionVerified = try await verifyRemoteSession(
                    client: client,
                    sessionID: localSession.id,
                    propertyID: propertyID,
                    activeOrganizationID: activeOrganizationID
                )
                guard sessionVerified else {
                    let message = "Session \(localSession.id.uuidString) could not be verified remotely after upsert."
                    try markEntityFailure(
                        ledger: &ledger,
                        entityType: "session",
                        index: index,
                        state: .failedTerminal,
                        category: "session_verify_after_upsert_failed",
                        message: message,
                        runID: runID
                    )
                    throw LegacyMigrationStep2AError.verificationFailed(message)
                }

                try markEntityVerified(
                    ledger: &ledger,
                    entityType: "session",
                    index: index,
                    runID: runID
                )
            }

            ledger.mutationRun.state = "completed"
            ledger.mutationRun.completedAt = Date()
            ledger.mutationRun.lastErrorCategory = nil
            ledger.mutationRun.lastErrorMessage = nil
            try localStore.writeLegacyMigrationLedger(ledger)

            return LegacyMigrationStep2AResult(
                runID: runID,
                activeOrganizationID: activeOrganizationID,
                ledgerURL: localStore.legacyMigrationLedgerURL(),
                verifiedPropertyCount: ledger.properties.filter { $0.mutation.state == .verified }.count,
                verifiedSessionCount: ledger.sessions.filter { $0.mutation.state == .verified }.count
            )
        } catch {
            if ledger.mutationRun.currentRunID == runID {
                if ledger.mutationRun.lastErrorCategory == nil {
                    ledger.mutationRun.lastErrorCategory = legacyMigrationStep2AErrorCategory(
                        for: error,
                        fallback: "step2a_failed"
                    )
                }
                ledger.mutationRun.lastErrorMessage = error.localizedDescription
                if ledger.mutationRun.state == "in_progress" {
                    let terminal = legacyMigrationStep2AIsTerminalError(error)
                    ledger.mutationRun.state = terminal
                        ? LegacyMigrationPreflightLedger.MutationState.failedTerminal.rawValue
                        : LegacyMigrationPreflightLedger.MutationState.failedRetryable.rawValue
                }
                ledger.mutationRun.completedAt = Date()
                try? localStore.writeLegacyMigrationLedger(ledger)
            }
            throw error
        }
    }

    func runLegacyMigrationStep2BSlice1() async throws -> LegacyMigrationStep2BSlice1Result {
        guard let client = supabaseClient else {
            throw LegacyMigrationStep2AError.missingSupabaseClient
        }
        guard let activeOrganizationID else {
            throw LegacyMigrationStep2AError.missingActiveOrganization
        }

        let runID = UUID()
        let now = Date()
        var ledger: LegacyMigrationPreflightLedger

        do {
            ledger = try localStore.loadLegacyMigrationLedger()
        } catch {
            throw LegacyMigrationStep2AError.missingLedger
        }

        guard ledger.schemaVersion <= LegacyMigrationPreflightLedger.currentSchemaVersion else {
            ledger.mutationRun = LegacyMigrationPreflightLedger.MutationRunStatus(
                currentRunID: runID,
                state: LegacyMigrationPreflightLedger.MutationState.failedTerminal.rawValue,
                startedAt: now,
                completedAt: Date(),
                lastErrorCategory: "unsupported_ledger_schema",
                lastErrorMessage: LegacyMigrationStep2AError.unsupportedLedgerSchema(ledger.schemaVersion).localizedDescription
            )
            try localStore.writeLegacyMigrationLedger(ledger)
            throw LegacyMigrationStep2AError.unsupportedLedgerSchema(ledger.schemaVersion)
        }

        guard ledger.activeOrganizationID == activeOrganizationID else {
            ledger.mutationRun = LegacyMigrationPreflightLedger.MutationRunStatus(
                currentRunID: runID,
                state: LegacyMigrationPreflightLedger.MutationState.failedTerminal.rawValue,
                startedAt: now,
                completedAt: Date(),
                lastErrorCategory: "active_org_drift",
                lastErrorMessage: LegacyMigrationStep2AError.activeOrgDrift(
                    expected: ledger.activeOrganizationID,
                    actual: activeOrganizationID
                ).localizedDescription
            )
            try localStore.writeLegacyMigrationLedger(ledger)
            throw LegacyMigrationStep2AError.activeOrgDrift(
                expected: ledger.activeOrganizationID,
                actual: activeOrganizationID
            )
        }

        ledger.schemaVersion = LegacyMigrationPreflightLedger.currentSchemaVersion
        ledger.mutationRun = LegacyMigrationPreflightLedger.MutationRunStatus(
            currentRunID: runID,
            state: "in_progress",
            startedAt: now,
            completedAt: nil,
            lastErrorCategory: nil,
            lastErrorMessage: nil
        )
        try localStore.writeLegacyMigrationLedger(ledger)

        let sessionIndexByID = Dictionary(uniqueKeysWithValues: ledger.sessions.enumerated().map { ($0.element.localID, $0.offset) })
        let shotIndexByID = Dictionary(uniqueKeysWithValues: ledger.shots.enumerated().map { ($0.element.localID, $0.offset) })

        do {
            let remoteOrgExists = try await verifyRemoteActiveOrganizationExists(
                client: client,
                activeOrganizationID: activeOrganizationID
            )
            guard remoteOrgExists else {
                throw LegacyMigrationStep2AError.missingRemoteActiveOrg(activeOrganizationID)
            }

            for shotID in ledger.shots.map(\.localID) {
                guard let index = shotIndexByID[shotID] else { continue }
                let shotEntry = ledger.shots[index]
                guard shotEntry.activeOrganizationID == activeOrganizationID else { continue }
                guard shotEntry.eligible else { continue }
                guard shotEntry.b2WarningRemoteIDs.isEmpty else { continue }
                guard shotEntry.mutation.state != .verified else { continue }
                guard let sessionID = shotEntry.sessionID else {
                    let message = "Shot \(shotID.uuidString) is missing session linkage in the ledger."
                    try markEntityFailure(
                        ledger: &ledger,
                        entityType: "shot",
                        index: index,
                        state: .failedTerminal,
                        category: "shot_missing_session_linkage",
                        message: message,
                        runID: runID
                    )
                    throw LegacyMigrationStep2AError.verificationFailed(message)
                }
                guard let parentSessionIndex = sessionIndexByID[sessionID],
                      ledger.sessions[parentSessionIndex].mutation.state == .verified else {
                    continue
                }

                if shotEntry.b1RemoteExists {
                    try await verifyExistingShotEntry(
                        client: client,
                        activeOrganizationID: activeOrganizationID,
                        sessionID: sessionID,
                        ledger: &ledger,
                        shotIndex: index,
                        runID: runID
                    )
                    continue
                }

                guard let propertyID = shotEntry.propertyID else {
                    let message = "Shot \(shotID.uuidString) is missing property linkage in the ledger."
                    try markEntityFailure(
                        ledger: &ledger,
                        entityType: "shot",
                        index: index,
                        state: .failedTerminal,
                        category: "shot_missing_property_linkage",
                        message: message,
                        runID: runID
                    )
                    throw LegacyMigrationStep2AError.verificationFailed(message)
                }

                guard let metadata = try? localStore.loadSessionMetadata(propertyID: propertyID, sessionID: sessionID) else {
                    let message = LegacyMigrationStep2AError.localSessionMetadataMissing(sessionID).localizedDescription
                    try markEntityFailure(
                        ledger: &ledger,
                        entityType: "shot",
                        index: index,
                        state: .failedTerminal,
                        category: "local_session_metadata_missing",
                        message: message,
                        runID: runID
                    )
                    throw LegacyMigrationStep2AError.localSessionMetadataMissing(sessionID)
                }

                guard metadata.shots.contains(where: { $0.shotID == shotID }) else {
                    let message = LegacyMigrationStep2AError.localShotMissing(shotID).localizedDescription
                    try markEntityFailure(
                        ledger: &ledger,
                        entityType: "shot",
                        index: index,
                        state: .failedTerminal,
                        category: "local_shot_missing",
                        message: message,
                        runID: runID
                    )
                    throw LegacyMigrationStep2AError.localShotMissing(shotID)
                }

                try markEntityMutationState(
                    ledger: &ledger,
                    entityType: "shot",
                    index: index,
                    state: .rowUpsertStarted,
                    runID: runID
                )

                do {
                    try await persistShotStorageMetadataToSupabase(
                        orgID: ledger.activeOrganizationID,
                        sessionID: sessionID,
                        shotID: shotID,
                        storageBucket: nil,
                        storagePath: nil,
                        checksumSHA256: nil,
                        byteSize: nil,
                        uploadState: "pending",
                        uploadAttempts: 0,
                        lastUploadError: nil
                    )
                } catch {
                    let category = legacyMigrationStep2AErrorCategory(for: error, fallback: "shot_row_upsert_failed")
                    let state: LegacyMigrationPreflightLedger.MutationState = category == "transient_transport_failure" ? .failedRetryable : .failedTerminal
                    try markEntityFailure(
                        ledger: &ledger,
                        entityType: "shot",
                        index: index,
                        state: state,
                        category: category,
                        message: error.localizedDescription,
                        runID: runID
                    )
                    throw error
                }

                try markEntityMutationState(
                    ledger: &ledger,
                    entityType: "shot",
                    index: index,
                    state: .rowUpsertSucceeded,
                    runID: runID
                )

                let shotVerified = try await verifyRemoteShot(
                    client: client,
                    shotID: shotID,
                    sessionID: sessionID,
                    activeOrganizationID: activeOrganizationID
                )
                guard shotVerified else {
                    let message = "Shot \(shotID.uuidString) could not be verified remotely after upsert."
                    try markEntityFailure(
                        ledger: &ledger,
                        entityType: "shot",
                        index: index,
                        state: .failedTerminal,
                        category: "shot_verify_after_upsert_failed",
                        message: message,
                        runID: runID
                    )
                    throw LegacyMigrationStep2AError.verificationFailed(message)
                }

                try markEntityVerified(
                    ledger: &ledger,
                    entityType: "shot",
                    index: index,
                    runID: runID
                )
            }

            ledger.mutationRun.state = "completed"
            ledger.mutationRun.completedAt = Date()
            ledger.mutationRun.lastErrorCategory = nil
            ledger.mutationRun.lastErrorMessage = nil
            try localStore.writeLegacyMigrationLedger(ledger)

            return LegacyMigrationStep2BSlice1Result(
                runID: runID,
                activeOrganizationID: activeOrganizationID,
                ledgerURL: localStore.legacyMigrationLedgerURL(),
                verifiedShotCount: ledger.shots.filter { $0.mutation.state == .verified }.count
            )
        } catch {
            if ledger.mutationRun.currentRunID == runID {
                if ledger.mutationRun.lastErrorCategory == nil {
                    ledger.mutationRun.lastErrorCategory = legacyMigrationStep2AErrorCategory(
                        for: error,
                        fallback: "step2b_slice1_failed"
                    )
                }
                ledger.mutationRun.lastErrorMessage = error.localizedDescription
                if ledger.mutationRun.state == "in_progress" {
                    let terminal = legacyMigrationStep2AIsTerminalError(error)
                    ledger.mutationRun.state = terminal
                        ? LegacyMigrationPreflightLedger.MutationState.failedTerminal.rawValue
                        : LegacyMigrationPreflightLedger.MutationState.failedRetryable.rawValue
                }
                ledger.mutationRun.completedAt = Date()
                try? localStore.writeLegacyMigrationLedger(ledger)
            }
            throw error
        }
    }

    func runLegacyMigrationStep2BSlice2A() async throws -> LegacyMigrationStep2BSlice2AResult {
        guard let client = supabaseClient else {
            throw LegacyMigrationStep2AError.missingSupabaseClient
        }
        guard let activeOrganizationID else {
            throw LegacyMigrationStep2AError.missingActiveOrganization
        }

        let runID = UUID()
        let now = Date()
        var ledger: LegacyMigrationPreflightLedger

        do {
            ledger = try localStore.loadLegacyMigrationLedger()
        } catch {
            throw LegacyMigrationStep2AError.missingLedger
        }

        guard ledger.schemaVersion <= LegacyMigrationPreflightLedger.currentSchemaVersion else {
            ledger.mutationRun = LegacyMigrationPreflightLedger.MutationRunStatus(
                currentRunID: runID,
                state: LegacyMigrationPreflightLedger.MutationState.failedTerminal.rawValue,
                startedAt: now,
                completedAt: Date(),
                lastErrorCategory: "unsupported_ledger_schema",
                lastErrorMessage: LegacyMigrationStep2AError.unsupportedLedgerSchema(ledger.schemaVersion).localizedDescription
            )
            try localStore.writeLegacyMigrationLedger(ledger)
            throw LegacyMigrationStep2AError.unsupportedLedgerSchema(ledger.schemaVersion)
        }

        guard ledger.activeOrganizationID == activeOrganizationID else {
            ledger.mutationRun = LegacyMigrationPreflightLedger.MutationRunStatus(
                currentRunID: runID,
                state: LegacyMigrationPreflightLedger.MutationState.failedTerminal.rawValue,
                startedAt: now,
                completedAt: Date(),
                lastErrorCategory: "active_org_drift",
                lastErrorMessage: LegacyMigrationStep2AError.activeOrgDrift(
                    expected: ledger.activeOrganizationID,
                    actual: activeOrganizationID
                ).localizedDescription
            )
            try localStore.writeLegacyMigrationLedger(ledger)
            throw LegacyMigrationStep2AError.activeOrgDrift(
                expected: ledger.activeOrganizationID,
                actual: activeOrganizationID
            )
        }

        ledger.schemaVersion = LegacyMigrationPreflightLedger.currentSchemaVersion
        ledger.mutationRun = LegacyMigrationPreflightLedger.MutationRunStatus(
            currentRunID: runID,
            state: "in_progress",
            startedAt: now,
            completedAt: nil,
            lastErrorCategory: nil,
            lastErrorMessage: nil
        )
        try localStore.writeLegacyMigrationLedger(ledger)

        let sessionIndexByID = Dictionary(uniqueKeysWithValues: ledger.sessions.enumerated().map { ($0.element.localID, $0.offset) })
        let shotIndexByID = Dictionary(uniqueKeysWithValues: ledger.shots.enumerated().map { ($0.element.localID, $0.offset) })
        let mediaIndexByShotID = Dictionary(uniqueKeysWithValues: ledger.media.enumerated().map { ($0.element.shotID, $0.offset) })

        do {
            let remoteOrgExists = try await verifyRemoteActiveOrganizationExists(
                client: client,
                activeOrganizationID: activeOrganizationID
            )
            guard remoteOrgExists else {
                throw LegacyMigrationStep2AError.missingRemoteActiveOrg(activeOrganizationID)
            }

            for shotID in ledger.media.map(\.shotID) {
                guard let index = mediaIndexByShotID[shotID] else { continue }
                let mediaEntry = ledger.media[index]
                guard mediaEntry.activeOrganizationID == activeOrganizationID else { continue }
                guard mediaEntry.eligible else { continue }
                guard mediaEntry.b2WarningRemoteIDs.isEmpty else { continue }
                guard mediaEntry.mutation.state != .mediaUploadSucceeded else { continue }
                guard mediaEntry.mutation.state != .verified else { continue }

                guard let parentSessionIndex = sessionIndexByID[mediaEntry.sessionID],
                      ledger.sessions[parentSessionIndex].mutation.state == .verified else {
                    continue
                }
                guard let parentShotIndex = shotIndexByID[mediaEntry.shotID],
                      ledger.shots[parentShotIndex].mutation.state == .verified else {
                    continue
                }

                let operationKey = "upload|\(mediaEntry.sessionID.uuidString.lowercased())|\(mediaEntry.shotID.uuidString.lowercased())"
                guard beginSupabaseMediaOperation(operationKey) else {
                    let message = "Shot \(mediaEntry.shotID.uuidString) already has an in-flight media operation."
                    try markEntityFailure(
                        ledger: &ledger,
                        entityType: "media",
                        index: index,
                        state: .failedTerminal,
                        category: "concurrent_media_operation",
                        message: message,
                        runID: runID
                    )
                    throw LegacyMigrationStep2AError.verificationFailed(message)
                }

                do {
                    defer { endSupabaseMediaOperation(operationKey) }

                    let localFileURL = try resolveLegacyMigrationMediaFileURL(for: mediaEntry)
                    let fileData = try Data(contentsOf: localFileURL, options: [.mappedIfSafe])
                    let recomputedChecksum = sha256Hex(for: fileData)
                    if let preflightChecksum = normalizedSupabaseText(mediaEntry.checksumSHA256),
                       preflightChecksum.lowercased() != recomputedChecksum.lowercased() {
                        let message = "Shot \(mediaEntry.shotID.uuidString) checksum changed since preflight."
                        try markEntityFailure(
                            ledger: &ledger,
                            entityType: "media",
                            index: index,
                            state: .failedTerminal,
                            category: "checksum_mismatch_since_preflight",
                            message: message,
                            runID: runID
                        )
                        throw LegacyMigrationStep2AError.verificationFailed(message)
                    }

                    guard let metadata = try? localStore.loadSessionMetadata(
                        propertyID: mediaEntry.propertyID,
                        sessionID: mediaEntry.sessionID
                    ),
                    let shot = metadata.shots.first(where: { $0.shotID == mediaEntry.shotID }) else {
                        let message = LegacyMigrationStep2AError.localShotMissing(mediaEntry.shotID).localizedDescription
                        try markEntityFailure(
                            ledger: &ledger,
                            entityType: "media",
                            index: index,
                            state: .failedTerminal,
                            category: "local_shot_missing",
                            message: message,
                            runID: runID
                        )
                        throw LegacyMigrationStep2AError.localShotMissing(mediaEntry.shotID)
                    }

                    let storagePath = operationalMediaStoragePath(
                        sessionID: mediaEntry.sessionID,
                        shotID: mediaEntry.shotID,
                        originalFilename: shot.originalFilename
                    )

                    try markEntityMutationState(
                        ledger: &ledger,
                        entityType: "media",
                        index: index,
                        state: .mediaUploadStarted,
                        runID: runID
                    )

                    do {
                        _ = try await client.storage.from(supabaseOperationalMediaBucket).upload(
                            storagePath,
                            fileURL: localFileURL,
                            options: FileOptions(
                                cacheControl: "31536000",
                                contentType: contentType(for: localFileURL),
                                upsert: true
                            )
                        )
                    } catch {
                        let category = legacyMigrationStep2AErrorCategory(for: error, fallback: "media_upload_failed")
                        let state: LegacyMigrationPreflightLedger.MutationState = category == "transient_transport_failure" ? .failedRetryable : .failedTerminal
                        try markEntityFailure(
                            ledger: &ledger,
                            entityType: "media",
                            index: index,
                            state: state,
                            category: category,
                            message: error.localizedDescription,
                            runID: runID
                        )
                        throw error
                    }

                    try markEntityMutationState(
                        ledger: &ledger,
                        entityType: "media",
                        index: index,
                        state: .mediaUploadSucceeded,
                        runID: runID
                    )
                } catch {
                    throw error
                }
            }

            ledger.mutationRun.state = "completed"
            ledger.mutationRun.completedAt = Date()
            ledger.mutationRun.lastErrorCategory = nil
            ledger.mutationRun.lastErrorMessage = nil
            try localStore.writeLegacyMigrationLedger(ledger)

            return LegacyMigrationStep2BSlice2AResult(
                runID: runID,
                activeOrganizationID: activeOrganizationID,
                ledgerURL: localStore.legacyMigrationLedgerURL(),
                uploadedMediaCount: ledger.media.filter { $0.mutation.state == .mediaUploadSucceeded || $0.mutation.state == .verified }.count
            )
        } catch {
            if ledger.mutationRun.currentRunID == runID {
                if ledger.mutationRun.lastErrorCategory == nil {
                    ledger.mutationRun.lastErrorCategory = legacyMigrationStep2AErrorCategory(
                        for: error,
                        fallback: "step2b_slice2a_failed"
                    )
                }
                ledger.mutationRun.lastErrorMessage = error.localizedDescription
                if ledger.mutationRun.state == "in_progress" {
                    let terminal = legacyMigrationStep2AIsTerminalError(error)
                    ledger.mutationRun.state = terminal
                        ? LegacyMigrationPreflightLedger.MutationState.failedTerminal.rawValue
                        : LegacyMigrationPreflightLedger.MutationState.failedRetryable.rawValue
                }
                ledger.mutationRun.completedAt = Date()
                try? localStore.writeLegacyMigrationLedger(ledger)
            }
            throw error
        }
    }

    func runLegacyMigrationStep2BSlice2BReadiness() async throws -> LegacyMigrationStep2BSlice2BReadinessResult {
        guard let client = supabaseClient else {
            throw LegacyMigrationStep2AError.missingSupabaseClient
        }
        guard let activeOrganizationID else {
            throw LegacyMigrationStep2AError.missingActiveOrganization
        }

        let runID = UUID()
        let now = Date()
        var ledger: LegacyMigrationPreflightLedger

        do {
            ledger = try localStore.loadLegacyMigrationLedger()
        } catch {
            throw LegacyMigrationStep2AError.missingLedger
        }

        guard ledger.schemaVersion <= LegacyMigrationPreflightLedger.currentSchemaVersion else {
            ledger.mutationRun = LegacyMigrationPreflightLedger.MutationRunStatus(
                currentRunID: runID,
                state: LegacyMigrationPreflightLedger.MutationState.failedTerminal.rawValue,
                startedAt: now,
                completedAt: Date(),
                lastErrorCategory: "unsupported_ledger_schema",
                lastErrorMessage: LegacyMigrationStep2AError.unsupportedLedgerSchema(ledger.schemaVersion).localizedDescription
            )
            try localStore.writeLegacyMigrationLedger(ledger)
            throw LegacyMigrationStep2AError.unsupportedLedgerSchema(ledger.schemaVersion)
        }

        guard ledger.activeOrganizationID == activeOrganizationID else {
            ledger.mutationRun = LegacyMigrationPreflightLedger.MutationRunStatus(
                currentRunID: runID,
                state: LegacyMigrationPreflightLedger.MutationState.failedTerminal.rawValue,
                startedAt: now,
                completedAt: Date(),
                lastErrorCategory: "active_org_drift",
                lastErrorMessage: LegacyMigrationStep2AError.activeOrgDrift(
                    expected: ledger.activeOrganizationID,
                    actual: activeOrganizationID
                ).localizedDescription
            )
            try localStore.writeLegacyMigrationLedger(ledger)
            throw LegacyMigrationStep2AError.activeOrgDrift(
                expected: ledger.activeOrganizationID,
                actual: activeOrganizationID
            )
        }

        ledger.schemaVersion = LegacyMigrationPreflightLedger.currentSchemaVersion
        ledger.mutationRun = LegacyMigrationPreflightLedger.MutationRunStatus(
            currentRunID: runID,
            state: "in_progress",
            startedAt: now,
            completedAt: nil,
            lastErrorCategory: nil,
            lastErrorMessage: nil
        )
        try localStore.writeLegacyMigrationLedger(ledger)

        let sessionIndexByID = Dictionary(uniqueKeysWithValues: ledger.sessions.enumerated().map { ($0.element.localID, $0.offset) })
        let shotIndexByID = Dictionary(uniqueKeysWithValues: ledger.shots.enumerated().map { ($0.element.localID, $0.offset) })
        let mediaIndexByShotID = Dictionary(uniqueKeysWithValues: ledger.media.enumerated().map { ($0.element.shotID, $0.offset) })

        do {
            let remoteOrgExists = try await verifyRemoteActiveOrganizationExists(
                client: client,
                activeOrganizationID: activeOrganizationID
            )
            guard remoteOrgExists else {
                throw LegacyMigrationStep2AError.missingRemoteActiveOrg(activeOrganizationID)
            }

            for shotID in ledger.media.map(\.shotID) {
                guard let index = mediaIndexByShotID[shotID] else { continue }
                let mediaEntry = ledger.media[index]
                guard mediaEntry.activeOrganizationID == activeOrganizationID else { continue }
                guard mediaEntry.eligible else { continue }
                guard mediaEntry.b2WarningRemoteIDs.isEmpty else { continue }
                guard mediaEntry.mutation.state == .mediaUploadSucceeded || mediaEntry.mutation.state == .verified else { continue }

                guard let parentSessionIndex = sessionIndexByID[mediaEntry.sessionID],
                      ledger.sessions[parentSessionIndex].mutation.state == .verified else {
                    continue
                }
                guard let parentShotIndex = shotIndexByID[mediaEntry.shotID],
                      ledger.shots[parentShotIndex].mutation.state == .verified else {
                    continue
                }

                guard let metadata = try? localStore.loadSessionMetadata(
                    propertyID: mediaEntry.propertyID,
                    sessionID: mediaEntry.sessionID
                ),
                let shot = metadata.shots.first(where: { $0.shotID == mediaEntry.shotID }) else {
                    let message = LegacyMigrationStep2AError.localShotMissing(mediaEntry.shotID).localizedDescription
                    try markEntityFailure(
                        ledger: &ledger,
                        entityType: "media",
                        index: index,
                        state: .failedTerminal,
                        category: "local_shot_missing",
                        message: message,
                        runID: runID
                    )
                    throw LegacyMigrationStep2AError.localShotMissing(mediaEntry.shotID)
                }

                guard let expectedChecksum = normalizedSupabaseText(mediaEntry.checksumSHA256) else {
                    let message = "Media entry \(mediaEntry.shotID.uuidString) is missing expected checksum for finalize readiness."
                    try markEntityFailure(
                        ledger: &ledger,
                        entityType: "media",
                        index: index,
                        state: .failedTerminal,
                        category: "missing_expected_checksum",
                        message: message,
                        runID: runID
                    )
                    throw LegacyMigrationStep2AError.verificationFailed(message)
                }

                guard let expectedByteSize = mediaEntry.fileSizeBytes else {
                    let message = "Media entry \(mediaEntry.shotID.uuidString) is missing expected byte size for finalize readiness."
                    try markEntityFailure(
                        ledger: &ledger,
                        entityType: "media",
                        index: index,
                        state: .failedTerminal,
                        category: "missing_expected_byte_size",
                        message: message,
                        runID: runID
                    )
                    throw LegacyMigrationStep2AError.verificationFailed(message)
                }

                let expectedStoragePath = operationalMediaStoragePath(
                    sessionID: mediaEntry.sessionID,
                    shotID: mediaEntry.shotID,
                    originalFilename: shot.originalFilename
                )
                let readinessRecord = try await fetchShotFinalizeReadinessRecord(
                    client: client,
                    shotID: mediaEntry.shotID,
                    sessionID: mediaEntry.sessionID,
                    activeOrganizationID: activeOrganizationID
                )

                guard let readinessRecord else {
                    let message = "Shot \(mediaEntry.shotID.uuidString) could not be loaded for finalize readiness."
                    try markEntityFailure(
                        ledger: &ledger,
                        entityType: "media",
                        index: index,
                        state: .failedRetryable,
                        category: "finalize_readback_missing",
                        message: message,
                        runID: runID
                    )
                    throw LegacyMigrationStep2AError.verificationFailed(message)
                }

                let hasMatchingFinalizedState =
                    readinessRecord.id == mediaEntry.shotID &&
                    readinessRecord.orgID == activeOrganizationID &&
                    readinessRecord.sessionID == mediaEntry.sessionID &&
                    normalizedSupabaseText(readinessRecord.storageBucket) == supabaseOperationalMediaBucket &&
                    normalizedSupabaseText(readinessRecord.storagePath) == expectedStoragePath &&
                    normalizedSupabaseText(readinessRecord.checksumSHA256)?.lowercased() == expectedChecksum.lowercased() &&
                    Int64(readinessRecord.byteSize ?? -1) == expectedByteSize &&
                    readinessRecord.uploadState == "uploaded"

                if hasMatchingFinalizedState {
                    try markEntityVerified(
                        ledger: &ledger,
                        entityType: "media",
                        index: index,
                        runID: runID
                    )
                    continue
                }

                let hasConflictingStorageState =
                    (normalizedSupabaseText(readinessRecord.storageBucket) != nil && normalizedSupabaseText(readinessRecord.storageBucket) != supabaseOperationalMediaBucket) ||
                    (normalizedSupabaseText(readinessRecord.storagePath) != nil && normalizedSupabaseText(readinessRecord.storagePath) != expectedStoragePath) ||
                    (normalizedSupabaseText(readinessRecord.checksumSHA256) != nil && normalizedSupabaseText(readinessRecord.checksumSHA256)?.lowercased() != expectedChecksum.lowercased()) ||
                    (readinessRecord.byteSize != nil && Int64(readinessRecord.byteSize ?? -1) != expectedByteSize)

                if hasConflictingStorageState {
                    let message = "Shot \(mediaEntry.shotID.uuidString) has conflicting remote storage metadata and is not ready for finalize."
                    try markEntityFailure(
                        ledger: &ledger,
                        entityType: "media",
                        index: index,
                        state: .failedTerminal,
                        category: "conflicting_remote_storage_state",
                        message: message,
                        runID: runID
                    )
                    throw LegacyMigrationStep2AError.verificationFailed(message)
                }

                try markMediaReadyForFinalize(
                    ledger: &ledger,
                    index: index,
                    runID: runID
                )
            }

            ledger.mutationRun.state = "completed"
            ledger.mutationRun.completedAt = Date()
            ledger.mutationRun.lastErrorCategory = nil
            ledger.mutationRun.lastErrorMessage = nil
            try localStore.writeLegacyMigrationLedger(ledger)

            return LegacyMigrationStep2BSlice2BReadinessResult(
                runID: runID,
                activeOrganizationID: activeOrganizationID,
                ledgerURL: localStore.legacyMigrationLedgerURL(),
                verifiedMediaCount: ledger.media.filter { $0.mutation.state == .verified }.count,
                readyForFinalizeCount: ledger.media.filter { $0.mutation.isReadyForFinalize }.count
            )
        } catch {
            if ledger.mutationRun.currentRunID == runID {
                if ledger.mutationRun.lastErrorCategory == nil {
                    ledger.mutationRun.lastErrorCategory = legacyMigrationStep2AErrorCategory(
                        for: error,
                        fallback: "step2b_slice2b_readiness_failed"
                    )
                }
                ledger.mutationRun.lastErrorMessage = error.localizedDescription
                if ledger.mutationRun.state == "in_progress" {
                    let terminal = legacyMigrationStep2AIsTerminalError(error)
                    ledger.mutationRun.state = terminal
                        ? LegacyMigrationPreflightLedger.MutationState.failedTerminal.rawValue
                        : LegacyMigrationPreflightLedger.MutationState.failedRetryable.rawValue
                }
                ledger.mutationRun.completedAt = Date()
                try? localStore.writeLegacyMigrationLedger(ledger)
            }
            throw error
        }
    }

    func runLegacyMigrationStep2BSlice2BFinalize() async throws -> LegacyMigrationStep2BSlice2BFinalizeResult {
        guard let client = supabaseClient else {
            throw LegacyMigrationStep2AError.missingSupabaseClient
        }
        guard let activeOrganizationID else {
            throw LegacyMigrationStep2AError.missingActiveOrganization
        }

        let runID = UUID()
        let now = Date()
        var ledger: LegacyMigrationPreflightLedger

        do {
            ledger = try localStore.loadLegacyMigrationLedger()
        } catch {
            throw LegacyMigrationStep2AError.missingLedger
        }

        guard ledger.schemaVersion <= LegacyMigrationPreflightLedger.currentSchemaVersion else {
            ledger.mutationRun = LegacyMigrationPreflightLedger.MutationRunStatus(
                currentRunID: runID,
                state: LegacyMigrationPreflightLedger.MutationState.failedTerminal.rawValue,
                startedAt: now,
                completedAt: Date(),
                lastErrorCategory: "unsupported_ledger_schema",
                lastErrorMessage: LegacyMigrationStep2AError.unsupportedLedgerSchema(ledger.schemaVersion).localizedDescription
            )
            try localStore.writeLegacyMigrationLedger(ledger)
            throw LegacyMigrationStep2AError.unsupportedLedgerSchema(ledger.schemaVersion)
        }

        guard ledger.activeOrganizationID == activeOrganizationID else {
            ledger.mutationRun = LegacyMigrationPreflightLedger.MutationRunStatus(
                currentRunID: runID,
                state: LegacyMigrationPreflightLedger.MutationState.failedTerminal.rawValue,
                startedAt: now,
                completedAt: Date(),
                lastErrorCategory: "active_org_drift",
                lastErrorMessage: LegacyMigrationStep2AError.activeOrgDrift(
                    expected: ledger.activeOrganizationID,
                    actual: activeOrganizationID
                ).localizedDescription
            )
            try localStore.writeLegacyMigrationLedger(ledger)
            throw LegacyMigrationStep2AError.activeOrgDrift(
                expected: ledger.activeOrganizationID,
                actual: activeOrganizationID
            )
        }

        guard !hasInFlightSupabaseUploadOperations() else {
            ledger.mutationRun = LegacyMigrationPreflightLedger.MutationRunStatus(
                currentRunID: runID,
                state: LegacyMigrationPreflightLedger.MutationState.failedTerminal.rawValue,
                startedAt: now,
                completedAt: Date(),
                lastErrorCategory: "concurrent_live_upload_activity",
                lastErrorMessage: "Finalize cannot run while live upload activity is in flight for this app."
            )
            try localStore.writeLegacyMigrationLedger(ledger)
            throw LegacyMigrationStep2AError.verificationFailed("Finalize cannot run while live upload activity is in flight for this app.")
        }

        ledger.schemaVersion = LegacyMigrationPreflightLedger.currentSchemaVersion
        ledger.mutationRun = LegacyMigrationPreflightLedger.MutationRunStatus(
            currentRunID: runID,
            state: "in_progress",
            startedAt: now,
            completedAt: nil,
            lastErrorCategory: nil,
            lastErrorMessage: nil
        )
        try localStore.writeLegacyMigrationLedger(ledger)

        let sessionIndexByID = Dictionary(uniqueKeysWithValues: ledger.sessions.enumerated().map { ($0.element.localID, $0.offset) })
        let shotIndexByID = Dictionary(uniqueKeysWithValues: ledger.shots.enumerated().map { ($0.element.localID, $0.offset) })
        let mediaIndexByShotID = Dictionary(uniqueKeysWithValues: ledger.media.enumerated().map { ($0.element.shotID, $0.offset) })

        do {
            let remoteOrgExists = try await verifyRemoteActiveOrganizationExists(
                client: client,
                activeOrganizationID: activeOrganizationID
            )
            guard remoteOrgExists else {
                throw LegacyMigrationStep2AError.missingRemoteActiveOrg(activeOrganizationID)
            }

            for shotID in ledger.media.map(\.shotID) {
                guard let index = mediaIndexByShotID[shotID] else { continue }
                let mediaEntry = ledger.media[index]
                guard mediaEntry.activeOrganizationID == activeOrganizationID else { continue }
                guard mediaEntry.eligible else { continue }
                guard mediaEntry.b2WarningRemoteIDs.isEmpty else { continue }

                guard let parentSessionIndex = sessionIndexByID[mediaEntry.sessionID],
                      ledger.sessions[parentSessionIndex].mutation.state == .verified else {
                    continue
                }
                guard let parentShotIndex = shotIndexByID[mediaEntry.shotID],
                      ledger.shots[parentShotIndex].mutation.state == .verified else {
                    continue
                }

                let isUploadComplete = mediaEntry.mutation.state == .mediaUploadSucceeded
                let isAlreadyVerified = mediaEntry.mutation.state == .verified
                guard isUploadComplete || isAlreadyVerified else { continue }

                guard let metadata = try? localStore.loadSessionMetadata(
                    propertyID: mediaEntry.propertyID,
                    sessionID: mediaEntry.sessionID
                ),
                let shot = metadata.shots.first(where: { $0.shotID == mediaEntry.shotID }) else {
                    let message = LegacyMigrationStep2AError.localShotMissing(mediaEntry.shotID).localizedDescription
                    try markEntityFailure(
                        ledger: &ledger,
                        entityType: "media",
                        index: index,
                        state: .failedTerminal,
                        category: "local_shot_missing",
                        message: message,
                        runID: runID
                    )
                    throw LegacyMigrationStep2AError.localShotMissing(mediaEntry.shotID)
                }

                guard let expectedChecksum = normalizedSupabaseText(mediaEntry.checksumSHA256) else {
                    let message = "Media entry \(mediaEntry.shotID.uuidString) is missing expected checksum for finalize."
                    try markEntityFailure(
                        ledger: &ledger,
                        entityType: "media",
                        index: index,
                        state: .failedTerminal,
                        category: "missing_expected_checksum",
                        message: message,
                        runID: runID
                    )
                    throw LegacyMigrationStep2AError.verificationFailed(message)
                }

                guard let expectedByteSize = mediaEntry.fileSizeBytes else {
                    let message = "Media entry \(mediaEntry.shotID.uuidString) is missing expected byte size for finalize."
                    try markEntityFailure(
                        ledger: &ledger,
                        entityType: "media",
                        index: index,
                        state: .failedTerminal,
                        category: "missing_expected_byte_size",
                        message: message,
                        runID: runID
                    )
                    throw LegacyMigrationStep2AError.verificationFailed(message)
                }

                let expectedStoragePath = operationalMediaStoragePath(
                    sessionID: mediaEntry.sessionID,
                    shotID: mediaEntry.shotID,
                    originalFilename: shot.originalFilename
                )
                let expectedBucket = supabaseOperationalMediaBucket

                let preFinalizeRecord = try await fetchShotFinalizeReadinessRecord(
                    client: client,
                    shotID: mediaEntry.shotID,
                    sessionID: mediaEntry.sessionID,
                    activeOrganizationID: activeOrganizationID
                )

                guard let preFinalizeRecord else {
                    let message = "Shot \(mediaEntry.shotID.uuidString) could not be loaded before finalize."
                    try markEntityFailure(
                        ledger: &ledger,
                        entityType: "media",
                        index: index,
                        state: .failedRetryable,
                        category: "finalize_precheck_missing",
                        message: message,
                        runID: runID
                    )
                    throw LegacyMigrationStep2AError.verificationFailed(message)
                }

                let alreadyFinalized = shotFinalizeRecord(
                    preFinalizeRecord,
                    matchesShotID: mediaEntry.shotID,
                    activeOrganizationID: activeOrganizationID,
                    sessionID: mediaEntry.sessionID,
                    storageBucket: expectedBucket,
                    storagePath: expectedStoragePath,
                    checksumSHA256: expectedChecksum,
                    byteSize: expectedByteSize,
                    uploadState: "uploaded"
                )

                if alreadyFinalized {
                    try markEntityVerified(
                        ledger: &ledger,
                        entityType: "media",
                        index: index,
                        runID: runID
                    )
                    continue
                }

                guard mediaEntry.mutation.isReadyForFinalize else {
                    let message = "Media entry \(mediaEntry.shotID.uuidString) is not marked ready for finalize."
                    try markEntityFailure(
                        ledger: &ledger,
                        entityType: "media",
                        index: index,
                        state: .failedTerminal,
                        category: "media_not_ready_for_finalize",
                        message: message,
                        runID: runID
                    )
                    throw LegacyMigrationStep2AError.verificationFailed(message)
                }

                let conflictingPreFinalizeState =
                    (normalizedSupabaseText(preFinalizeRecord.storageBucket) != nil && normalizedSupabaseText(preFinalizeRecord.storageBucket) != expectedBucket) ||
                    (normalizedSupabaseText(preFinalizeRecord.storagePath) != nil && normalizedSupabaseText(preFinalizeRecord.storagePath) != expectedStoragePath) ||
                    (normalizedSupabaseText(preFinalizeRecord.checksumSHA256) != nil && normalizedSupabaseText(preFinalizeRecord.checksumSHA256)?.lowercased() != expectedChecksum.lowercased()) ||
                    (preFinalizeRecord.byteSize != nil && Int64(preFinalizeRecord.byteSize ?? -1) != expectedByteSize)

                if conflictingPreFinalizeState {
                    let message = "Shot \(mediaEntry.shotID.uuidString) has conflicting remote storage metadata and cannot be finalized."
                    try markEntityFailure(
                        ledger: &ledger,
                        entityType: "media",
                        index: index,
                        state: .failedTerminal,
                        category: "conflicting_remote_storage_state",
                        message: message,
                        runID: runID
                    )
                    throw LegacyMigrationStep2AError.verificationFailed(message)
                }

                do {
                    try await persistShotStorageMetadataToSupabase(
                        orgID: ledger.activeOrganizationID,
                        sessionID: mediaEntry.sessionID,
                        shotID: mediaEntry.shotID,
                        storageBucket: expectedBucket,
                        storagePath: expectedStoragePath,
                        checksumSHA256: expectedChecksum,
                        byteSize: Int(exactly: expectedByteSize),
                        uploadState: "uploaded",
                        uploadAttempts: mediaEntry.mutation.attemptCount,
                        lastUploadError: nil
                    )
                } catch {
                    if let postgrestError = error as? PostgrestError,
                       postgrestError.code == "23505" {
                        let pathOwner = try await fetchShotFinalizeReadinessRecordByStoragePath(
                            client: client,
                            storageBucket: expectedBucket,
                            storagePath: expectedStoragePath,
                            activeOrganizationID: activeOrganizationID
                        )

                        if let pathOwner,
                           pathOwner.id == mediaEntry.shotID,
                           pathOwner.orgID == activeOrganizationID,
                           pathOwner.sessionID == mediaEntry.sessionID {
                            // Treat as idempotent conflict and proceed to strict verification.
                        } else {
                            let message = "Storage path conflict for shot \(mediaEntry.shotID.uuidString) is owned by a different shot."
                            try markEntityFailure(
                                ledger: &ledger,
                                entityType: "media",
                                index: index,
                                state: .failedTerminal,
                                category: "storage_path_conflict_with_different_shot",
                                message: message,
                                runID: runID
                            )
                            throw LegacyMigrationStep2AError.verificationFailed(message)
                        }
                    } else {
                        let category = legacyMigrationStep2AErrorCategory(for: error, fallback: "media_finalize_failed")
                        let state: LegacyMigrationPreflightLedger.MutationState = category == "transient_transport_failure" ? .failedRetryable : .failedTerminal
                        try markEntityFailure(
                            ledger: &ledger,
                            entityType: "media",
                            index: index,
                            state: state,
                            category: category,
                            message: error.localizedDescription,
                            runID: runID
                        )
                        throw error
                    }
                }

                let strictRecord = try await fetchShotFinalizeReadinessRecord(
                    client: client,
                    shotID: mediaEntry.shotID,
                    sessionID: mediaEntry.sessionID,
                    activeOrganizationID: activeOrganizationID
                )

                guard let strictRecord,
                      shotFinalizeRecord(
                        strictRecord,
                        matchesShotID: mediaEntry.shotID,
                        activeOrganizationID: activeOrganizationID,
                        sessionID: mediaEntry.sessionID,
                        storageBucket: expectedBucket,
                        storagePath: expectedStoragePath,
                        checksumSHA256: expectedChecksum,
                        byteSize: expectedByteSize,
                        uploadState: "uploaded"
                      ) else {
                    let message = "Strict finalize verification failed for shot \(mediaEntry.shotID.uuidString)."
                    try markEntityFailure(
                        ledger: &ledger,
                        entityType: "media",
                        index: index,
                        state: .failedTerminal,
                        category: "media_finalize_verification_failed",
                        message: message,
                        runID: runID
                    )
                    throw LegacyMigrationStep2AError.verificationFailed(message)
                }

                try markEntityVerified(
                    ledger: &ledger,
                    entityType: "media",
                    index: index,
                    runID: runID
                )
            }

            ledger.mutationRun.state = "completed"
            ledger.mutationRun.completedAt = Date()
            ledger.mutationRun.lastErrorCategory = nil
            ledger.mutationRun.lastErrorMessage = nil
            try localStore.writeLegacyMigrationLedger(ledger)

            return LegacyMigrationStep2BSlice2BFinalizeResult(
                runID: runID,
                activeOrganizationID: activeOrganizationID,
                ledgerURL: localStore.legacyMigrationLedgerURL(),
                verifiedMediaCount: ledger.media.filter { $0.mutation.state == .verified }.count
            )
        } catch {
            if ledger.mutationRun.currentRunID == runID {
                if ledger.mutationRun.lastErrorCategory == nil {
                    ledger.mutationRun.lastErrorCategory = legacyMigrationStep2AErrorCategory(
                        for: error,
                        fallback: "step2b_slice2b_finalize_failed"
                    )
                }
                ledger.mutationRun.lastErrorMessage = error.localizedDescription
                if ledger.mutationRun.state == "in_progress" {
                    let terminal = legacyMigrationStep2AIsTerminalError(error)
                    ledger.mutationRun.state = terminal
                        ? LegacyMigrationPreflightLedger.MutationState.failedTerminal.rawValue
                        : LegacyMigrationPreflightLedger.MutationState.failedRetryable.rawValue
                }
                ledger.mutationRun.completedAt = Date()
                try? localStore.writeLegacyMigrationLedger(ledger)
            }
            throw error
        }
    }

    private func verifyRemoteActiveOrganizationExists(
        client: SupabaseClient,
        activeOrganizationID: UUID
    ) async throws -> Bool {
        let rows = try await client
            .from("orgs")
            .select("id")
            .eq("id", value: activeOrganizationID.uuidString.lowercased())
            .limit(1)
            .execute()
            .value as [SupabaseOrgIdentityRecord]

        return rows.first?.id == activeOrganizationID
    }

    private func verifyRemoteProperty(
        client: SupabaseClient,
        propertyID: UUID,
        activeOrganizationID: UUID
    ) async throws -> Bool {
        let rows = try await client
            .from("properties")
            .select("id, org_id, name")
            .eq("id", value: propertyID.uuidString.lowercased())
            .eq("org_id", value: activeOrganizationID.uuidString.lowercased())
            .limit(1)
            .execute()
            .value as [SupabasePropertyIdentityRecord]

        guard let row = rows.first else { return false }
        return row.id == propertyID && row.orgID == activeOrganizationID
    }

    private func verifyRemoteSession(
        client: SupabaseClient,
        sessionID: UUID,
        propertyID: UUID,
        activeOrganizationID: UUID
    ) async throws -> Bool {
        let rows = try await client
            .from("sessions")
            .select("id, org_id, property_id, title, status, started_at")
            .eq("id", value: sessionID.uuidString.lowercased())
            .eq("org_id", value: activeOrganizationID.uuidString.lowercased())
            .eq("property_id", value: propertyID.uuidString.lowercased())
            .limit(1)
            .execute()
            .value as [SupabaseSessionIdentityRecord]

        guard let row = rows.first else { return false }
        return row.id == sessionID && row.orgID == activeOrganizationID && row.propertyID == propertyID
    }

    private func verifyRemoteShot(
        client: SupabaseClient,
        shotID: UUID,
        sessionID: UUID,
        activeOrganizationID: UUID
    ) async throws -> Bool {
        let rows = try await client
            .from("shots")
            .select("id, org_id, session_id, storage_bucket, storage_path, checksum_sha256, upload_state")
            .eq("id", value: shotID.uuidString.lowercased())
            .eq("org_id", value: activeOrganizationID.uuidString.lowercased())
            .eq("session_id", value: sessionID.uuidString.lowercased())
            .limit(1)
            .execute()
            .value as [SupabaseShotIdentityRecord]

        guard let row = rows.first else { return false }
        return row.id == shotID && row.orgID == activeOrganizationID && row.sessionID == sessionID
    }

    private func verifyExistingPropertyEntry(
        client: SupabaseClient,
        activeOrganizationID: UUID,
        ledger: inout LegacyMigrationPreflightLedger,
        propertyIndex: Int,
        runID: UUID
    ) async throws {
        let propertyID = ledger.properties[propertyIndex].localID
        let verified = try await verifyRemoteProperty(
            client: client,
            propertyID: propertyID,
            activeOrganizationID: activeOrganizationID
        )

        guard verified else {
            let message = "Property \(propertyID.uuidString) was marked B1 but remote verification failed."
            try markEntityFailure(
                ledger: &ledger,
                entityType: "property",
                index: propertyIndex,
                state: .failedTerminal,
                category: "property_b1_verification_failed",
                message: message,
                runID: runID
            )
            throw LegacyMigrationStep2AError.verificationFailed(message)
        }

        try markEntityVerified(
            ledger: &ledger,
            entityType: "property",
            index: propertyIndex,
            runID: runID
        )
    }

    private func verifyExistingSessionEntry(
        client: SupabaseClient,
        activeOrganizationID: UUID,
        propertyID: UUID,
        ledger: inout LegacyMigrationPreflightLedger,
        sessionIndex: Int,
        runID: UUID
    ) async throws {
        let sessionID = ledger.sessions[sessionIndex].localID
        let verified = try await verifyRemoteSession(
            client: client,
            sessionID: sessionID,
            propertyID: propertyID,
            activeOrganizationID: activeOrganizationID
        )

        guard verified else {
            let message = "Session \(sessionID.uuidString) was marked B1 but remote verification failed."
            try markEntityFailure(
                ledger: &ledger,
                entityType: "session",
                index: sessionIndex,
                state: .failedTerminal,
                category: "session_b1_verification_failed",
                message: message,
                runID: runID
            )
            throw LegacyMigrationStep2AError.verificationFailed(message)
        }

        try markEntityVerified(
            ledger: &ledger,
            entityType: "session",
            index: sessionIndex,
            runID: runID
        )
    }

    private func verifyExistingShotEntry(
        client: SupabaseClient,
        activeOrganizationID: UUID,
        sessionID: UUID,
        ledger: inout LegacyMigrationPreflightLedger,
        shotIndex: Int,
        runID: UUID
    ) async throws {
        let shotID = ledger.shots[shotIndex].localID
        let verified = try await verifyRemoteShot(
            client: client,
            shotID: shotID,
            sessionID: sessionID,
            activeOrganizationID: activeOrganizationID
        )

        guard verified else {
            let message = "Shot \(shotID.uuidString) was marked B1 but remote verification failed."
            try markEntityFailure(
                ledger: &ledger,
                entityType: "shot",
                index: shotIndex,
                state: .failedTerminal,
                category: "shot_b1_verification_failed",
                message: message,
                runID: runID
            )
            throw LegacyMigrationStep2AError.verificationFailed(message)
        }

        try markEntityVerified(
            ledger: &ledger,
            entityType: "shot",
            index: shotIndex,
            runID: runID
        )
    }

    private func resolveLegacyMigrationMediaFileURL(
        for mediaEntry: LegacyMigrationPreflightLedger.MediaEntry
    ) throws -> URL {
        if let resolvedFilePath = normalizedSupabaseText(mediaEntry.resolvedFilePath) {
            let directURL = URL(fileURLWithPath: resolvedFilePath)
            if FileManager.default.fileExists(atPath: directURL.path) {
                return directURL
            }
        }

        if let resolved = localStore.resolveSessionRelativeFileURL(
            propertyID: mediaEntry.propertyID,
            sessionID: mediaEntry.sessionID,
            relativePath: mediaEntry.originalRelativePath
        ), FileManager.default.fileExists(atPath: resolved.path) {
            return resolved
        }

        let fallbackURL = localStore
            .sessionFolderURL(propertyID: mediaEntry.propertyID, sessionID: mediaEntry.sessionID)
            .appendingPathComponent(mediaEntry.originalRelativePath, isDirectory: false)
        if FileManager.default.fileExists(atPath: fallbackURL.path) {
            return fallbackURL
        }

        throw NSError(
            domain: "ScoutCapture.LegacyMigration",
            code: 404,
            userInfo: [NSLocalizedDescriptionKey: "Original media file is missing for shot \(mediaEntry.shotID.uuidString)."]
        )
    }

    private func fetchShotFinalizeReadinessRecord(
        client: SupabaseClient,
        shotID: UUID,
        sessionID: UUID,
        activeOrganizationID: UUID
    ) async throws -> SupabaseShotFinalizeReadinessRecord? {
        let rows = try await client
            .from("shots")
            .select("id, org_id, session_id, storage_bucket, storage_path, checksum_sha256, byte_size, upload_state")
            .eq("id", value: shotID.uuidString.lowercased())
            .eq("org_id", value: activeOrganizationID.uuidString.lowercased())
            .eq("session_id", value: sessionID.uuidString.lowercased())
            .limit(1)
            .execute()
            .value as [SupabaseShotFinalizeReadinessRecord]

        return rows.first
    }

    private func markMediaReadyForFinalize(
        ledger: inout LegacyMigrationPreflightLedger,
        index: Int,
        runID: UUID
    ) throws {
        ledger.media[index].mutation.lastRunID = runID
        ledger.media[index].mutation.lastErrorCategory = nil
        ledger.media[index].mutation.lastErrorMessage = nil
        ledger.media[index].mutation.isReadyForFinalize = true
        try localStore.writeLegacyMigrationLedger(ledger)
    }

    private func fetchShotFinalizeReadinessRecordByStoragePath(
        client: SupabaseClient,
        storageBucket: String,
        storagePath: String,
        activeOrganizationID: UUID
    ) async throws -> SupabaseShotFinalizeReadinessRecord? {
        let rows = try await client
            .from("shots")
            .select("id, org_id, session_id, storage_bucket, storage_path, checksum_sha256, byte_size, upload_state")
            .eq("org_id", value: activeOrganizationID.uuidString.lowercased())
            .eq("storage_bucket", value: storageBucket)
            .eq("storage_path", value: storagePath)
            .limit(1)
            .execute()
            .value as [SupabaseShotFinalizeReadinessRecord]

        return rows.first
    }

    private func shotFinalizeRecord(
        _ record: SupabaseShotFinalizeReadinessRecord,
        matchesShotID shotID: UUID,
        activeOrganizationID: UUID,
        sessionID: UUID,
        storageBucket: String,
        storagePath: String,
        checksumSHA256: String,
        byteSize: Int64,
        uploadState: String
    ) -> Bool {
        record.id == shotID &&
        record.orgID == activeOrganizationID &&
        record.sessionID == sessionID &&
        normalizedSupabaseText(record.storageBucket) == storageBucket &&
        normalizedSupabaseText(record.storagePath) == storagePath &&
        normalizedSupabaseText(record.checksumSHA256)?.lowercased() == checksumSHA256.lowercased() &&
        Int64(record.byteSize ?? -1) == byteSize &&
        record.uploadState == uploadState
    }

    private func hasInFlightSupabaseUploadOperations() -> Bool {
        supabaseMediaOperationQueue.sync {
            inFlightSupabaseMediaOperations.contains { $0.hasPrefix("upload|") }
        }
    }

    private func markEntityMutationState(
        ledger: inout LegacyMigrationPreflightLedger,
        entityType: String,
        index: Int,
        state: LegacyMigrationPreflightLedger.MutationState,
        runID: UUID
    ) throws {
        let now = Date()
        switch entityType {
        case "property":
            ledger.properties[index].mutation.state = state
            ledger.properties[index].mutation.lastRunID = runID
            ledger.properties[index].mutation.lastAttemptedAt = now
            if state == .rowUpsertStarted || state == .mediaUploadStarted {
                ledger.properties[index].mutation.attemptCount += 1
            }
            ledger.properties[index].mutation.lastErrorCategory = nil
            ledger.properties[index].mutation.lastErrorMessage = nil
        case "session":
            ledger.sessions[index].mutation.state = state
            ledger.sessions[index].mutation.lastRunID = runID
            ledger.sessions[index].mutation.lastAttemptedAt = now
            if state == .rowUpsertStarted || state == .mediaUploadStarted {
                ledger.sessions[index].mutation.attemptCount += 1
            }
            ledger.sessions[index].mutation.lastErrorCategory = nil
            ledger.sessions[index].mutation.lastErrorMessage = nil
        case "shot":
            ledger.shots[index].mutation.state = state
            ledger.shots[index].mutation.lastRunID = runID
            ledger.shots[index].mutation.lastAttemptedAt = now
            if state == .rowUpsertStarted || state == .mediaUploadStarted {
                ledger.shots[index].mutation.attemptCount += 1
            }
            ledger.shots[index].mutation.lastErrorCategory = nil
            ledger.shots[index].mutation.lastErrorMessage = nil
        case "media":
            ledger.media[index].mutation.state = state
            ledger.media[index].mutation.lastRunID = runID
            ledger.media[index].mutation.lastAttemptedAt = now
            if state == .rowUpsertStarted || state == .mediaUploadStarted {
                ledger.media[index].mutation.attemptCount += 1
            }
            ledger.media[index].mutation.lastErrorCategory = nil
            ledger.media[index].mutation.lastErrorMessage = nil
            ledger.media[index].mutation.isReadyForFinalize = false
        default:
            return
        }
        try localStore.writeLegacyMigrationLedger(ledger)
    }

    private func markEntityVerified(
        ledger: inout LegacyMigrationPreflightLedger,
        entityType: String,
        index: Int,
        runID: UUID
    ) throws {
        let now = Date()
        switch entityType {
        case "property":
            ledger.properties[index].mutation.state = .verified
            ledger.properties[index].mutation.lastRunID = runID
            ledger.properties[index].mutation.lastVerifiedAt = now
            ledger.properties[index].mutation.lastErrorCategory = nil
            ledger.properties[index].mutation.lastErrorMessage = nil
        case "session":
            ledger.sessions[index].mutation.state = .verified
            ledger.sessions[index].mutation.lastRunID = runID
            ledger.sessions[index].mutation.lastVerifiedAt = now
            ledger.sessions[index].mutation.lastErrorCategory = nil
            ledger.sessions[index].mutation.lastErrorMessage = nil
        case "shot":
            ledger.shots[index].mutation.state = .verified
            ledger.shots[index].mutation.lastRunID = runID
            ledger.shots[index].mutation.lastVerifiedAt = now
            ledger.shots[index].mutation.lastErrorCategory = nil
            ledger.shots[index].mutation.lastErrorMessage = nil
        case "media":
            ledger.media[index].mutation.state = .verified
            ledger.media[index].mutation.lastRunID = runID
            ledger.media[index].mutation.lastVerifiedAt = now
            ledger.media[index].mutation.lastErrorCategory = nil
            ledger.media[index].mutation.lastErrorMessage = nil
            ledger.media[index].mutation.isReadyForFinalize = false
        default:
            return
        }
        try localStore.writeLegacyMigrationLedger(ledger)
    }

    private func markEntityFailure(
        ledger: inout LegacyMigrationPreflightLedger,
        entityType: String,
        index: Int,
        state: LegacyMigrationPreflightLedger.MutationState,
        category: String,
        message: String,
        runID: UUID
    ) throws {
        switch entityType {
        case "property":
            ledger.properties[index].mutation.state = state
            ledger.properties[index].mutation.lastRunID = runID
            ledger.properties[index].mutation.lastErrorCategory = category
            ledger.properties[index].mutation.lastErrorMessage = message
        case "session":
            ledger.sessions[index].mutation.state = state
            ledger.sessions[index].mutation.lastRunID = runID
            ledger.sessions[index].mutation.lastErrorCategory = category
            ledger.sessions[index].mutation.lastErrorMessage = message
        case "shot":
            ledger.shots[index].mutation.state = state
            ledger.shots[index].mutation.lastRunID = runID
            ledger.shots[index].mutation.lastErrorCategory = category
            ledger.shots[index].mutation.lastErrorMessage = message
        case "media":
            ledger.media[index].mutation.state = state
            ledger.media[index].mutation.lastRunID = runID
            ledger.media[index].mutation.lastErrorCategory = category
            ledger.media[index].mutation.lastErrorMessage = message
            ledger.media[index].mutation.isReadyForFinalize = false
        default:
            return
        }
        ledger.mutationRun.lastErrorCategory = category
        ledger.mutationRun.lastErrorMessage = message
        ledger.mutationRun.state = state.rawValue
        ledger.mutationRun.completedAt = Date()
        try localStore.writeLegacyMigrationLedger(ledger)
    }

    private func legacyMigrationStep2AErrorCategory(for error: Error, fallback: String) -> String {
        if let step2Error = error as? LegacyMigrationStep2AError {
            switch step2Error {
            case .missingRemoteActiveOrg:
                return "missing_remote_active_org"
            case .activeOrgDrift:
                return "active_org_drift"
            case .unsupportedLedgerSchema:
                return "unsupported_ledger_schema"
            case .missingLedger:
                return "missing_ledger"
            case .localPropertyMissing:
                return "local_property_missing"
            case .localSessionMissing:
                return "local_session_missing"
            case .localSessionMetadataMissing:
                return "local_session_metadata_missing"
            case .localShotMissing:
                return "local_shot_missing"
            case .verificationFailed:
                return "verification_failed"
            case .missingSupabaseClient:
                return "missing_supabase_client"
            case .missingActiveOrganization:
                return "missing_active_org"
            }
        }

        if let httpError = error as? HTTPError {
            switch httpError.response.statusCode {
            case 408, 425, 429:
                return "transient_transport_failure"
            case 500 ... 599:
                return "transient_transport_failure"
            case 401, 403:
                return "permission_denied"
            case 400 ... 499:
                return "request_rejected"
            default:
                return fallback
            }
        }

        if let postgrestError = error as? PostgrestError {
            let code = postgrestError.code?.uppercased() ?? ""
            let message = postgrestError.message.lowercased()

            if code == "42501" {
                return "permission_denied"
            }
            if code == "57014" || code == "57P03" || code == "53300" || code == "53400" || code == "40001" || code == "40P01" || code.hasPrefix("08") {
                return "transient_transport_failure"
            }
            if message.contains("timeout")
                || message.contains("timed out")
                || message.contains("temporar")
                || message.contains("try again")
                || message.contains("rate limit")
                || message.contains("too many requests")
                || message.contains("connection") && message.contains("closed")
            {
                return "transient_transport_failure"
            }
            if code.hasPrefix("22") || code.hasPrefix("23") || code.hasPrefix("42") {
                return "request_rejected"
            }
            return fallback
        }

        if let storageError = error as? StorageError {
            if let statusCode = Int(storageError.statusCode ?? "") {
                switch statusCode {
                case 408, 425, 429:
                    return "transient_transport_failure"
                case 500 ... 599:
                    return "transient_transport_failure"
                case 401, 403:
                    return "permission_denied"
                case 400 ... 499:
                    return "request_rejected"
                default:
                    break
                }
            }

            let message = storageError.message.lowercased()
            if message.contains("timeout")
                || message.contains("temporar")
                || message.contains("try again")
                || message.contains("rate limit")
                || message.contains("too many requests")
            {
                return "transient_transport_failure"
            }
            return fallback
        }

        let nsError = error as NSError
        let domain = nsError.domain.lowercased()
        if domain.contains("url") || domain.contains("network") || domain.contains("nsurl") {
            return "transient_transport_failure"
        }
        return fallback
    }

    private func legacyMigrationStep2AIsTerminalError(_ error: Error) -> Bool {
        if error is LegacyMigrationStep2AError {
            return true
        }
        let category = legacyMigrationStep2AErrorCategory(for: error, fallback: "unknown")
        return category != "transient_transport_failure"
    }

    private func fetchShotStorageMetadataFromSupabase(
        sessionID: UUID,
        shotID: UUID
    ) async throws -> SupabaseShotStorageRecord? {
        guard let client = supabaseClient else { return nil }
        guard let activeOrganizationID else { return nil }

        let rows = try await client
            .from("shots")
            .select(
                """
                id,
                storage_bucket,
                storage_path,
                checksum_sha256,
                byte_size,
                upload_state,
                upload_attempts,
                last_upload_error
                """
            )
            .eq("id", value: shotID.uuidString.lowercased())
            .eq("session_id", value: sessionID.uuidString.lowercased())
            .eq("org_id", value: activeOrganizationID.uuidString.lowercased())
            .limit(1)
            .execute()
            .value as [SupabaseShotStorageRecord]

        return rows.first
    }

    private func resolveShotStorageMetadata(
        propertyID: UUID,
        sessionID: UUID,
        shot: ShotMetadata
    ) async -> ShotMetadata {
        let hasLocalBucket = shot.storageBucket?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let hasLocalPath = shot.storagePath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        guard !(hasLocalBucket && hasLocalPath) else {
            return shot
        }

        guard let remote = try? await fetchShotStorageMetadataFromSupabase(
            sessionID: sessionID,
            shotID: shot.shotID
        ) else {
            return shot
        }

        try? localStore.updateShotStorageMetadata(propertyID: propertyID, sessionID: sessionID, shotID: shot.shotID) { localShot in
            localShot.storageBucket = remote.storageBucket
            localShot.storagePath = remote.storagePath
            localShot.checksumSHA256 = remote.checksumSHA256
            localShot.byteSize = remote.byteSize
            localShot.uploadState = remote.uploadState
            localShot.uploadAttempts = max(localShot.uploadAttempts, remote.uploadAttempts)
            localShot.lastUploadError = remote.lastUploadError
        }

        var resolvedShot = shot
        resolvedShot.storageBucket = remote.storageBucket
        resolvedShot.storagePath = remote.storagePath
        resolvedShot.checksumSHA256 = remote.checksumSHA256
        resolvedShot.byteSize = remote.byteSize
        resolvedShot.uploadState = remote.uploadState
        resolvedShot.uploadAttempts = max(resolvedShot.uploadAttempts, remote.uploadAttempts)
        resolvedShot.lastUploadError = remote.lastUploadError
        return resolvedShot
    }

    private func operationalMediaStoragePath(
        sessionID: UUID,
        shotID: UUID,
        originalFilename: String
    ) -> String {
        let normalizedFilename = sanitizedStorageFilename(originalFilename, fallbackShotID: shotID)
        return "sessions/\(sessionID.uuidString.lowercased())/shots/\(shotID.uuidString.lowercased())/\(normalizedFilename)"
    }

    private func sanitizedStorageFilename(_ originalFilename: String, fallbackShotID: UUID) -> String {
        let candidate = URL(fileURLWithPath: originalFilename).lastPathComponent
        let fallback = "\(fallbackShotID.uuidString.lowercased()).heic"
        let base = candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : candidate
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let sanitizedScalars = base.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let sanitized = String(sanitizedScalars)
        return sanitized.isEmpty ? fallback : sanitized
    }

    private func contentType(for fileURL: URL) -> String {
        let fileExtension = fileURL.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        #if canImport(UniformTypeIdentifiers)
        if let type = UTType(filenameExtension: fileExtension),
           let mimeType = type.preferredMIMEType {
            return mimeType
        }
        #endif

        switch fileExtension.lowercased() {
        case "heic", "heif":
            return "image/heic"
        case "jpg", "jpeg":
            return "image/jpeg"
        case "png":
            return "image/png"
        default:
            return "application/octet-stream"
        }
    }

    private func sha256Hex(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func supabaseUploadOperationKey(sessionID: UUID, shotID: UUID) -> String {
        "upload|\(sessionID.uuidString.lowercased())|\(shotID.uuidString.lowercased())"
    }

    private func beginSupabaseMediaOperation(_ key: String) -> Bool {
        supabaseMediaOperationQueue.sync {
            if inFlightSupabaseMediaOperations.contains(key) {
                return false
            }
            inFlightSupabaseMediaOperations.insert(key)
            return true
        }
    }

    private func endSupabaseMediaOperation(_ key: String) {
        let _: Void = supabaseMediaOperationQueue.sync {
            inFlightSupabaseMediaOperations.remove(key)
        }
    }

    private func snapshotInFlightSupabaseMediaOperations() -> Set<String> {
        supabaseMediaOperationQueue.sync {
            inFlightSupabaseMediaOperations
        }
    }

    private func beginSupabaseMediaBackfillRun() -> Bool {
        supabaseMediaOperationQueue.sync {
            if isSupabaseMediaBackfillInProgress {
                return false
            }
            isSupabaseMediaBackfillInProgress = true
            return true
        }
    }

    private func endSupabaseMediaBackfillRun() {
        let _: Void = supabaseMediaOperationQueue.sync {
            isSupabaseMediaBackfillInProgress = false
        }
    }

    private func fetchRemotePropertyList(activeOrganizationID: UUID) async throws -> [RemotePropertyRecord] {
        guard let client = supabaseClient else {
            throw RemotePropertyFetchError.missingClient
        }

        return try await withThrowingTaskGroup(of: [RemotePropertyRecord].self) { group in
            group.addTask {
                try await client
                    .from("properties")
                    .select(
                        """
                        id,
                        org_id,
                        folder_id,
                        client_name,
                        client_email,
                        client_phone,
                        name,
                        address_line1,
                        city,
                        state,
                        postal_code,
                        baseline_session_id,
                        is_archived,
                        created_at,
                        updated_at
                        """
                    )
                    .eq("org_id", value: activeOrganizationID.uuidString.lowercased())
                    .execute()
                    .value as [RemotePropertyRecord]
            }

            group.addTask {
                try await Task.sleep(nanoseconds: 3_000_000_000)
                throw RemotePropertyFetchError.timedOut
            }

            guard let firstResult = try await group.next() else {
                throw RemotePropertyFetchError.timedOut
            }
            group.cancelAll()
            return firstResult
        }
    }

    private func validateRemotePropertyResponse(
        records: [RemotePropertyRecord],
        localCacheCount: Int,
        activeOrganizationID: UUID
    ) throws -> [RemotePropertyRecord] {
        if localCacheCount > 0 && records.isEmpty {
            throw RemotePropertyFetchError.emptyResponseRejected(localCacheCount: localCacheCount)
        }

        var seenIDs = Set<UUID>()
        for record in records {
            let trimmedName = record.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedAddressLine1 = record.addressLine1.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedCity = record.city.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedState = record.state.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedPostalCode = record.postalCode.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else {
                throw RemotePropertyFetchError.invalidPropertyName(record.id)
            }
            guard !trimmedAddressLine1.isEmpty else {
                throw RemotePropertyFetchError.invalidAddressLine1(record.id)
            }
            guard !trimmedCity.isEmpty else {
                throw RemotePropertyFetchError.invalidCity(record.id)
            }
            guard !trimmedState.isEmpty else {
                throw RemotePropertyFetchError.invalidState(record.id)
            }
            guard !trimmedPostalCode.isEmpty else {
                throw RemotePropertyFetchError.invalidPostalCode(record.id)
            }
            guard record.orgID == activeOrganizationID else {
                throw RemotePropertyFetchError.orgScopeMismatch(
                    expected: activeOrganizationID,
                    actual: record.orgID,
                    propertyID: record.id
                )
            }
            guard seenIDs.insert(record.id).inserted else {
                throw RemotePropertyFetchError.duplicatePropertyID(record.id)
            }
            guard remotePropertyDateIsValid(record.updatedAt) else {
                logRemotePropertyTimestampIssue(
                    kind: "updated_at",
                    propertyID: record.id,
                    orgID: record.orgID,
                    value: record.updatedAt
                )
                throw RemotePropertyFetchError.invalidUpdatedAt(record.id)
            }
            if let createdAt = record.createdAt,
               !remotePropertyDateIsValid(createdAt) {
                logRemotePropertyTimestampIssue(
                    kind: "created_at",
                    propertyID: record.id,
                    orgID: record.orgID,
                    value: createdAt
                )
                throw RemotePropertyFetchError.invalidCreatedAt(record.id)
            }
        }

        return records
    }

    private func makeRemotePropertyRefreshPayload(
        validatedRecords: [RemotePropertyRecord],
        requestedOrganizationID: UUID
    ) throws -> PropertyRefreshPayload {
        let normalizedRecords = try normalizedRemotePropertyRecordsForPayload(
            validatedRecords,
            requestedOrganizationID: requestedOrganizationID
        )
        let properties: [Property] = try normalizedRecords.map { record in
            let trimmedAddressLine1 = record.addressLine1.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedCity = record.city.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedState = record.state.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedPostalCode = record.postalCode.trimmingCharacters(in: .whitespacesAndNewlines)
            let createdAt = try resolvedRemotePropertyCreatedAt(for: record)
            let address = "\(trimmedAddressLine1), \(trimmedCity), \(trimmedState) \(trimmedPostalCode)"
            return Property(
                id: record.id,
                orgId: record.orgID,
                folderId: normalizedRemotePropertyText(record.folderID),
                clientName: normalizedRemotePropertyText(record.clientName),
                clientPhone: normalizedRemotePropertyText(record.clientPhone),
                clientEmail: normalizedRemotePropertyText(record.clientEmail),
                name: record.name.trimmingCharacters(in: .whitespacesAndNewlines),
                address: address,
                street: trimmedAddressLine1,
                city: trimmedCity,
                state: trimmedState,
                zip: trimmedPostalCode,
                baselineSessionID: record.baselineSessionID,
                isArchived: record.isArchived,
                createdAt: createdAt,
                updatedAt: record.updatedAt
            )
        }.sorted(by: Self.propertyIsOrderedBefore)
        let organizations = allOrganizations.isEmpty ? organizations : allOrganizations
        let caches = makeHubCaches(for: properties)
        let fingerprint = try remotePropertyFingerprint(
            for: normalizedRecords,
            activeOrganizationID: requestedOrganizationID
        )
        return PropertyRefreshPayload(
            properties: properties,
            organizations: organizations,
            caches: caches,
            fingerprint: fingerprint
        )
    }

    private func normalizedRemotePropertyRecordsForPayload(
        _ records: [RemotePropertyRecord],
        requestedOrganizationID: UUID
    ) throws -> [RemotePropertyRecord] {
        let sortedRecords = records.sorted { lhs, rhs in
            lhs.id.uuidString.lowercased() < rhs.id.uuidString.lowercased()
        }
        for record in sortedRecords {
            guard record.orgID == requestedOrganizationID else {
                throw RemotePropertyFetchError.orgScopeMismatch(
                    expected: requestedOrganizationID,
                    actual: record.orgID,
                    propertyID: record.id
                )
            }
            guard remotePropertyDateIsValid(record.updatedAt) else {
                logRemotePropertyTimestampIssue(
                    kind: "updated_at",
                    propertyID: record.id,
                    orgID: record.orgID,
                    value: record.updatedAt
                )
                throw RemotePropertyFetchError.invalidUpdatedAt(record.id)
            }
            if let createdAt = record.createdAt,
               !remotePropertyDateIsValid(createdAt) {
                logRemotePropertyTimestampIssue(
                    kind: "created_at",
                    propertyID: record.id,
                    orgID: record.orgID,
                    value: createdAt
                )
                throw RemotePropertyFetchError.invalidCreatedAt(record.id)
            }
            _ = try resolvedRemotePropertyCreatedAt(for: record)
        }
        return sortedRecords
    }

    private func remotePropertyDateIsValid(_ value: Date) -> Bool {
        let interval = value.timeIntervalSince1970
        guard interval.isFinite else { return false }
        guard interval > 0 else { return false }
        let minimum = Date(timeIntervalSince1970: 946684800) // 2000-01-01T00:00:00Z
        let maximum = Date(timeIntervalSince1970: 4_102_444_800) // 2100-01-01T00:00:00Z
        return value >= minimum && value <= maximum
    }

    private func resolvedRemotePropertyCreatedAt(for record: RemotePropertyRecord) throws -> Date {
        if let createdAt = record.createdAt {
            return createdAt
        }
        if let localCreatedAt = allProperties.first(where: { $0.id == record.id })?.createdAt
            ?? properties.first(where: { $0.id == record.id })?.createdAt {
            print(
                "[RemotePropertyFetch] " +
                "outcome=used_local_createdAt_fallback " +
                "propertyID=\(record.id.uuidString) " +
                "orgID=\(record.orgID.uuidString)"
            )
            return localCreatedAt
        }
        throw RemotePropertyFetchError.missingLocalCreatedAtFallback(record.id)
    }

    private func normalizedRemotePropertyText(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func logRemotePropertyTimestampIssue(
        kind: String,
        propertyID: UUID,
        orgID: UUID,
        value: Date
    ) {
        let formatter = ISO8601DateFormatter()
        print(
            "[RemotePropertyFetch] " +
            "outcome=invalid_timestamp " +
            "field=\(kind) " +
            "propertyID=\(propertyID.uuidString) " +
            "orgID=\(orgID.uuidString) " +
            "value=\(formatter.string(from: value))"
        )
    }

    private func remotePropertyFingerprint(
        for records: [RemotePropertyRecord],
        activeOrganizationID: UUID
    ) throws -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let normalizedRecords = records.sorted { lhs, rhs in
            lhs.id.uuidString.lowercased() < rhs.id.uuidString.lowercased()
        }
        let joined = try normalizedRecords.map { record in
            [
                activeOrganizationID.uuidString.lowercased(),
                record.id.uuidString.lowercased(),
                record.orgID.uuidString.lowercased(),
                normalizedRemotePropertyText(record.folderID) ?? "",
                normalizedRemotePropertyText(record.clientName) ?? "",
                normalizedRemotePropertyText(record.clientEmail) ?? "",
                normalizedRemotePropertyText(record.clientPhone) ?? "",
                record.name.trimmingCharacters(in: .whitespacesAndNewlines),
                record.addressLine1.trimmingCharacters(in: .whitespacesAndNewlines),
                record.city.trimmingCharacters(in: .whitespacesAndNewlines),
                record.state.trimmingCharacters(in: .whitespacesAndNewlines),
                record.postalCode.trimmingCharacters(in: .whitespacesAndNewlines),
                record.baselineSessionID?.uuidString.lowercased() ?? "",
                record.isArchived ? "true" : "false",
                formatter.string(from: try resolvedRemotePropertyCreatedAt(for: record)),
                formatter.string(from: record.updatedAt)
            ].joined(separator: "|")
        }.joined(separator: "\n")
        let digest = SHA256.hash(data: Data(joined.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func logRemotePropertyFetchResult(
        outcome: String,
        recordCount: Int?,
        error: Error?,
        fingerprint: String? = nil
    ) {
        let countText = recordCount.map(String.init) ?? "nil"
        let errorText = error?.localizedDescription ?? "nil"
        let fingerprintText = fingerprint ?? "nil"
        print(
            "[RemotePropertyFetch] " +
            "outcome=\(outcome) " +
            "recordCount=\(countText) " +
            "fingerprint=\(fingerprintText) " +
            "error=\(errorText)"
        )
    }

    private func testFetchRemoteProperties() async {
        guard backendFeatureFlags.supabaseEnabled,
              backendFeatureFlags.supabaseReadEnabled else {
            logRemotePropertyFetchResult(
                outcome: "skipped_gate_disabled",
                recordCount: nil,
                error: nil
            )
            return
        }

        guard supabaseClient != nil else {
            logRemotePropertyFetchResult(
                outcome: "skipped_missing_client",
                recordCount: nil,
                error: RemotePropertyFetchError.missingClient
            )
            return
        }

        guard let activeOrganizationID else {
            logRemotePropertyFetchResult(
                outcome: "skipped_missing_active_org",
                recordCount: nil,
                error: RemotePropertyFetchError.missingActiveOrganization
            )
            return
        }

        do {
            let records = try await fetchRemotePropertyList(activeOrganizationID: activeOrganizationID)
            let validated = try validateRemotePropertyResponse(
                records: records,
                localCacheCount: properties.count,
                activeOrganizationID: activeOrganizationID
            )
            let payload = try makeRemotePropertyRefreshPayload(
                validatedRecords: validated,
                requestedOrganizationID: activeOrganizationID
            )
            logRemotePropertyFetchResult(
                outcome: "success",
                recordCount: payload.properties.count,
                error: nil,
                fingerprint: payload.fingerprint
            )
        } catch {
            let outcome: String
            if let remoteError = error as? RemotePropertyFetchError,
               case .timedOut = remoteError {
                outcome = "timeout"
            } else {
                outcome = "rejected"
            }
            logRemotePropertyFetchResult(
                outcome: outcome,
                recordCount: nil,
                error: error
            )
        }
    }

    func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        refreshProperties()
    }

    func warmLaunchReadiness(completion: @escaping () -> Void) {
        guard !didLoad else {
            completion()
            return
        }
        didLoad = true
        isStartupHydrationInProgress = true
        setLoadingState(allProperties.isEmpty)

        if allProperties.isEmpty,
           let localState = try? localStore.fetchPropertyAndOrganizationStateFromLocalHubIndexCache(),
           !localState.properties.isEmpty {
            let caches = makeHubCaches(for: localState.properties)
            applyHubCachePayload(
                properties: localState.properties,
                organizations: localState.organizations,
                caches: caches
            )
            setLoadingState(false)
            logHubFetch(
                phase: "warmLaunch",
                source: localState.source.rawValue,
                properties: localState.properties.count,
                orgs: localState.organizations.count,
                elapsedMs: 0
            )
        }

        DispatchQueue.global(qos: .utility).async {
            let start = Date()
            let fetchedState = try? self.localStore.fetchPropertyAndOrganizationStateFromHubIndex(downloadTimeout: self.startupHubIndexTimeout)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let fetchedState, !fetchedState.properties.isEmpty {
                    let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
                    self.logHubFetch(
                        phase: "warmLaunch",
                        source: fetchedState.source.rawValue,
                        properties: fetchedState.properties.count,
                        orgs: fetchedState.organizations.count,
                        elapsedMs: elapsedMs
                    )
                    let caches = self.makeHubCaches(for: fetchedState.properties)
                    self.applyHubCachePayload(
                        properties: fetchedState.properties,
                        organizations: fetchedState.organizations,
                        caches: caches
                    )
                } else {
                    let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
                    self.logHubFetch(
                        phase: "warmLaunch",
                        source: "none",
                        properties: 0,
                        orgs: 0,
                        elapsedMs: elapsedMs
                    )
                }
                self.setLoadingState(false)
                self.isStartupHydrationInProgress = false
                self.startupHydrationCompletedAt = Date()
                completion()
            }
        }
    }

    func refreshProperties() {
        cloudBackupManager?.refreshStatus()
        setLoadingState(true)
        guard isRemotePropertyRefreshEnabled else {
            performLocalPropertyRefreshFallback()
            setLoadingState(false)
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.setLoadingState(false) }
            await self.performForegroundRemotePropertyRefresh()
        }
    }

    @MainActor
    func refreshPropertiesAwaitingForegroundRefresh() async {
        cloudBackupManager?.refreshStatus()
        setLoadingState(true)
        defer { setLoadingState(false) }

        guard isRemotePropertyRefreshEnabled else {
            performLocalPropertyRefreshFallback()
            return
        }

        await performForegroundRemotePropertyRefresh()
    }

    func refreshPropertiesInBackground() {
        cloudBackupManager?.refreshStatus()
        if isStartupHydrationInProgress {
            return
        }
        if currentSession?.status == .draft {
            return
        }
        let now = Date()
        if isBackgroundRefreshInFlight { return }
        if !allProperties.isEmpty,
           let lastBackgroundRefreshStartedAt,
           now.timeIntervalSince(lastBackgroundRefreshStartedAt) < minimumBackgroundRefreshInterval {
            return
        }
        isBackgroundRefreshInFlight = true
        lastBackgroundRefreshStartedAt = now
        setLoadingState(allProperties.isEmpty)
        DispatchQueue.global(qos: .userInitiated).async {
            let fastPayload = try? self.makeRefreshPayloadForHubIndexOnly()
            let fastHasProperties = (fastPayload?.properties.isEmpty == false)
            let withinStartupFallbackGraceWindow: Bool = {
                guard self.allProperties.isEmpty,
                      let completedAt = self.startupHydrationCompletedAt else {
                    return false
                }
                return Date().timeIntervalSince(completedAt) < self.startupFallbackGraceWindow
            }()
            // When the hub is empty, start full fallback immediately to avoid long "syncing" dead time.
            let shouldRunFallback: Bool = {
                if fastHasProperties { return false }
                if self.allProperties.isEmpty { return true }
                return !withinStartupFallbackGraceWindow
            }()

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let fastPayload, fastHasProperties || self.allProperties.isEmpty {
                    self.applyRefreshPayload(fastPayload)
                    self.scheduleOffloadEligibleSessionMedia(excludingSessionID: self.currentSession?.id)
                }
                if fastHasProperties || !self.allProperties.isEmpty {
                    self.setLoadingState(false)
                }
                if !fastHasProperties, withinStartupFallbackGraceWindow {
                    self.setLoadingState(false)
                    self.isBackgroundRefreshInFlight = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                        guard let self else { return }
                        self.refreshPropertiesInBackground()
                    }
                    return
                }
                if !shouldRunFallback {
                    if self.isRemotePropertyRefreshEnabled {
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            await self.performBackgroundRemotePropertyRefresh()
                        }
                    } else {
                        self.isBackgroundRefreshInFlight = false
                    }
                }
            }

            guard shouldRunFallback else { return }

            do {
                let payload = try self.makeRefreshPayload()
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.applyRefreshPayload(payload)
                    self.scheduleOffloadEligibleSessionMedia(excludingSessionID: self.currentSession?.id)
                    self.setLoadingState(false)
                    if self.isRemotePropertyRefreshEnabled {
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            await self.performBackgroundRemotePropertyRefresh()
                        }
                    } else {
                        self.isBackgroundRefreshInFlight = false
                    }
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    // Preserve current in-memory view on transient iCloud read failures.
                    print("[PropertiesRefresh] transient read failure: \(error.localizedDescription)")
                    self.setLoadingState(false)
                    self.isBackgroundRefreshInFlight = false
                }
            }
        }
    }

    func refreshPropertySessionState(propertyID: UUID) {
        guard canAccessProperty(propertyID) else { return }
        reloadSessionCache(for: propertyID)
    }

    func canonicalLockSession(for propertyID: UUID) -> Session? {
        sessions(for: propertyID)
            .sorted { $0.startedAt > $1.startedAt }
            .first
    }

    func isPropertyOccupiedByOther(propertyID: UUID) -> Bool {
        guard let occupancy = propertySessionOccupancyByPropertyID[propertyID] else { return false }
        let currentUserID = authenticatedSupabaseUser?.id
        let currentDeviceID = currentDeviceIdentifier()
        let isOwnedByCurrentActor =
            occupancy.occupiedByUserID == currentUserID &&
            normalizedSupabaseText(occupancy.occupiedByDeviceID) == currentDeviceID
        let hasOccupancy =
            occupancy.occupiedByUserID != nil ||
            normalizedSupabaseText(occupancy.occupiedByDeviceID) != nil
        return hasOccupancy && !isOwnedByCurrentActor
    }

    func clearLocalLocks() {
        locallyLockedPropertyIDs.removeAll()
    }

    func reconcileLocalLocksAfterRefresh() async {
        var stillLocked: Set<UUID> = []

        for propertyID in locallyLockedPropertyIDs {
            guard let session = canonicalLockSession(for: propertyID) else { continue }
            guard let property = properties.first(where: { $0.id == propertyID }),
                  let orgID = property.orgId else { continue }

            let remoteRecord = try? await fetchRemoteSessionCoordinationRecord(
                orgID: orgID,
                propertyID: propertyID,
                sessionID: session.id
            )
            let remoteLockedAt = remoteRecord?.lockedAt.flatMap(parseSupabaseDateString)
            let remoteHasLockFields =
                remoteRecord?.lockedByUserID != nil ||
                normalizedSupabaseText(remoteRecord?.lockedByDeviceID) != nil

            if remoteRecord != nil, remoteHasLockFields {
                setSessionCoordinationState(
                    sessionID: session.id,
                    lockedByUserID: remoteRecord?.lockedByUserID,
                    lockedByDeviceID: normalizedSupabaseText(remoteRecord?.lockedByDeviceID),
                    lockedAt: remoteLockedAt
                )
            } else {
                setSessionCoordinationState(
                    sessionID: session.id,
                    lockedByUserID: nil,
                    lockedByDeviceID: nil,
                    lockedAt: nil
                )
            }

            let currentUserID = authenticatedSupabaseUser?.id
            let currentDeviceID = currentDeviceIdentifier()

            let isStillLocked: Bool = {
                guard let remote = remoteRecord else { return false }

                let hasLock =
                    remote.lockedByUserID != nil ||
                    normalizedSupabaseText(remote.lockedByDeviceID) != nil

                let isOwnedByCurrentActor =
                    remote.lockedByUserID == currentUserID &&
                    normalizedSupabaseText(remote.lockedByDeviceID) == currentDeviceID

                return hasLock && !isOwnedByCurrentActor
            }()

            if isStillLocked {
                stillLocked.insert(propertyID)
            }
        }

        await MainActor.run {
            self.locallyLockedPropertyIDs = stillLocked
        }
    }

    func isSessionLockedByOther(sessionID: UUID) -> Bool {
        guard let coord = sessionCoordinationStateBySessionID[sessionID] else { return false }
        guard let lockedByUser = coord.lockedByUserID else { return false }
        return lockedByUser != authenticatedSupabaseUser?.id
    }

    func setLiveSyncMonitoringActive(_ active: Bool) {
        if active {
            guard liveSyncTimer == nil else { return }
            liveSyncTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                guard let self else { return }
                if self.isLoading { return }
                let now = Date()
                let isBurst = (self.liveSyncBurstUntil.map { $0 > now }) ?? false
                if !isBurst,
                   let lastRefresh = self.lastLiveSyncRefreshAt,
                   now.timeIntervalSince(lastRefresh) < 6.0 {
                    return
                }
                let fingerprint = self.localStore.propertiesLedgerFingerprint()
                if fingerprint != self.lastLiveSyncFingerprint {
                    self.lastLiveSyncRefreshAt = now
                    self.refreshPropertiesInBackground()
                }
            }
            liveSyncTimer?.tolerance = 1.0
        } else {
            liveSyncTimer?.invalidate()
            liveSyncTimer = nil
            liveSyncBurstUntil = nil
            lastLiveSyncRefreshAt = nil
        }
    }

    private struct PropertyRefreshPayload {
        let properties: [Property]
        let organizations: [Organization]
        let caches: HubCachePayload
        let fingerprint: String
    }

    private var isRemotePropertyRefreshEnabled: Bool {
        backendFeatureFlags.supabaseEnabled &&
        backendFeatureFlags.supabasePropertyReadEnabled &&
        supabaseClient != nil &&
        activeOrganizationID != nil &&
        isOrganizationContextReady
    }

    private var isSyncDeltaEnabled: Bool {
        backendFeatureFlags.supabaseEnabled &&
        backendFeatureFlags.syncDeltaEnabled &&
        supabaseClient != nil &&
        activeOrganizationID != nil
    }

    private func setLoadingState(_ loading: Bool) {
        guard isLoading != loading else { return }
        isLoading = loading
    }

    @MainActor
    private func performForegroundRemotePropertyRefresh() async {
        guard let requestedOrganizationID = activeOrganizationID else {
            performLocalPropertyRefreshFallback()
            return
        }

        logRemotePropertyFetchResult(
            outcome: "foreground_fetch_started",
            recordCount: properties.count,
            error: nil
        )

        do {
            let records = try await fetchRemotePropertyList(activeOrganizationID: requestedOrganizationID)
            let validated = try validateRemotePropertyResponse(
                records: records,
                localCacheCount: properties.count,
                activeOrganizationID: requestedOrganizationID
            )
            guard activeOrganizationID == requestedOrganizationID else {
                throw RemotePropertyFetchError.missingActiveOrganization
            }
            let payload = try makeRemotePropertyRefreshPayload(
                validatedRecords: validated,
                requestedOrganizationID: requestedOrganizationID
            )
            try localStore.replacePropertyListCacheAtomically(
                properties: payload.properties,
                organizations: payload.organizations
            )
            applyRefreshPayload(payload)
            await hydratePreTapLockVisibility(
                orgID: requestedOrganizationID,
                propertyIDs: payload.properties.map(\.id)
            )
            await reconcileLocalLocksAfterRefresh()
            lastLiveSyncFingerprint = localStore.propertiesLedgerFingerprint()
            logRemotePropertyFetchResult(
                outcome: "foreground_success",
                recordCount: payload.properties.count,
                error: nil,
                fingerprint: payload.fingerprint
            )
        } catch {
            logRemotePropertyFetchResult(
                outcome: "foreground_fallback_local",
                recordCount: nil,
                error: error
            )
            performLocalPropertyRefreshFallback()
        }
    }

    @MainActor
    private func performBackgroundRemotePropertyRefresh() async {
        defer { isBackgroundRefreshInFlight = false }

        guard let requestedOrganizationID = activeOrganizationID else {
            logRemotePropertyFetchResult(
                outcome: "background_rejected",
                recordCount: nil,
                error: RemotePropertyFetchError.missingActiveOrganization
            )
            return
        }

        if let lastCompletedAt = lastBackgroundRemoteAttemptCompletedAt,
           Date().timeIntervalSince(lastCompletedAt) < 60 {
            return
        }

        logRemotePropertyFetchResult(
            outcome: "background_fetch_started",
            recordCount: properties.count,
            error: nil
        )

        do {
            let records = try await fetchRemotePropertyList(activeOrganizationID: requestedOrganizationID)
            let validated = try validateRemotePropertyResponse(
                records: records,
                localCacheCount: properties.count,
                activeOrganizationID: requestedOrganizationID
            )
            guard activeOrganizationID == requestedOrganizationID else {
                throw RemotePropertyFetchError.missingActiveOrganization
            }
            let payload = try makeRemotePropertyRefreshPayload(
                validatedRecords: validated,
                requestedOrganizationID: requestedOrganizationID
            )
            let mergedPayload = mergedBackingRefreshPayload(
                replacingOrganizationID: requestedOrganizationID,
                with: payload
            )
            if lastBackgroundRemoteFingerprint == mergedPayload.fingerprint {
                lastBackgroundRemoteAttemptCompletedAt = Date()
                return
            }
            guard wouldApplyRefreshPayloadChangeBackingState(mergedPayload) else {
                lastBackgroundRemoteFingerprint = mergedPayload.fingerprint
                lastBackgroundRemoteAttemptCompletedAt = Date()
                return
            }
            try localStore.replacePropertyListCacheAtomically(
                properties: mergedPayload.properties,
                organizations: mergedPayload.organizations
            )
            applyRefreshPayload(mergedPayload)
            await hydratePreTapLockVisibility(
                orgID: requestedOrganizationID,
                propertyIDs: mergedPayload.properties.map(\.id)
            )
            lastBackgroundRemoteFingerprint = mergedPayload.fingerprint
            lastBackgroundRemoteAttemptCompletedAt = Date()
            lastLiveSyncFingerprint = localStore.propertiesLedgerFingerprint()
            scheduleOffloadEligibleSessionMedia(excludingSessionID: currentSession?.id)
            logRemotePropertyFetchResult(
                outcome: "background_success",
                recordCount: mergedPayload.properties.count,
                error: nil,
                fingerprint: mergedPayload.fingerprint
            )
        } catch {
            logRemotePropertyFetchResult(
                outcome: "background_rejected",
                recordCount: nil,
                error: error
            )
        }
    }

    private func performLocalPropertyRefreshFallback() {
        do {
            let payload = try makeRefreshPayload()
            applyRefreshPayload(payload)
        } catch {
            // Preserve current in-memory view on transient iCloud read failures.
            print("[PropertiesRefresh] transient read failure: \(error.localizedDescription)")
        }
    }


    private func makeRefreshPayload() throws -> PropertyRefreshPayload {
        let start = Date()
        let fetchedProperties = try localStore.fetchProperties()
        let fetchedOrganizations = (try? localStore.fetchOrganizations()) ?? []
        let caches = makeHubCaches(for: fetchedProperties)
        let fingerprint = localStore.propertiesLedgerFingerprint()
        let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
        logHubFetch(
            phase: "background",
            source: "full-fallback",
            properties: fetchedProperties.count,
            orgs: fetchedOrganizations.count,
            elapsedMs: elapsedMs
        )
        return PropertyRefreshPayload(
            properties: fetchedProperties,
            organizations: fetchedOrganizations,
            caches: caches,
            fingerprint: fingerprint
        )
    }

    private func makeRefreshPayloadForHubIndexOnly() throws -> PropertyRefreshPayload {
        let start = Date()
        guard let state = try localStore.fetchPropertyAndOrganizationStateFromHubIndex(downloadTimeout: 2.0) else {
            let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
            logHubFetch(
                phase: "background",
                source: "none",
                properties: 0,
                orgs: 0,
                elapsedMs: elapsedMs
            )
            throw NSError(domain: "AppState.HubIndex", code: 1)
        }
        let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
        logHubFetch(
            phase: "background",
            source: state.source.rawValue,
            properties: state.properties.count,
            orgs: state.organizations.count,
            elapsedMs: elapsedMs
        )
        let caches = makeHubCaches(for: state.properties)
        let fingerprint = localStore.propertiesLedgerFingerprint()
        return PropertyRefreshPayload(
            properties: state.properties,
            organizations: state.organizations,
            caches: caches,
            fingerprint: fingerprint
        )
    }

    private func applyRefreshPayload(_ payload: PropertyRefreshPayload) {
        applyHubCachePayload(
            properties: payload.properties,
            organizations: payload.organizations,
            caches: payload.caches
        )
        lastLiveSyncFingerprint = payload.fingerprint
    }

    private func wouldApplyRefreshPayloadChangeBackingState(_ payload: PropertyRefreshPayload) -> Bool {
        if !propertiesMatchForNoOpDecision(allProperties, payload.properties) {
            return true
        }
        if allOrganizations != payload.organizations {
            return true
        }
        if allSessionIndexByProperty != payload.caches.sessionIndex {
            return true
        }
        if allDraftSessionByProperty != payload.caches.drafts {
            return true
        }
        if allPendingExportSessionByProperty != payload.caches.pending {
            return true
        }
        if allHubMetaByProperty != payload.caches.meta {
            return true
        }
        return false
    }

    private func propertiesMatchForNoOpDecision(_ lhs: [Property], _ rhs: [Property]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (left, right) in zip(lhs, rhs) {
            guard propertyMatchesForNoOpDecision(left, right) else {
                return false
            }
        }
        return true
    }

    private func propertyMatchesForNoOpDecision(_ lhs: Property, _ rhs: Property) -> Bool {
        lhs.id == rhs.id &&
        lhs.orgId == rhs.orgId &&
        lhs.name == rhs.name &&
        lhs.address == rhs.address &&
        lhs.street == rhs.street &&
        lhs.city == rhs.city &&
        lhs.state == rhs.state &&
        lhs.zip == rhs.zip &&
        lhs.clientName == rhs.clientName &&
        lhs.clientEmail == rhs.clientEmail &&
        lhs.clientPhone == rhs.clientPhone &&
        lhs.baselineSessionID == rhs.baselineSessionID &&
        lhs.isArchived == rhs.isArchived
    }

    private static func propertyIsOrderedBefore(_ lhs: Property, _ rhs: Property) -> Bool {
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt
        }
        let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        if nameOrder != .orderedSame {
            return nameOrder == .orderedAscending
        }
        return lhs.id.uuidString.lowercased() < rhs.id.uuidString.lowercased()
    }

    private func mergedBackingRefreshPayload(
        replacingOrganizationID organizationID: UUID,
        with payload: PropertyRefreshPayload
    ) -> PropertyRefreshPayload {
        let mergedProperties = mergedBackingProperties(
            replacingOrganizationID: organizationID,
            with: payload.properties
        )
        let mergedOrganizations = mergedBackingOrganizations(
            replacingOrganizationID: organizationID,
            with: payload.organizations
        )
        let mergedCaches = mergedBackingCaches(
            replacingOrganizationID: organizationID,
            mergedProperties: mergedProperties,
            remoteCaches: payload.caches
        )
        return PropertyRefreshPayload(
            properties: mergedProperties,
            organizations: mergedOrganizations,
            caches: mergedCaches,
            fingerprint: payload.fingerprint
        )
    }

    private func mergedBackingProperties(
        replacingOrganizationID organizationID: UUID,
        with remoteProperties: [Property]
    ) -> [Property] {
        let preserved = allProperties.filter { $0.orgId != organizationID }
        return (preserved + remoteProperties).sorted(by: Self.propertyIsOrderedBefore)
    }

    private func mergedBackingOrganizations(
        replacingOrganizationID organizationID: UUID,
        with remoteOrganizations: [Organization]
    ) -> [Organization] {
        var merged = allOrganizations
        guard let replacement = remoteOrganizations.first(where: { $0.id == organizationID }) else {
            return merged
        }
        if let index = merged.firstIndex(where: { $0.id == organizationID }) {
            merged[index] = replacement
        } else {
            merged.append(replacement)
        }
        return merged
    }

    private func mergedBackingCaches(
        replacingOrganizationID organizationID: UUID,
        mergedProperties: [Property],
        remoteCaches: HubCachePayload
    ) -> HubCachePayload {
        let currentActivePropertyIDs = Set(
            allProperties
                .filter { $0.orgId == organizationID }
                .map(\.id)
        )
        let remoteActivePropertyIDs = Set(
            mergedProperties
                .filter { $0.orgId == organizationID }
                .map(\.id)
        )
        let replacedPropertyIDs = currentActivePropertyIDs.union(remoteActivePropertyIDs)

        let sessionIndex = allSessionIndexByProperty
            .filter { !replacedPropertyIDs.contains($0.key) }
            .merging(remoteCaches.sessionIndex) { _, new in new }
        let drafts = allDraftSessionByProperty
            .filter { !replacedPropertyIDs.contains($0.key) }
            .merging(remoteCaches.drafts) { _, new in new }
        let pending = allPendingExportSessionByProperty
            .filter { !replacedPropertyIDs.contains($0.key) }
            .merging(remoteCaches.pending) { _, new in new }
        let meta = allHubMetaByProperty
            .filter { !replacedPropertyIDs.contains($0.key) }
            .merging(remoteCaches.meta) { _, new in new }

        return HubCachePayload(
            sessionIndex: sessionIndex,
            drafts: drafts,
            pending: pending,
            meta: meta
        )
    }

    private func markLiveSyncBurstWindow(seconds: TimeInterval) {
        liveSyncBurstUntil = Date().addingTimeInterval(max(seconds, 1))
    }

    @discardableResult
    func createProperty(
        organizationID: UUID,
        clientName: String,
        propertyName: String,
        address: String,
        street: String = "",
        city: String = "",
        state: String = "",
        zip: String = "",
        clientPhone: String = "",
        clientEmail: String = ""
    ) throws -> Property {
        let cleanedClientName = clientName.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedName = propertyName.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedStreet = street.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedCity = city.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedState = state.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedZip = zip.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedPhone = clientPhone.filter(\.isNumber)
        let cleanedEmail = clientEmail.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleanedName.isEmpty else { throw PropertyCreationError.missingPropertyName }
        guard canAccessOrganization(organizationID) else { throw PropertyCreationError.missingOrganization }

        do {
            try ensureLocalOrganizationExists(for: organizationID)
            let property = Property(
                id: UUID(),
                orgId: organizationID,
                clientName: cleanedClientName.isEmpty ? nil : cleanedClientName,
                clientPhone: cleanedPhone.isEmpty ? nil : cleanedPhone,
                clientEmail: cleanedEmail.isEmpty ? nil : cleanedEmail,
                name: cleanedName,
                address: cleanedAddress.isEmpty ? nil : cleanedAddress,
                street: cleanedStreet.isEmpty ? nil : cleanedStreet,
                city: cleanedCity.isEmpty ? nil : cleanedCity,
                state: cleanedState.isEmpty ? nil : cleanedState,
                zip: cleanedZip.isEmpty ? nil : cleanedZip
            )
            let created = try localStore.createProperty(property)
            allProperties.append(created)
            allOrganizations = (try? localStore.fetchOrganizations()) ?? allOrganizations
            allSessionIndexByProperty[created.id] = []
            allDraftSessionByProperty[created.id] = nil
            allPendingExportSessionByProperty[created.id] = nil
            allHubMetaByProperty[created.id] = makeHubMeta(for: created, organizations: allOrganizations)
            applyTenantScopedState()
            if selectedPropertyID == nil {
                selectedPropertyID = created.id
            }
            schedulePhaseBPropertyShadowWrite(for: created)
            return created
        } catch {
            if let propertyCreationError = error as? PropertyCreationError {
                throw propertyCreationError
            }
            if case LocalStore.StoreError.noAvailableFolderID = error {
                throw PropertyCreationError.noAvailableFolderID
            }
            throw PropertyCreationError.persistenceFailed
        }
    }

    @discardableResult
    func createOrganization(name: String) -> Organization? {
        guard !requiresAuthentication else { return nil }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }
        do {
            let created = try localStore.createOrganization(Organization(name: trimmedName))
            allOrganizations = (try? localStore.fetchOrganizations()) ?? allOrganizations
            applyTenantScopedState()
            return created
        } catch {
            return allOrganizations.first(where: { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(trimmedName) == .orderedSame })
        }
    }

    func organizationContacts(for organizationID: UUID?) -> [OrganizationContact] {
        guard canAccessOrganization(organizationID), let organizationID else { return [] }
        return organizations.first(where: { $0.id == organizationID })?.contacts ?? []
    }

    @discardableResult
    func updateOrganizationContact(organizationID: UUID, contact: OrganizationContact) -> Bool {
        guard canAccessOrganization(organizationID) else { return false }
        do {
            _ = try localStore.updateOrganizationContact(organizationID: organizationID, contact: contact)
            allOrganizations = (try? localStore.fetchOrganizations()) ?? allOrganizations
            applyTenantScopedState()
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    func deleteOrganizationContact(organizationID: UUID, contactID: UUID) -> Bool {
        guard canAccessOrganization(organizationID) else { return false }
        do {
            _ = try localStore.deleteOrganizationContact(organizationID: organizationID, contactID: contactID)
            allOrganizations = (try? localStore.fetchOrganizations()) ?? allOrganizations
            applyTenantScopedState()
            return true
        } catch {
            return false
        }
    }

    func selectProperty(id: UUID) {
        selectedPropertyID = id
        markPropertyActivated(id: id)
    }

    func propertyHasBaseline(_ propertyID: UUID) -> Bool {
        guard canAccessProperty(propertyID) else { return false }
        return properties.first(where: { $0.id == propertyID })?.baselineSessionID != nil
    }

    @discardableResult
    func setPropertyBaselineSession(propertyID: UUID, sessionID: UUID) -> Bool {
        guard canAccessProperty(propertyID) else { return false }
        guard let index = properties.firstIndex(where: { $0.id == propertyID }) else { return false }
        var updated = properties[index]
        updated.baselineSessionID = sessionID
        do {
            let persisted = try localStore.updateProperty(updated)
            if let rawIndex = allProperties.firstIndex(where: { $0.id == propertyID }) {
                allProperties[rawIndex] = persisted
            }
            let caches = makeHubCaches(for: allProperties)
            applyHubCachePayload(properties: allProperties, organizations: allOrganizations, caches: caches)
            schedulePhaseBPropertyShadowWrite(for: persisted)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    func setPropertyArchived(id: UUID, archived: Bool) -> Bool {
        guard canAccessProperty(id) else { return false }
        guard let property = properties.first(where: { $0.id == id }) else { return false }
        var updated = property
        updated.isArchived = archived
        do {
            let persisted = try localStore.updateProperty(updated)
            if let idx = allProperties.firstIndex(where: { $0.id == id }) {
                allProperties[idx] = persisted
            }
            if archived, selectedPropertyID == id {
                clearCurrentSession()
                selectedPropertyID = nil
            }
            let caches = makeHubCaches(for: allProperties)
            applyHubCachePayload(properties: allProperties, organizations: allOrganizations, caches: caches)
            schedulePhaseBPropertyShadowWrite(for: persisted)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    func updatePropertyContact(
        id: UUID,
        organizationID: UUID?,
        propertyName: String?,
        clientName: String?,
        address: String?,
        street: String?,
        city: String?,
        state: String?,
        zip: String?,
        clientPhone: String?,
        clientEmail: String?
    ) -> Bool {
        guard canAccessProperty(id) else { return false }
        guard let index = properties.firstIndex(where: { $0.id == id }) else { return false }
        var updated = properties[index]
        let cleanedName = propertyName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cleanedClient = clientName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cleanedAddress = address?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cleanedStreet = street?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cleanedCity = city?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cleanedState = state?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cleanedZip = zip?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let digitsOnlyPhone = (clientPhone ?? "").filter(\.isNumber)
        let cleanedEmail = clientEmail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if let organizationID, canAccessOrganization(organizationID) {
            updated.orgId = organizationID
        }
        if !cleanedName.isEmpty {
            updated.name = cleanedName
        }
        updated.clientName = cleanedClient.isEmpty ? nil : cleanedClient
        updated.address = cleanedAddress.isEmpty ? nil : cleanedAddress
        updated.street = cleanedStreet.isEmpty ? nil : cleanedStreet
        updated.city = cleanedCity.isEmpty ? nil : cleanedCity
        updated.state = cleanedState.isEmpty ? nil : cleanedState
        updated.zip = cleanedZip.isEmpty ? nil : cleanedZip
        updated.clientPhone = digitsOnlyPhone.isEmpty ? nil : digitsOnlyPhone
        updated.clientEmail = cleanedEmail.isEmpty ? nil : cleanedEmail

        do {
            let persisted = try localStore.updateProperty(updated)
            if let rawIndex = allProperties.firstIndex(where: { $0.id == id }) {
                allProperties[rawIndex] = persisted
            }
            allOrganizations = (try? localStore.fetchOrganizations()) ?? allOrganizations
            let caches = makeHubCaches(for: allProperties)
            applyHubCachePayload(properties: allProperties, organizations: allOrganizations, caches: caches)
            schedulePhaseBPropertyShadowWrite(for: persisted)
            return true
        } catch {
            return false
        }
    }

    func propertyDataCounts(for propertyID: UUID) -> PropertyDataCounts {
        guard canAccessProperty(propertyID) else {
            return PropertyDataCounts(sessions: 0, guided: 0, observations: 0)
        }
        let sessions = (try? localStore.fetchSessions(propertyID: propertyID).count) ?? 0
        let guided = (try? localStore.fetchGuidedShots(propertyID: propertyID).count) ?? 0
        let observations = (try? localStore.fetchObservations(propertyID: propertyID).count) ?? 0
        return PropertyDataCounts(sessions: sessions, guided: guided, observations: observations)
    }

    @discardableResult
    func deletePropertyIfEmpty(id: UUID) -> Bool {
        guard canAccessProperty(id) else { return false }
        let counts = propertyDataCounts(for: id)
        guard counts.isEmpty else { return false }
        do {
            try localStore.deleteProperty(id: id)
            allProperties.removeAll { $0.id == id }
            let caches = makeHubCaches(for: allProperties)
            applyHubCachePayload(properties: allProperties, organizations: allOrganizations, caches: caches)
            if selectedPropertyID == id {
                selectedPropertyID = nil
                clearCurrentSession()
            }
            cloudBackupManager?.markDataChanged(scheduleBackupAfter: 0)
            return true
        } catch {
            if handleDeletePropertyNotFound(id: id, error: error) {
                return true
            }
            return false
        }
    }

    @discardableResult
    func deleteProperty(id: UUID) -> Bool {
        guard canAccessProperty(id) else { return false }
        refreshProperties()
        do {
            try localStore.deleteProperty(id: id)
            allProperties.removeAll { $0.id == id }
            let caches = makeHubCaches(for: allProperties)
            applyHubCachePayload(properties: allProperties, organizations: allOrganizations, caches: caches)
            if selectedPropertyID == id {
                selectedPropertyID = nil
                clearCurrentSession()
            }
            cloudBackupManager?.markDataChanged(scheduleBackupAfter: 0)
            return true
        } catch {
            if handleDeletePropertyNotFound(id: id, error: error) {
                return true
            }
            return false
        }
    }

    private func handleDeletePropertyNotFound(id: UUID, error: Error) -> Bool {
        guard case LocalStore.StoreError.propertyNotFound = error else {
            return false
        }

        // Cross-device iCloud updates can remove a property on disk before this device's in-memory list refreshes.
        refreshProperties()
        allProperties.removeAll { $0.id == id }
        let caches = makeHubCaches(for: allProperties)
        applyHubCachePayload(properties: allProperties, organizations: allOrganizations, caches: caches)
        if selectedPropertyID == id {
            selectedPropertyID = nil
            clearCurrentSession()
        }
        return true
    }

    @discardableResult
    func startSession() -> Session? {
        guard let selectedPropertyID else { return nil }
        let sessionsForProperty = sessions(for: selectedPropertyID)
        let pendingDeliveryExists = sessionsForProperty.contains(where: { isPendingDelivery($0) })
        let reExportEligibleExists = sessionsForProperty.contains(where: { isReExportEligible($0) })
        if let currentSession, currentSession.status == .draft, currentSession.propertyID == selectedPropertyID {
            print("[StartSession] propertyID=\(selectedPropertyID.uuidString) blockedReason=none pendingDeliveryExists=\(pendingDeliveryExists) reExportEligibleExists=\(reExportEligibleExists)")
            logActiveSession(currentSession)
            cloudBackupManager?.setCaptureModeActive(true)
            return currentSession
        }

        if let draft = canonicalDraftSession(for: selectedPropertyID, requireCaptures: false) {
            currentSession = draft
            print("[StartSession] propertyID=\(selectedPropertyID.uuidString) blockedReason=none pendingDeliveryExists=\(pendingDeliveryExists) reExportEligibleExists=\(reExportEligibleExists)")
            cloudBackupManager?.setCaptureModeActive(true)
            return draft
        }

        let session = Session(propertyID: selectedPropertyID, startedAt: Date(), status: .draft, endedAt: nil, exportedAt: nil)
        currentSession = session
        print("[StartSession] propertyID=\(selectedPropertyID.uuidString) blockedReason=none pendingDeliveryExists=\(pendingDeliveryExists) reExportEligibleExists=\(reExportEligibleExists)")
        cloudBackupManager?.setCaptureModeActive(true)
        return session
    }

    @discardableResult
    func ensureCurrentSessionPersisted() -> Session? {
        guard let session = currentSession else { return nil }
        let alreadyPersisted = sessions(for: session.propertyID).contains { $0.id == session.id }
        guard !alreadyPersisted else { return session }

        let persisted = (try? localStore.upsertSession(session)) ?? session
        currentSession = persisted
        reloadSessionCache(for: session.propertyID)
        return persisted
    }

    @discardableResult
    func saveDraftCurrentSession(scheduleShadowWrite: Bool = true) -> Session? {
        guard var session = currentSession else { return nil }
        session.status = .draft
        session.endedAt = nil
        session.exportedAt = nil
        if session.firstDeliveredAt == nil {
            session.isSealed = false
        }
        currentSession = session
        let persisted = (try? localStore.upsertSession(session)) ?? session
        currentSession = persisted
        reloadSessionCache(for: session.propertyID)
        if scheduleShadowWrite {
            schedulePhaseBSessionShadowWrite(for: persisted)
        }
        return persisted
    }

    func scheduleSessionShadowWriteAfterCoordinationRelease(for session: Session) {
        schedulePhaseBSessionShadowWrite(for: session)
    }

    func completeCurrentSession(markExported: Bool) {
        guard var session = currentSession else { return }
        session.status = .completed
        if session.endedAt == nil {
            session.endedAt = Date()
        }
        session.isSealed = true
        if markExported {
            let now = Date()
            applyDeliverySuccess(to: &session, deliveredAt: now)
        } else {
            if session.exportedAt != nil {
                session.exportedAt = nil
            }
        }
        currentSession = session
        let persisted = (try? localStore.upsertSession(session)) ?? session
        currentSession = persisted
        reloadSessionCache(for: persisted.propertyID)
        schedulePhaseBSessionShadowWrite(for: persisted)
        scheduleOffloadEligibleSessionMedia(excludingSessionID: currentSession?.id)
        cloudBackupManager?.setCaptureModeActive(false)
        triggerBackupForLifecycleEvent()
    }
    
    func clearCurrentSession() {
        scheduleOffloadEligibleSessionMedia(excludingSessionID: currentSession?.id)
        if let sessionID = currentSession?.id {
            sessionCoordinationStateBySessionID.removeValue(forKey: sessionID)
            sessionCoordinationEntrySnapshotBySessionID.removeValue(forKey: sessionID)
        }
        currentSession = nil
        cloudBackupManager?.setCaptureModeActive(false)
    }
    
    func draftSession(for propertyID: UUID) -> Session? {
        guard canAccessProperty(propertyID) else { return nil }
        return canonicalDraftSession(for: propertyID, requireCaptures: true)
    }
    
    func sessions(for propertyID: UUID) -> [Session] {
        guard canAccessProperty(propertyID) else { return [] }
        if let cached = sessionIndexByProperty[propertyID] {
            return cached
        }
        let fetched = (try? localStore.fetchSessions(propertyID: propertyID)) ?? []
        var uniqueByID: [UUID: Session] = [:]
        for session in fetched {
            uniqueByID[session.id] = session
        }
        return uniqueByID.values.sorted { $0.startedAt < $1.startedAt }
    }

    func latestPendingExportSession(for propertyID: UUID) -> Session? {
        guard canAccessProperty(propertyID) else { return nil }
        if let cached = pendingExportSessionByProperty[propertyID] {
            return cached
        }
        return sessions(for: propertyID)
            .filter { isPendingDelivery($0) }
            .sorted { $0.startedAt > $1.startedAt }
            .first
    }
    
    func pendingExportCountAcrossProperties() -> Int {
        if !pendingExportSessionByProperty.isEmpty {
            return Set(pendingExportSessionByProperty.values.map(\.id)).count
        }
        var pendingSessionIDs = Set<UUID>()
        for property in properties {
            for session in sessions(for: property.id) where isPendingDelivery(session) {
                pendingSessionIDs.insert(session.id)
            }
        }
        return pendingSessionIDs.count
    }
    
    func draftPropertyCount() -> Int {
        if !draftSessionByProperty.isEmpty {
            return draftSessionByProperty.count
        }
        return properties.filter { draftSession(for: $0.id) != nil }.count
    }
    
    func markCurrentSessionExported() {
        guard var session = currentSession else { return }
        guard session.status == .completed else { return }
        if session.endedAt == nil {
            session.endedAt = Date()
        }
        let now = Date()
        if session.firstDeliveredAt != nil, !isReExportEligible(session, now: now) {
            print("[ExportEligibility] sessionID=\(session.id.uuidString) enabled=false reason=Re export window expired")
            return
        }
        applyDeliverySuccess(to: &session, deliveredAt: now)
        currentSession = session
        let persisted = (try? localStore.upsertSession(session)) ?? session
        currentSession = persisted
        reloadSessionCache(for: persisted.propertyID)
        schedulePhaseBSessionShadowWrite(for: persisted)
        scheduleSessionArchiveSnapshot(persisted, trigger: "markCurrentSessionExported")
        scheduleOffloadEligibleSessionMedia(excludingSessionID: currentSession?.id)
        cloudBackupManager?.setCaptureModeActive(false)
        triggerBackupForLifecycleEvent()
    }

    func sealCurrentSessionForExportLater() {
        guard var session = currentSession else { return }
        session.status = .completed
        if session.endedAt == nil {
            session.endedAt = Date()
        }
        session.exportedAt = nil
        session.isSealed = true
        print("[ExportSeal] action=export_later sessionID=\(session.id.uuidString) isSealed=true firstDeliveredAt=nil reExportExpiresAt=nil")
        currentSession = session
        let persisted = (try? localStore.upsertSession(session)) ?? session
        currentSession = persisted
        reloadSessionCache(for: persisted.propertyID)
        schedulePhaseBSessionShadowWrite(for: persisted)
        scheduleSessionArchiveSnapshot(persisted, trigger: "sealCurrentSessionForExportLater")
        scheduleOffloadEligibleSessionMedia(excludingSessionID: currentSession?.id)
        cloudBackupManager?.setCaptureModeActive(false)
        triggerBackupForLifecycleEvent()
    }

    func sealCurrentSessionForExportNow() {
        guard var session = currentSession else { return }
        session.status = .completed
        if session.endedAt == nil {
            session.endedAt = Date()
        }
        session.isSealed = true
        print("[ExportSeal] action=export_now sessionID=\(session.id.uuidString) isSealed=true")
        currentSession = session
        let persisted = (try? localStore.upsertSession(session)) ?? session
        currentSession = persisted
        reloadSessionCache(for: persisted.propertyID)
        schedulePhaseBSessionShadowWrite(for: persisted)
        scheduleSessionArchiveSnapshot(persisted, trigger: "sealCurrentSessionForExportNow")
        scheduleOffloadEligibleSessionMedia(excludingSessionID: currentSession?.id)
        cloudBackupManager?.setCaptureModeActive(false)
        triggerBackupForLifecycleEvent()
    }
    
    func loadDraftSession(for propertyID: UUID) -> Session? {
        guard canAccessProperty(propertyID) else { return nil }
        guard let draft = canonicalDraftSession(for: propertyID, requireCaptures: false) else { return nil }
        selectedPropertyID = propertyID
        currentSession = draft
        cloudBackupManager?.setCaptureModeActive(true)
        return draft
    }

    func ensureSessionMetadataInBackground(for session: Session) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            try? self.localStore.ensureSessionMetadata(for: session)
        }
    }

    func ensureCurrentSessionMetadataInBackground() {
        guard let session = currentSession else { return }
        ensureSessionMetadataInBackground(for: session)
    }

    @discardableResult
    func markSessionExported(propertyID: UUID, sessionID: UUID) -> Bool {
        guard canAccessProperty(propertyID) else { return false }
        let allSessions = sessions(for: propertyID)
        guard var session = allSessions.first(where: { $0.id == sessionID }) else { return false }
        guard session.status == .completed else { return false }
        if session.endedAt == nil {
            session.endedAt = Date()
        }
        let now = Date()
        if session.firstDeliveredAt != nil, !isReExportEligible(session, now: now) {
            print("[ExportEligibility] sessionID=\(session.id.uuidString) enabled=false reason=Re export window expired")
            return false
        }
        applyDeliverySuccess(to: &session, deliveredAt: now)
        if currentSession?.id == sessionID {
            currentSession = session
        }
        do {
            let persisted = try localStore.upsertSession(session)
            if currentSession?.id == sessionID {
                currentSession = persisted
            }
            reloadSessionCache(for: propertyID)
            schedulePhaseBSessionShadowWrite(for: persisted)
            scheduleSessionArchiveSnapshot(persisted, trigger: "markSessionExported")
            scheduleOffloadEligibleSessionMedia(excludingSessionID: currentSession?.id)
            cloudBackupManager?.setCaptureModeActive(false)
            triggerBackupForLifecycleEvent()
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    func deleteSession(
        propertyID: UUID,
        sessionID: UUID,
        triggerSafetyPause: Bool = true
    ) -> Bool {
        guard canAccessProperty(propertyID) else { return false }
        do {
            try localStore.deleteSessionCascade(id: sessionID, propertyID: propertyID)
            if currentSession?.id == sessionID {
                clearCurrentSession()
            }
            reloadSessionCache(for: propertyID)
            cloudBackupManager?.markDataChanged(scheduleBackupAfter: 0)
            return true
        } catch {
            if case LocalStore.StoreError.sessionNotFound = error {
                do {
                    try localStore.deleteSession(id: sessionID, propertyID: propertyID)
                } catch {
                    return false
                }
                if currentSession?.id == sessionID {
                    clearCurrentSession()
                }
                reloadSessionCache(for: propertyID)
                cloudBackupManager?.markDataChanged(scheduleBackupAfter: 0)
                return true
            }
            return false
        }
    }

    func resetLocalSessionUIIndex() {
        clearLocalCacheOnly()
    }

    func clearLocalCacheOnly() {
        NotificationCenter.default.post(name: .scoutClearLocalUICache, object: nil)
        refreshProperties()
    }

    func nuclearResetLocalOnly() {
        do {
            try localStore.wipeAllLocalData()
        } catch {
            // Keep UI stable even when cleanup fails.
        }
        clearAllUserDefaults()
        selectedPropertyID = nil
        clearCurrentSession()
        allProperties = []
        allOrganizations = []
        allSessionIndexByProperty = [:]
        allDraftSessionByProperty = [:]
        allPendingExportSessionByProperty = [:]
        allHubMetaByProperty = [:]
        applyTenantScopedState()
        refreshProperties()
        NotificationCenter.default.post(name: .scoutClearLocalUICache, object: nil)
    }

    func completeMigrationImport(restoredSelectedPropertyID: UUID?) {
        clearCurrentSession()
        selectedPropertyID = nil
        allProperties = []
        allSessionIndexByProperty = [:]
        allDraftSessionByProperty = [:]
        allPendingExportSessionByProperty = [:]
        allHubMetaByProperty = [:]
        applyTenantScopedState()
        refreshProperties()
        if let restoredSelectedPropertyID,
           properties.contains(where: { $0.id == restoredSelectedPropertyID }) {
            selectedPropertyID = restoredSelectedPropertyID
        }
        cloudBackupManager?.refreshStatus()
        NotificationCenter.default.post(name: .scoutClearLocalUICache, object: nil)
    }

    func backupNow() {
        cloudBackupManager?.backupNow()
    }

    func refreshBackupStatus() {
        cloudBackupManager?.refreshStatus()
    }

    func backupStatusSubtitle() -> String {
        if !cloudBackupStatus.iCloudAvailable {
            return "iCloud unavailable"
        }
        if let lastSuccessfulBackupAt = cloudBackupStatus.lastSuccessfulBackupAt {
            return "Last backup \(RelativeDateTimeFormatter().localizedString(for: lastSuccessfulBackupAt, relativeTo: Date()))"
        }
        return "No backup yet"
    }

    func restoreLatestBackup(completion: @escaping (String?) -> Void) {
        cloudBackupManager?.refreshStatus()
        guard let cloudBackupManager else {
            completion("No restorable backup is available yet.")
            return
        }
        let status = cloudBackupStatus
        guard status.iCloudAvailable else {
            completion("iCloud is unavailable.")
            return
        }
        guard status.hasBackup,
              !status.isRunning else {
            completion("No restorable backup is available yet.")
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let restoredSelectedPropertyID = try cloudBackupManager.restoreLatestBackup(mode: .mergeMissingPropertiesOnly)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.completeMigrationImport(restoredSelectedPropertyID: restoredSelectedPropertyID)
                    completion(nil)
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.cloudBackupManager?.refreshStatus()
                    completion(error.localizedDescription)
                }
            }
        }
    }

    func triggerBackupForLifecycleEvent() {
        cloudBackupManager?.setCaptureModeActive(false)
        cloudBackupManager?.scheduleAutomaticBackup(after: 0)
    }

    func handleSceneDidEnterBackground() {
        cloudBackupManager?.scheduleAutomaticBackup(after: 0)
    }

    func handleSceneDidBecomeActive() {
        queuePendingSupabaseMediaBackfillIfNeeded(reason: "scene_active")
        guard isOrganizationContextReady else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await performRemoteConvergenceCycle(source: "foreground")
        }
    }

    private func persistSelectedPropertyID() {
        if let selectedPropertyID {
            userDefaults.set(selectedPropertyID.uuidString, forKey: selectedPropertyDefaultsKey)
        } else {
            userDefaults.removeObject(forKey: selectedPropertyDefaultsKey)
        }
        NotificationCenter.default.post(name: .scoutPersistentDataDidChange, object: nil)
    }

    private func clearAllUserDefaults() {
        if let bundleID = Bundle.main.bundleIdentifier {
            userDefaults.removePersistentDomain(forName: bundleID)
            userDefaults.synchronize()
        } else {
            userDefaults.removeObject(forKey: selectedPropertyDefaultsKey)
            userDefaults.removeObject(forKey: propertyActivationTimestampsDefaultsKey)
            userDefaults.removeObject(forKey: activeOrganizationDefaultsKey(for: authenticatedSupabaseUser?.id))
        }
    }

    func hubMeta(for propertyID: UUID) -> HubPropertyMeta? {
        hubMetaByProperty[propertyID]
    }

    private struct HubCachePayload {
        let sessionIndex: [UUID: [Session]]
        let drafts: [UUID: Session]
        let pending: [UUID: Session]
        let meta: [UUID: HubPropertyMeta]
    }

    private func applyHubCachePayload(
        properties: [Property],
        organizations: [Organization],
        caches: HubCachePayload
    ) {
        let canonicalProperties = properties.sorted(by: Self.propertyIsOrderedBefore)
        let preservedOrganizations = mergeOrganizationContacts(into: organizations)
        if allProperties != canonicalProperties {
            allProperties = canonicalProperties
        }
        if allOrganizations != preservedOrganizations {
            allOrganizations = preservedOrganizations
        }
        if allSessionIndexByProperty != caches.sessionIndex {
            allSessionIndexByProperty = caches.sessionIndex
        }
        if allDraftSessionByProperty != caches.drafts {
            allDraftSessionByProperty = caches.drafts
        }
        if allPendingExportSessionByProperty != caches.pending {
            allPendingExportSessionByProperty = caches.pending
        }
        if allHubMetaByProperty != caches.meta {
            allHubMetaByProperty = caches.meta
        }
        applyTenantScopedState()
    }

    private func mergeOrganizationContacts(into organizations: [Organization]) -> [Organization] {
        let existingOrganizations = ((try? localStore.fetchOrganizations()) ?? allOrganizations)
        let existingContactsByOrganizationID = Dictionary(
            uniqueKeysWithValues: existingOrganizations.map { ($0.id, $0.contacts) }
        )

        return organizations.map { organization in
            guard organization.contacts.isEmpty,
                  let preservedContacts = existingContactsByOrganizationID[organization.id],
                  !preservedContacts.isEmpty else {
                return organization
            }

            return Organization(
                id: organization.id,
                name: organization.name,
                contacts: preservedContacts
            )
        }
    }

#if DEBUG
    func _debugDiscoverPendingSupabaseMediaBackfillCandidates() -> [PendingSupabaseMediaBackfillCandidate] {
        discoverPendingSupabaseMediaBackfillCandidates().candidates
    }

    func _debugSetInFlightSupabaseMediaOperationsForTests(_ keys: Set<String>) {
        let _: Void = supabaseMediaOperationQueue.sync {
            inFlightSupabaseMediaOperations = keys
        }
    }

    func _debugSetSupabaseMediaBackfillInProgressForTests(_ inProgress: Bool) {
        let _: Void = supabaseMediaOperationQueue.sync {
            isSupabaseMediaBackfillInProgress = inProgress
        }
    }

    func _debugSupabaseUploadOperationKeyForTests(sessionID: UUID, shotID: UUID) -> String {
        supabaseUploadOperationKey(sessionID: sessionID, shotID: shotID)
    }

    func _debugRunPendingSupabaseMediaBackfillForTests(reason: String = "test") async -> SupabaseMediaBackfillRunSummary {
        await runPendingSupabaseMediaBackfill(reason: reason)
    }

    func _debugSetOfflineReplayInFlightForTests(_ inFlight: Bool) {
        let _: Void = offlineReplayStateQueue.sync {
            isOfflineReplayInFlight = inFlight
        }
    }

    func _debugIsOfflineReplayInFlightForTests() -> Bool {
        offlineReplayStateQueue.sync { isOfflineReplayInFlight }
    }

    @MainActor
    func _debugSetOfflineReplayEnvironmentForTests(
        activeOrganizationID: UUID?,
        ready: Bool = true,
        clientConfigured: Bool = true,
        authenticated: Bool = true,
        authenticationReady: Bool = true,
        authenticatedUserID: UUID? = nil
    ) {
        self.activeOrganizationID = activeOrganizationID
        self.isOrganizationContextReady = ready
        self.supabaseClient = clientConfigured
            ? SupabaseClient(
                supabaseURL: URL(string: "https://example.supabase.co")!,
                supabaseKey: "debug-anon-key"
            )
            : nil
        self.isAuthenticationReady = authenticationReady
        self.authenticatedSupabaseUser = authenticated
            ? AuthenticatedSupabaseUser(id: authenticatedUserID ?? UUID(), email: "debug@example.com")
            : nil
    }

    @MainActor
    func _debugPerformOfflineReplayForTests(source: String = "test") async -> OfflineReplayRunSummary {
        await performOfflineReplay(source: source)
    }

    @MainActor
    func _debugReadSyncCursorForTests(entity: String, orgID: UUID) -> Date? {
        readSyncCursor(entity: entity, orgID: orgID)
    }

    @MainActor
    func _debugWriteSyncCursorForTests(entity: String, orgID: UUID, date: Date) {
        writeSyncCursor(entity: entity, orgID: orgID, date: date)
    }

    @MainActor
    func _debugAdvanceSyncCursorForTests(entity: String, orgID: UUID, updatedAts: [Date]) {
        advanceSyncCursor(entity: entity, orgID: orgID, updatedAts: updatedAts)
    }

    @MainActor
    func _debugClearSyncCursorsForTests(orgID: UUID) {
        clearSyncCursors(orgID: orgID)
    }

    @MainActor
    func _debugIsSyncDeltaEnabledForTests() -> Bool {
        isSyncDeltaEnabled
    }

    @MainActor
    func _debugSetSyncDeltaEnvironmentForTests(
        activeOrganizationID: UUID?,
        ready: Bool = true,
        clientConfigured: Bool = true
    ) {
        self.activeOrganizationID = activeOrganizationID
        self.isOrganizationContextReady = ready
        self.supabaseClient = clientConfigured
            ? SupabaseClient(
                supabaseURL: URL(string: "https://example.supabase.co")!,
                supabaseKey: "debug-anon-key"
            )
            : nil
    }

    func _debugSetSyncDeltaPullInFlightForTests(_ inFlight: Bool) {
        isSyncDeltaPullInFlight = inFlight
    }

    func _debugIsSyncDeltaPullInFlightForTests() -> Bool {
        isSyncDeltaPullInFlight
    }

    func _debugSetLastForegroundSyncDeltaCompletedAtForTests(_ date: Date?) {
        lastForegroundSyncDeltaCompletedAt = date
    }

    func _debugReadLastForegroundSyncDeltaCompletedAtForTests() -> Date? {
        lastForegroundSyncDeltaCompletedAt
    }

    func _debugSetSyncDeltaFetchResultForTests(
        propertyRecords: [DebugRemotePropertyDeltaInput] = [],
        sessionRecords: [DebugRemoteSessionDeltaInput] = []
    ) {
        syncDeltaFetchOverride = { orgID, _, _ in
            (
                propertyRecords.map {
                    RemotePropertyDeltaRecord(
                        id: $0.id,
                        orgID: $0.orgID == orgID ? $0.orgID : orgID,
                        folderID: $0.folderID,
                        clientName: $0.clientName,
                        clientEmail: $0.clientEmail,
                        clientPhone: $0.clientPhone,
                        name: $0.name,
                        addressLine1: $0.addressLine1,
                        city: $0.city,
                        state: $0.state,
                        postalCode: $0.postalCode,
                        baselineSessionID: $0.baselineSessionID,
                        isArchived: $0.isArchived,
                        createdAt: $0.createdAt,
                        updatedAt: $0.updatedAt,
                        deletedAt: $0.deletedAt
                    )
                },
                sessionRecords.map {
                    RemoteSessionDeltaRecord(
                        id: $0.id,
                        orgID: $0.orgID == orgID ? $0.orgID : orgID,
                        propertyID: $0.propertyID,
                        title: $0.title,
                        status: $0.status,
                        startedAt: $0.startedAt,
                        completedAt: $0.completedAt,
                        updatedAt: $0.updatedAt,
                        deletedAt: $0.deletedAt
                    )
                }
            )
        }
    }

    func _debugSetSessionCoordinationFetchResultForTests(
        _ record: DebugSessionCoordinationRemoteInput?
    ) {
        if let record {
            sessionCoordinationDebugRemoteRecords[record.sessionID] = RemoteSessionCoordinationRecord(
                id: record.sessionID,
                orgID: record.orgID,
                propertyID: record.propertyID,
                lockedByUserID: record.lockedByUserID,
                lockedByDeviceID: record.lockedByDeviceID,
                lockedAt: record.lockedAt,
                coordinationTier1Snapshot: record.coordinationTier1Snapshot,
                updatedAt: record.updatedAt
            )
        } else {
            sessionCoordinationDebugRemoteRecords.removeAll()
        }
        sessionCoordinationFetchOverride = { orgID, propertyID, sessionID in
            guard let record,
                  record.sessionID == sessionID,
                  record.propertyID == propertyID else {
                return nil
            }
            return RemoteSessionCoordinationRecord(
                id: sessionID,
                orgID: record.orgID == orgID ? record.orgID : orgID,
                propertyID: propertyID,
                lockedByUserID: record.lockedByUserID,
                lockedByDeviceID: record.lockedByDeviceID,
                lockedAt: record.lockedAt,
                coordinationTier1Snapshot: record.coordinationTier1Snapshot,
                updatedAt: record.updatedAt
            )
        }
    }

    func _debugSetSessionCoordinationStateForTests(
        sessionID: UUID,
        lockedByUserID: UUID?,
        lockedByDeviceID: String?,
        lockedAt: Date?
    ) {
        sessionCoordinationStateBySessionID[sessionID] = SessionCoordinationState(
            lockedByUserID: lockedByUserID,
            lockedByDeviceID: lockedByDeviceID,
            lockedAt: lockedAt
        )
        if var cached = sessionCoordinationDebugRemoteRecords[sessionID] {
            cached = RemoteSessionCoordinationRecord(
                id: cached.id,
                orgID: cached.orgID,
                propertyID: cached.propertyID,
                lockedByUserID: lockedByUserID,
                lockedByDeviceID: lockedByDeviceID,
                lockedAt: lockedAt?.ISO8601Format(),
                coordinationTier1Snapshot: cached.coordinationTier1Snapshot,
                updatedAt: Date()
            )
            sessionCoordinationDebugRemoteRecords[sessionID] = cached
        }
    }

    func _debugReadSessionCoordinationStateForTests(
        sessionID: UUID
    ) -> (lockedByUserID: UUID?, lockedByDeviceID: String?, lockedAt: Date?) {
#if DEBUG
        if let cached = sessionCoordinationDebugRemoteRecords[sessionID] {
            return (
                cached.lockedByUserID,
                cached.lockedByDeviceID,
                cached.lockedAt.flatMap(parseSupabaseDateString)
            )
        }
#endif
        let state = sessionCoordinationStateBySessionID[sessionID]
        return (state?.lockedByUserID, state?.lockedByDeviceID, state?.lockedAt)
    }

    func _debugSetSessionCoordinationEntrySnapshotForTests(
        sessionID: UUID,
        snapshot: String?
    ) {
        sessionCoordinationEntrySnapshotBySessionID[sessionID] = snapshot ?? ""
    }

    func _debugSessionCoordinationSnapshotStringForTests(
        metadata: SessionMetadata
    ) -> String? {
        sessionCoordinationTier1SnapshotString(metadata: metadata)
    }

    func _debugAllPropertiesForTests() -> [Property] {
        allProperties
    }

    @MainActor
    func _debugApplySyncDeltaPropertiesForTests(
        records: [DebugRemotePropertyDeltaInput],
        orgID: UUID
    ) -> (applied: Int, skipped: Int) {
        applySyncDeltaProperties(
            records: records.map {
                RemotePropertyDeltaRecord(
                    id: $0.id,
                    orgID: $0.orgID,
                    folderID: $0.folderID,
                    clientName: $0.clientName,
                    clientEmail: $0.clientEmail,
                    clientPhone: $0.clientPhone,
                    name: $0.name,
                    addressLine1: $0.addressLine1,
                    city: $0.city,
                    state: $0.state,
                    postalCode: $0.postalCode,
                    baselineSessionID: $0.baselineSessionID,
                    isArchived: $0.isArchived,
                    createdAt: $0.createdAt,
                    updatedAt: $0.updatedAt,
                    deletedAt: $0.deletedAt
                )
            },
            orgID: orgID
        )
    }

    @MainActor
    func _debugApplySyncDeltaSessionsForTests(
        records: [DebugRemoteSessionDeltaInput],
        orgID: UUID
    ) -> (applied: Int, skipped: Int) {
        applySyncDeltaSessions(
            records: records.map {
                RemoteSessionDeltaRecord(
                    id: $0.id,
                    orgID: $0.orgID,
                    propertyID: $0.propertyID,
                    title: $0.title,
                    status: $0.status,
                    startedAt: $0.startedAt,
                    completedAt: $0.completedAt,
                    updatedAt: $0.updatedAt,
                    deletedAt: $0.deletedAt
                )
            },
            orgID: orgID
        )
    }

    @MainActor
    func _debugPerformSyncDeltaPullForTests(source: String = "test") async {
        await performSyncDeltaPull(source: source)
    }
#endif

    private func makeHubCaches(for properties: [Property]) -> HubCachePayload {
        var sessionIndex: [UUID: [Session]] = [:]
        var drafts: [UUID: Session] = [:]
        var pending: [UUID: Session] = [:]
        var meta: [UUID: HubPropertyMeta] = [:]
        let lookupOrganizations = allOrganizations.isEmpty ? ((try? localStore.fetchOrganizations()) ?? []) : allOrganizations

        for property in properties {
            let sessions = loadAndNormalizeSessions(propertyID: property.id)
            sessionIndex[property.id] = sessions

            if let draft = latestVisibleDraft(in: sessions) {
                drafts[property.id] = draft
            }

            if let pendingSession = sessions
                .filter({ isPendingDelivery($0) })
                .sorted(by: { $0.startedAt > $1.startedAt })
                .first {
                pending[property.id] = pendingSession
            }

            meta[property.id] = makeHubMeta(for: property, organizations: lookupOrganizations)
        }

        return HubCachePayload(
            sessionIndex: sessionIndex,
            drafts: drafts,
            pending: pending,
            meta: meta
        )
    }

    private func makeHubMeta(for property: Property, organizations: [Organization]? = nil) -> HubPropertyMeta {
        let client = property.clientName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let lookupOrganizations = organizations ?? self.organizations
        let organization = lookupOrganizations.first(where: { $0.id == property.orgId })?.name
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let address = normalizedAddressLine(property.address)
        let name = property.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return HubPropertyMeta(
            clientLine: client.isEmpty ? nil : client,
            addressLine: address.isEmpty ? nil : address,
            normalizedNameToken: name.lowercased(),
            normalizedClientToken: client.lowercased(),
            normalizedOrganizationToken: organization.lowercased(),
            normalizedAddressToken: address.lowercased()
        )
    }

    private func loadAndNormalizeSessions(propertyID: UUID) -> [Session] {
        let fetched = (try? localStore.fetchSessions(propertyID: propertyID)) ?? []
        var uniqueByID: [UUID: Session] = [:]
        for session in fetched {
            uniqueByID[session.id] = session
        }
        return uniqueByID.values.sorted { $0.startedAt < $1.startedAt }
    }

    private func normalizedAddressLine(_ rawAddress: String?) -> String {
        (rawAddress ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ", United States", with: "", options: [.caseInsensitive, .anchored, .backwards], range: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func reloadSessionCache(for propertyID: UUID) {
        let sessions = loadAndNormalizeSessions(propertyID: propertyID)
        if allSessionIndexByProperty[propertyID] != sessions {
            allSessionIndexByProperty[propertyID] = sessions
        }

        let latestDraft = latestVisibleDraft(in: sessions)
        if allDraftSessionByProperty[propertyID] != latestDraft {
            allDraftSessionByProperty[propertyID] = latestDraft
        }

        let pendingSession = sessions
            .filter { isPendingDelivery($0) }
            .sorted { $0.startedAt > $1.startedAt }
            .first
        if allPendingExportSessionByProperty[propertyID] != pendingSession {
            allPendingExportSessionByProperty[propertyID] = pendingSession
        }
        applyTenantScopedState()
    }

    private func latestVisibleDraft(in sessions: [Session]) -> Session? {
        sessions
            .filter { $0.status == .draft && sessionHasCaptures($0) }
            .sorted { $0.startedAt > $1.startedAt }
            .first
    }

    private func canonicalDraftSession(for propertyID: UUID, requireCaptures: Bool) -> Session? {
        let drafts = sessions(for: propertyID)
            .filter { $0.status == .draft }
            .sorted { $0.startedAt > $1.startedAt }

        guard requireCaptures else {
            return drafts.first
        }

        return drafts.first(where: { sessionHasCaptures($0) })
    }

    private func sessionHasCaptures(_ session: Session) -> Bool {
        guard let metadata = try? localStore.loadSessionMetadata(propertyID: session.propertyID, sessionID: session.id) else {
            return false
        }
        return metadata.shots.contains { shot in
            let originalRelative = shot.originalRelativePath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !originalRelative.isEmpty else { return false }
            return localStore.resolveSessionRelativeFileURL(
                propertyID: session.propertyID,
                sessionID: session.id,
                relativePath: originalRelative
            ) != nil
        }
    }

    private func scheduleOffloadEligibleSessionMedia(excludingSessionID: UUID?) {
        let excludedSessionID = excludingSessionID
        offloadSweepQueue.async { [weak self] in
            self?.offloadEligibleSessionMedia(excludingSessionID: excludedSessionID)
        }
    }

    private func scheduleSessionArchiveSnapshot(_ session: Session, trigger: String) {
        guard session.status == .completed, session.isSealed else { return }
        archiveSnapshotQueue.async { [weak self] in
            guard let self else { return }
            do {
                _ = try self.localStore.createSessionArchiveSnapshot(session: session, trigger: trigger)
            } catch {
                print(
                    "[SessionArchive] result=failed " +
                    "propertyID=\(session.propertyID.uuidString) " +
                    "sessionID=\(session.id.uuidString) " +
                    "trigger=\(trigger) " +
                    "error=\(error.localizedDescription)"
                )
            }
        }
    }

    private func offloadEligibleSessionMedia(excludingSessionID: UUID?) {
        let now = Date()
        var scanned = 0
        var offloadedFiles = 0
        var skippedCooldown = 0
        var skippedRecentActivation = 0

        let allProperties = (try? localStore.fetchProperties()) ?? []
        for property in allProperties {
            if isPropertyWithinActivationRetentionWindow(property.id, now: now) {
                skippedRecentActivation += 1
                continue
            }
            let propertySessions = (try? localStore.fetchSessions(propertyID: property.id)) ?? []
            for session in propertySessions {
                scanned += 1
                if session.id == excludingSessionID { continue }
                guard session.status == .completed else { continue }
                guard session.isSealed else { continue }
                guard !isPendingDelivery(session) else { continue }
                guard !isReExportEligible(session, now: now) else { continue }
                guard let endedAt = session.endedAt else { continue }
                if now.timeIntervalSince(endedAt) < sessionMediaOffloadCooldown {
                    skippedCooldown += 1
                    continue
                }
                offloadedFiles += localStore.offloadSessionMediaAssets(
                    propertyID: session.propertyID,
                    sessionID: session.id
                )
            }
        }

        logSessionOffload(
            scanned: scanned,
            offloadedFiles: offloadedFiles,
            skippedCooldown: skippedCooldown,
            skippedRecentActivation: skippedRecentActivation
        )
    }

    private func logHubFetch(
        phase: String,
        source: String,
        properties: Int,
        orgs: Int,
        elapsedMs: Int
    ) {
        let signature = "\(phase)|\(source)|\(properties)|\(orgs)"
        let shouldLog = logThrottleQueue.sync { () -> Bool in
            let now = Date()
            let minInterval: TimeInterval = 15
            if lastHubFetchLogSignature == signature,
               let lastHubFetchLogAt,
               now.timeIntervalSince(lastHubFetchLogAt) < minInterval {
                return false
            }
            lastHubFetchLogSignature = signature
            lastHubFetchLogAt = now
            return true
        }
        guard shouldLog else { return }
        print("[HubFetch] phase=\(phase) source=\(source) properties=\(properties) orgs=\(orgs) ms=\(elapsedMs)")
    }

    private func logCloudBackupStatusSink(_ status: CloudBackupStatus) {
        let terminalAppeared =
            status.lastFailureMessage != nil ||
            (status.state == .backedUp && !status.isRunning)

        let shouldLog = logThrottleQueue.sync { () -> Bool in
            if !status.isRunning {
                guard cloudBackupLogRunOpen else { return false }
                guard cloudBackupLogHasPrintedTerminal else { return false }
                guard !cloudBackupLogHasPrintedClose else { return false }

                cloudBackupLogHasPrintedClose = true
                cloudBackupLogRunOpen = false
                return true
            }

            if !cloudBackupLogRunOpen {
                cloudBackupLogRunOpen = true
                cloudBackupLogHasPrintedStart = true
                cloudBackupLogHasPrintedTerminal = false
                cloudBackupLogHasPrintedClose = false
                return true
            }

            guard !cloudBackupLogHasPrintedTerminal else { return false }

            if terminalAppeared {
                cloudBackupLogHasPrintedTerminal = true
                return true
            }

            return false
        }
        guard shouldLog else { return }
        print("[AppStateDiag] cloudBackupStatus_sink")
    }

    private func logSessionOffload(
        scanned: Int,
        offloadedFiles: Int,
        skippedCooldown: Int,
        skippedRecentActivation: Int
    ) {
        let activationRetentionDays = Int(activatedPropertyRetentionWindow / 86_400)
        let cooldownSeconds = Int(sessionMediaOffloadCooldown)
        let signature = "\(scanned)|\(offloadedFiles)|\(skippedCooldown)|\(skippedRecentActivation)|\(activationRetentionDays)|\(cooldownSeconds)"
        let shouldLog = logThrottleQueue.sync { () -> Bool in
            let now = Date()
            let minInterval: TimeInterval = 30
            if lastSessionOffloadLogSignature == signature,
               let lastSessionOffloadLogAt,
               now.timeIntervalSince(lastSessionOffloadLogAt) < minInterval {
                return false
            }
            lastSessionOffloadLogSignature = signature
            lastSessionOffloadLogAt = now
            return true
        }
        guard shouldLog else { return }
        print(
            "[SessionOffload] scanned=\(scanned) " +
            "offloadedFiles=\(offloadedFiles) " +
            "skippedCooldown=\(skippedCooldown) " +
            "skippedRecentActivation=\(skippedRecentActivation) " +
            "activationRetentionDays=\(activationRetentionDays) " +
            "cooldownSeconds=\(cooldownSeconds)"
        )
    }

    private func markPropertyActivated(id: UUID, at date: Date = Date()) {
        var map = propertyActivationTimestampMap()
        map[id.uuidString] = date.timeIntervalSince1970
        let cutoff = date.timeIntervalSince1970 - activatedPropertyRetentionWindow
        map = map.filter { $0.value >= cutoff }
        userDefaults.set(map, forKey: propertyActivationTimestampsDefaultsKey)
    }

    private func propertyActivationTimestampMap() -> [String: TimeInterval] {
        guard let raw = userDefaults.dictionary(forKey: propertyActivationTimestampsDefaultsKey) else {
            return [:]
        }
        var mapped: [String: TimeInterval] = [:]
        mapped.reserveCapacity(raw.count)
        for (key, value) in raw {
            if let time = value as? TimeInterval {
                mapped[key] = time
            } else if let number = value as? NSNumber {
                mapped[key] = number.doubleValue
            }
        }
        return mapped
    }

    private func isPropertyWithinActivationRetentionWindow(_ propertyID: UUID, now: Date) -> Bool {
        let map = propertyActivationTimestampMap()
        guard let timestamp = map[propertyID.uuidString] else { return false }
        return now.timeIntervalSince1970 - timestamp < activatedPropertyRetentionWindow
    }

    func isPendingDelivery(_ session: Session) -> Bool {
        session.isSealed && session.firstDeliveredAt == nil
    }

    func isReExportEligible(_ session: Session, now: Date = Date()) -> Bool {
        guard session.firstDeliveredAt != nil else { return false }
        guard let expiresAt = session.reExportExpiresAt else { return false }
        return now < expiresAt
    }

    func sessionNeedsDeliveryOrReExport(_ session: Session, now: Date = Date()) -> Bool {
        isPendingDelivery(session) || isReExportEligible(session, now: now)
    }

    func sessionReExportWindowExpired(_ session: Session, now: Date = Date()) -> Bool {
        guard session.status == .completed else { return false }
        guard session.isSealed else { return false }
        guard session.firstDeliveredAt != nil else { return false }
        guard let expiresAt = session.reExportExpiresAt else { return false }
        return now >= expiresAt
    }

    private func applyDeliverySuccess(to session: inout Session, deliveredAt: Date) {
        session.isSealed = true
        session.exportedAt = deliveredAt
        if session.firstDeliveredAt == nil {
            session.firstDeliveredAt = deliveredAt
            print("[ExportDelivery] sessionID=\(session.id.uuidString) firstDeliveredAt=\(deliveredAt)")
        }
        if session.reExportExpiresAt == nil, let first = session.firstDeliveredAt {
            session.reExportExpiresAt = Calendar.current.date(byAdding: .day, value: reExportWindowDays, to: first)
            if let expiresAt = session.reExportExpiresAt {
                print("[ExportDelivery] sessionID=\(session.id.uuidString) reExportExpiresAt=\(expiresAt)")
            }
        }
        if let first = session.firstDeliveredAt, let expiresAt = session.reExportExpiresAt {
            let isPendingDelivery = self.isPendingDelivery(session)
            let isReExportEligible = deliveredAt < expiresAt
            print("[ExportEligibility] sessionID=\(session.id.uuidString) now=\(deliveredAt) firstDeliveredAt=\(first) reExportExpiresAt=\(expiresAt) eligible=\(isReExportEligible)")
            print("[DeliveryState] sessionID=\(session.id.uuidString) sealed=\(session.isSealed) firstDeliveredAt=\(String(describing: session.firstDeliveredAt)) reExportExpiresAt=\(String(describing: session.reExportExpiresAt)) exportedAt=\(String(describing: session.exportedAt)) isPendingDelivery=\(isPendingDelivery) isReExportEligible=\(isReExportEligible)")
        }
    }

    private func logActiveSession(_ session: Session?) {
        guard let session else {
            print("[ActiveSession] NONE")
            return
        }
        let isBaseline = properties.first(where: { $0.id == session.propertyID })?.baselineSessionID == session.id
        print(
            "[ActiveSession] propertyID=\(session.propertyID.uuidString) " +
            "sessionID=\(session.id.uuidString) " +
            "isBaseline=\(isBaseline) " +
            "startedAt=\(session.startedAt) " +
            "status=\(session.status.rawValue)"
        )
    }
}
