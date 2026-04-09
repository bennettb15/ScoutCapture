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

struct BackendFeatureFlags {
    let supabaseEnabled: Bool
    let shadowWriteEnabled: Bool
    let supabaseReadEnabled: Bool
    let mediaSupabaseUploadEnabled: Bool

    static func load(
        bundle: Bundle = .main,
        userDefaults: UserDefaults = .standard
    ) -> BackendFeatureFlags {
        BackendFeatureFlags(
            supabaseEnabled: Self.boolValue(for: "supabase_enabled", bundle: bundle, userDefaults: userDefaults),
            shadowWriteEnabled: Self.boolValue(for: "shadow_write_enabled", bundle: bundle, userDefaults: userDefaults),
            supabaseReadEnabled: Self.boolValue(for: "supabase_read_enabled", bundle: bundle, userDefaults: userDefaults),
            mediaSupabaseUploadEnabled: Self.boolValue(for: "media_supabase_upload_enabled", bundle: bundle, userDefaults: userDefaults)
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

final class AppState: ObservableObject {
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

    private struct SupabasePropertyPayload: Encodable {
        let id: UUID
        let orgID: UUID
        let name: String
        let addressLine1: String?
        let city: String?
        let state: String?
        let postalCode: String?

        enum CodingKeys: String, CodingKey {
            case id
            case orgID = "org_id"
            case name
            case addressLine1 = "address_line1"
            case city
            case state
            case postalCode = "postal_code"
        }
    }

    private struct SupabaseSessionPayload: Encodable {
        let id: UUID
        let orgID: UUID
        let propertyID: UUID
        let title: String?
        let status: String
        let startedAt: String
        let completedAt: String?

        enum CodingKeys: String, CodingKey {
            case id
            case orgID = "org_id"
            case propertyID = "property_id"
            case title
            case status
            case startedAt = "started_at"
            case completedAt = "completed_at"
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
    private let cloudBackupManager: CloudBackupManager
    private let selectedPropertyDefaultsKey = "scoutcapture.selectedPropertyID"
    private let activeOrganizationDefaultsKeyPrefix = "scoutcapture.activeOrganizationID"
    private let propertyActivationTimestampsDefaultsKey = "scoutcapture.propertyActivationTimestamps.v1"
    private let reExportWindowDays = 7
    private let sessionMediaOffloadCooldown: TimeInterval = 30 * 60
    private let activatedPropertyRetentionWindow: TimeInterval = 7 * 24 * 60 * 60
    private let offloadSweepQueue = DispatchQueue(label: "ScoutCapture.AppState.offloadSweep", qos: .utility)
    private let archiveSnapshotQueue = DispatchQueue(label: "ScoutCapture.AppState.archiveSnapshot", qos: .utility)
    private let logThrottleQueue = DispatchQueue(label: "ScoutCapture.AppState.logThrottle")
    private let supabaseMediaOperationQueue = DispatchQueue(label: "ScoutCapture.AppState.supabaseMediaOperations")
    private var lastHubFetchLogSignature: String?
    private var lastHubFetchLogAt: Date?
    private var lastSessionOffloadLogSignature: String?
    private var lastSessionOffloadLogAt: Date?
    private var didLoad = false
    private var cancellables: Set<AnyCancellable> = []
    private var liveSyncTimer: Timer?
    private var lastLiveSyncFingerprint: String?
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
    private var inFlightSupabaseMediaOperations: Set<String> = []
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
        userDefaults: UserDefaults = .standard
    ) {
        self.injectedLocalStore = localStore
        self.userDefaults = userDefaults
        self.cloudBackupManager = CloudBackupManager(userDefaults: userDefaults)
        self.cloudBackupStatus = cloudBackupManager.status
        self.supabaseConfiguration = AppState.loadSupabaseConfiguration()
        self.backendFeatureFlags = BackendFeatureFlags.load(userDefaults: userDefaults)

        if let rawID = userDefaults.string(forKey: selectedPropertyDefaultsKey) {
            self.selectedPropertyID = UUID(uuidString: rawID)
        } else {
            self.selectedPropertyID = nil
        }

        self.currentSession = nil

        cloudBackupManager.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.cloudBackupStatus = status
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .scoutPersistentDataDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.markLiveSyncBurstWindow(seconds: 20)
                self?.cloudBackupManager.markDataChanged()
            }
            .store(in: &cancellables)

        prepareCollaborativeBackendBootstrap()
    }

    deinit {
        authStateChangesTask?.cancel()
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

    private func prepareCollaborativeBackendBootstrap() {
        guard backendFeatureFlags.supabaseEnabled else {
            supabaseClient = nil
            isAuthenticationReady = true
            isOrganizationContextReady = true
            print("[Supabase] bootstrap skipped because supabase_enabled=false")
            return
        }

        guard supabaseConfiguration.isConfigured else {
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
            "mediaUpload=\(backendFeatureFlags.mediaSupabaseUploadEnabled)"
        )
        if let url = supabaseConfiguration.url, let anonKey = supabaseConfiguration.anonKey {
            supabaseClient = SupabaseClient(supabaseURL: url, supabaseKey: anonKey)
            beginObservingAuthenticationState()
        }
    }

    private func beginObservingAuthenticationState() {
        authStateChangesTask?.cancel()

        guard let client = supabaseClient else {
            applyAuthenticationState(user: nil, ready: true)
            return
        }

        applyAuthenticationState(user: nil, ready: false)

        authStateChangesTask = Task { [weak self] in
            guard let self else { return }

            for await (event, authSession) in client.auth.authStateChanges {
                if Task.isCancelled {
                    return
                }

                let userID = authSession?.user.id
                let email = authSession?.user.email
                let user = userID.map { AuthenticatedSupabaseUser(id: $0, email: email) }
                self.applyAuthenticationState(user: user, ready: true)

                if event == .signedOut {
                    self.lastEnsuredUserProfileID = nil
                    self.clearOrganizationContext()
                    continue
                }

                if [.initialSession, .signedIn, .tokenRefreshed, .userUpdated].contains(event) {
                    do {
                        try await self.ensureCurrentUserProfileIfNeeded(for: userID)
                        try await self.refreshOrganizationContext(for: userID)
                    } catch {
                        print("[SupabaseAuth] ensure_current_user_profile failed: \(error.localizedDescription)")
                        self.handleOrganizationRefreshFailure()
                    }
                }
            }
        }
    }

    private func applyAuthenticationState(user: AuthenticatedSupabaseUser?, ready: Bool) {
        DispatchQueue.main.async {
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
        DispatchQueue.main.async {
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
        }
    }

    private func handleOrganizationRefreshFailure() {
        DispatchQueue.main.async {
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
        DispatchQueue.main.async {
            self.isAuthenticating = authenticating
        }
    }

    private func ensureCurrentUserProfileIfNeeded(for userID: UUID?, force: Bool = false) async throws {
        guard let userID, let client = supabaseClient else { return }
        guard force || lastEnsuredUserProfileID != userID else { return }

        try await (try client.rpc("ensure_current_user_profile")).execute()
        lastEnsuredUserProfileID = userID
    }

    func signIn(email: String, password: String) async throws {
        guard let client = supabaseClient else { return }

        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        setAuthenticating(true)
        DispatchQueue.main.async {
            self.authenticationErrorMessage = nil
        }
        defer { setAuthenticating(false) }

        do {
            let session = try await client.auth.signIn(email: trimmedEmail, password: password)
            try await ensureCurrentUserProfileIfNeeded(for: session.user.id, force: true)
        } catch {
            DispatchQueue.main.async {
                self.authenticationErrorMessage = error.localizedDescription
            }
            throw error
        }
    }

    func signUp(email: String, password: String) async throws -> AuthenticationFlowResult {
        guard let client = supabaseClient else { return .requiresEmailConfirmation }

        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        setAuthenticating(true)
        DispatchQueue.main.async {
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
            DispatchQueue.main.async {
                self.authenticationErrorMessage = error.localizedDescription
            }
            throw error
        }
    }

    func signOut() async {
        guard let client = supabaseClient else { return }

        setAuthenticating(true)
        defer { setAuthenticating(false) }

        do {
            try await client.auth.signOut(scope: .local)
        } catch {
            DispatchQueue.main.async {
                self.authenticationErrorMessage = error.localizedDescription
            }
        }
    }

    func uploadOperationalMediaIfNeeded(
        propertyID: UUID,
        sessionID: UUID,
        shotID: UUID
    ) {
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

    func ensureOperationalMediaAvailable(
        propertyID: UUID,
        sessionID: UUID,
        shotID: UUID
    ) {
        guard backendFeatureFlags.supabaseEnabled,
              backendFeatureFlags.supabaseReadEnabled,
              supabaseClient != nil else {
            return
        }

        let operationKey = "download|\(sessionID.uuidString.lowercased())|\(shotID.uuidString.lowercased())"
        guard beginSupabaseMediaOperation(operationKey) else { return }

        Task(priority: .utility) { [weak self] in
            defer { self?.endSupabaseMediaOperation(operationKey) }
            await self?.performOperationalMediaHydration(
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

            DispatchQueue.main.async {
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
        let organization = organizations.first(where: { $0.id == orgID })
        let orgName = normalizedSupabaseText(
            organization?.name ?? metadata.orgNameAtCapture
        ) ?? "Organization \(orgID.uuidString)"
        let propertyName = normalizedSupabaseText(
            property?.name ?? metadata.propertyNameAtCapture
        ) ?? "Property \(propertyID.uuidString)"

        let propertyPayload = SupabasePropertyPayload(
            id: propertyID,
            orgID: orgID,
            name: propertyName,
            addressLine1: normalizedSupabaseText(property?.address ?? metadata.propertyAddressAtCapture),
            city: normalizedSupabaseText(property?.city ?? metadata.propertyCityAtCapture),
            state: normalizedSupabaseText(property?.state ?? metadata.propertyStateAtCapture),
            postalCode: normalizedSupabaseText(property?.zip ?? metadata.propertyZipAtCapture)
        )

        let sessionPayload = SupabaseSessionPayload(
            id: sessionID,
            orgID: orgID,
            propertyID: propertyID,
            title: normalizedSupabaseText(metadata.propertyNameAtCapture ?? property?.name),
            status: metadata.status.rawValue,
            startedAt: metadata.startedAt.ISO8601Format(),
            completedAt: metadata.endedAt?.ISO8601Format()
        )

        do {
            try await client
                .from("orgs")
                .upsert(SupabaseOrgPayload(id: orgID, name: orgName), onConflict: "id", returning: .minimal)
                .execute()

            try await client
                .from("properties")
                .upsert(propertyPayload, onConflict: "id", returning: .minimal)
                .execute()

            try await client
                .from("sessions")
                .upsert(sessionPayload, onConflict: "id", returning: .minimal)
                .execute()
        } catch {
            print(
                "[SupabaseSessionEnsure] result=failed " +
                "orgID=\(orgID.uuidString) " +
                "propertyID=\(propertyID.uuidString) " +
                "sessionID=\(sessionID.uuidString) " +
                "error=\(error.localizedDescription)"
            )
            throw NSError(domain: "ScoutCapture.SupabaseMedia", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Failed to ensure org/property/session rows before shot metadata write: \(error.localizedDescription)"
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

    private func normalizedSupabaseText(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
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
        _ = supabaseMediaOperationQueue.sync {
            inFlightSupabaseMediaOperations.remove(key)
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
            DispatchQueue.main.async {
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
        cloudBackupManager.refreshStatus()
        setLoadingState(true)
        do {
            let payload = try makeRefreshPayload()
            applyRefreshPayload(payload)
        } catch {
            // Preserve current in-memory view on transient iCloud read failures.
            print("[PropertiesRefresh] transient read failure: \(error.localizedDescription)")
        }
        setLoadingState(false)
    }

    func refreshPropertiesInBackground() {
        cloudBackupManager.refreshStatus()
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

            DispatchQueue.main.async {
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
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        self.refreshPropertiesInBackground()
                    }
                    return
                }
                if !shouldRunFallback {
                    self.isBackgroundRefreshInFlight = false
                }
            }

            guard shouldRunFallback else { return }

            do {
                let payload = try self.makeRefreshPayload()
                DispatchQueue.main.async {
                    self.applyRefreshPayload(payload)
                    self.scheduleOffloadEligibleSessionMedia(excludingSessionID: self.currentSession?.id)
                    self.setLoadingState(false)
                    self.isBackgroundRefreshInFlight = false
                }
            } catch {
                DispatchQueue.main.async {
                    // Preserve current in-memory view on transient iCloud read failures.
                    print("[PropertiesRefresh] transient read failure: \(error.localizedDescription)")
                    self.setLoadingState(false)
                    self.isBackgroundRefreshInFlight = false
                }
            }
        }
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self else { return }
                if self.isLoading { return }
                self.refreshPropertiesInBackground()
            }
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

    private func setLoadingState(_ loading: Bool) {
        guard isLoading != loading else { return }
        isLoading = loading
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
            cloudBackupManager.markDataChanged(scheduleBackupAfter: 0)
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
            cloudBackupManager.markDataChanged(scheduleBackupAfter: 0)
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
            cloudBackupManager.setCaptureModeActive(true)
            return currentSession
        }
        
        if let draft = sessionsForProperty
            .filter({ $0.status == .draft })
            .sorted(by: { $0.startedAt > $1.startedAt })
            .first {
            currentSession = draft
            print("[StartSession] propertyID=\(selectedPropertyID.uuidString) blockedReason=none pendingDeliveryExists=\(pendingDeliveryExists) reExportEligibleExists=\(reExportEligibleExists)")
            cloudBackupManager.setCaptureModeActive(true)
            return draft
        }

        let session = Session(propertyID: selectedPropertyID, startedAt: Date(), status: .draft, endedAt: nil, exportedAt: nil)
        currentSession = session
        print("[StartSession] propertyID=\(selectedPropertyID.uuidString) blockedReason=none pendingDeliveryExists=\(pendingDeliveryExists) reExportEligibleExists=\(reExportEligibleExists)")
        _ = try? localStore.upsertSession(session)
        cloudBackupManager.setCaptureModeActive(true)
        reloadSessionCache(for: selectedPropertyID)
        return session
    }

    func saveDraftCurrentSession() {
        guard var session = currentSession else { return }
        session.status = .draft
        session.endedAt = nil
        session.exportedAt = nil
        if session.firstDeliveredAt == nil {
            session.isSealed = false
        }
        currentSession = session
        _ = try? localStore.upsertSession(session)
        reloadSessionCache(for: session.propertyID)
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
        _ = try? localStore.upsertSession(session)
        reloadSessionCache(for: session.propertyID)
        scheduleOffloadEligibleSessionMedia(excludingSessionID: currentSession?.id)
        cloudBackupManager.setCaptureModeActive(false)
        triggerBackupForLifecycleEvent()
    }
    
    func clearCurrentSession() {
        scheduleOffloadEligibleSessionMedia(excludingSessionID: currentSession?.id)
        currentSession = nil
        cloudBackupManager.setCaptureModeActive(false)
    }
    
    func draftSession(for propertyID: UUID) -> Session? {
        guard canAccessProperty(propertyID) else { return nil }
        if let cached = draftSessionByProperty[propertyID] {
            return cached
        }
        guard let draft = try? localStore.latestDraftSession(propertyID: propertyID) else {
            return nil
        }
        return sessionHasCaptures(draft) ? draft : nil
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
        _ = try? localStore.upsertSession(session)
        reloadSessionCache(for: session.propertyID)
        scheduleSessionArchiveSnapshot(session, trigger: "markCurrentSessionExported")
        scheduleOffloadEligibleSessionMedia(excludingSessionID: currentSession?.id)
        cloudBackupManager.setCaptureModeActive(false)
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
        _ = try? localStore.upsertSession(session)
        reloadSessionCache(for: session.propertyID)
        scheduleSessionArchiveSnapshot(session, trigger: "sealCurrentSessionForExportLater")
        scheduleOffloadEligibleSessionMedia(excludingSessionID: currentSession?.id)
        cloudBackupManager.setCaptureModeActive(false)
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
        _ = try? localStore.upsertSession(session)
        reloadSessionCache(for: session.propertyID)
        scheduleSessionArchiveSnapshot(session, trigger: "sealCurrentSessionForExportNow")
        scheduleOffloadEligibleSessionMedia(excludingSessionID: currentSession?.id)
        cloudBackupManager.setCaptureModeActive(false)
        triggerBackupForLifecycleEvent()
    }
    
    func loadDraftSession(for propertyID: UUID) -> Session? {
        guard canAccessProperty(propertyID) else { return nil }
        guard let draft = draftSession(for: propertyID) else { return nil }
        selectedPropertyID = propertyID
        currentSession = draft
        cloudBackupManager.setCaptureModeActive(true)
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
            _ = try localStore.upsertSession(session)
            reloadSessionCache(for: propertyID)
            scheduleSessionArchiveSnapshot(session, trigger: "markSessionExported")
            scheduleOffloadEligibleSessionMedia(excludingSessionID: currentSession?.id)
            cloudBackupManager.setCaptureModeActive(false)
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
            cloudBackupManager.markDataChanged(scheduleBackupAfter: 0)
            return true
        } catch {
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
        cloudBackupManager.refreshStatus()
        NotificationCenter.default.post(name: .scoutClearLocalUICache, object: nil)
    }

    func backupNow() {
        cloudBackupManager.backupNow()
    }

    func refreshBackupStatus() {
        cloudBackupManager.refreshStatus()
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
        cloudBackupManager.refreshStatus()
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
                let restoredSelectedPropertyID = try self.cloudBackupManager.restoreLatestBackup(mode: .mergeMissingPropertiesOnly)
                DispatchQueue.main.async {
                    self.completeMigrationImport(restoredSelectedPropertyID: restoredSelectedPropertyID)
                    completion(nil)
                }
            } catch {
                DispatchQueue.main.async {
                    self.cloudBackupManager.refreshStatus()
                    completion(error.localizedDescription)
                }
            }
        }
    }

    func triggerBackupForLifecycleEvent() {
        cloudBackupManager.setCaptureModeActive(false)
        cloudBackupManager.markDataChanged(scheduleBackupAfter: 0)
    }

    func handleSceneDidEnterBackground() {
        cloudBackupManager.scheduleAutomaticBackup(after: 0)
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
        if allProperties != properties {
            allProperties = properties
        }
        if allOrganizations != organizations {
            allOrganizations = organizations
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
