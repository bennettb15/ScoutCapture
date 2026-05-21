import XCTest
@testable import ScoutCapture

private final class Phase2C23ITestBundle: Bundle {
    private let values: [String: Any]

    init(values: [String: Any]) {
        self.values = values
        super.init()
    }

    override func object(forInfoDictionaryKey key: String) -> Any? {
        values[key]
    }
}

@MainActor
final class Phase2C23IALocalSupabaseOverrideTests: XCTestCase {
    private func makeDefaults(flagEnabled: Bool = false) -> UserDefaults {
        let suite = "Phase2C23IA-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        defaults.set(flagEnabled, forKey: "session_snapshot_shadow_write_enabled")
        return defaults
    }

    private func makeEmptyDefaults() -> UserDefaults {
        let suite = "Phase2C23IA-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func localSnapshotEnvironment(flagValue: String = "true") -> [String: String] {
        [
            "SCOUTCAPTURE_SUPABASE_URL": "http://127.0.0.1:54321",
            "SCOUTCAPTURE_SUPABASE_ANON_KEY": "local-anon-key",
            "session_snapshot_shadow_write_enabled": flagValue
        ]
    }

    private func approvedStagingSnapshotEnvironment(flagValue: String = "true") -> [String: String] {
        [
            "SCOUTCAPTURE_SUPABASE_URL": "https://hpekjqqiyurrewfjvjmn.supabase.co",
            "SCOUTCAPTURE_SUPABASE_ANON_KEY": "staging-anon-key",
            "session_snapshot_shadow_write_enabled": flagValue
        ]
    }

    private func makeStoreWithPropertyAndSessions(
        sessionStarts: [TimeInterval]
    ) throws -> (store: LocalStore, property: Property, sessions: [Session]) {
        let store = LocalStore(testStorageRootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let property = try store.createProperty(Property(id: UUID(), orgId: UUID(), name: "Manual Target Property"))
        let sessions = try sessionStarts.map { start in
            try store.upsertSession(
                Session(
                    id: UUID(),
                    propertyID: property.id,
                    startedAt: Date(timeIntervalSinceReferenceDate: start),
                    status: start == sessionStarts.max() ? .completed : .draft,
                    endedAt: start == sessionStarts.max() ? Date(timeIntervalSinceReferenceDate: start + 100) : nil,
                    isSealed: start == sessionStarts.max()
                )
            )
        }
        return (store, property, sessions)
    }

    func testDefaultConfigUsesInfoPlistValues() {
        let bundle = Phase2C23ITestBundle(values: [
            "SUPABASE_URL": "https://remote.example.supabase.co",
            "SUPABASE_ANON_KEY": "remote-anon-key"
        ])

        let config = AppState.loadSupabaseConfiguration(
            bundle: bundle,
            environment: [:],
            debugOverrideAllowed: true
        )

        XCTAssertEqual(config.source, .infoPlist)
        XCTAssertEqual(config.url?.absoluteString, "https://remote.example.supabase.co")
        XCTAssertEqual(config.anonKey, "remote-anon-key")
        XCTAssertFalse(config.isOverrideActive)
    }

    func testEnvironmentOverrideReplacesURLAndKeyInDebugContext() {
        let bundle = Phase2C23ITestBundle(values: [
            "SUPABASE_URL": "https://remote.example.supabase.co",
            "SUPABASE_ANON_KEY": "remote-anon-key"
        ])

        let config = AppState.loadSupabaseConfiguration(
            bundle: bundle,
            environment: [
                "SCOUTCAPTURE_SUPABASE_URL": "http://127.0.0.1:54321",
                "SCOUTCAPTURE_SUPABASE_ANON_KEY": "local-anon-key"
            ],
            debugOverrideAllowed: true
        )

        XCTAssertEqual(config.source, .environmentOverride)
        XCTAssertEqual(config.url?.absoluteString, "http://127.0.0.1:54321")
        XCTAssertEqual(config.anonKey, "local-anon-key")
        XCTAssertTrue(config.isOverrideActive)
    }

    func testMalformedOverrideIsRejected() {
        let config = AppState.loadSupabaseConfiguration(
            bundle: Phase2C23ITestBundle(values: [
                "SUPABASE_URL": "https://remote.example.supabase.co",
                "SUPABASE_ANON_KEY": "remote-anon-key"
            ]),
            environment: [
                "SCOUTCAPTURE_SUPABASE_URL": "not-a-url",
                "SCOUTCAPTURE_SUPABASE_ANON_KEY": "local-anon-key"
            ],
            debugOverrideAllowed: true
        )

        XCTAssertEqual(config.source, .invalidEnvironmentOverride)
        XCTAssertFalse(config.isConfigured)
        XCTAssertEqual(config.targetClassification, .invalid)
    }

    func testMalformedOverrideKeyIsRejected() {
        let config = AppState.loadSupabaseConfiguration(
            bundle: Phase2C23ITestBundle(values: [
                "SUPABASE_URL": "https://remote.example.supabase.co",
                "SUPABASE_ANON_KEY": "remote-anon-key"
            ]),
            environment: [
                "SCOUTCAPTURE_SUPABASE_URL": "https://hpekjqqiyurrewfjvjmn.supabase.co",
                "SCOUTCAPTURE_SUPABASE_ANON_KEY": ""
            ],
            debugOverrideAllowed: true
        )

        XCTAssertEqual(config.source, .invalidEnvironmentOverride)
        XCTAssertFalse(config.isConfigured)
        XCTAssertEqual(config.targetClassification, .invalid)
        XCTAssertFalse(config.isSessionSnapshotShadowWriteOverrideAllowed)
    }

    func testLocalStagingAndRemoteTargetsAreClassified() {
        let local = SupabaseRuntimeConfiguration(
            url: URL(string: "http://127.0.0.1:54321"),
            anonKey: "local-anon-key",
            source: .environmentOverride
        )
        let staging = SupabaseRuntimeConfiguration(
            url: URL(string: "https://hpekjqqiyurrewfjvjmn.supabase.co"),
            anonKey: "staging-anon-key",
            source: .environmentOverride
        )
        let remote = SupabaseRuntimeConfiguration(
            url: URL(string: "https://remote.example.supabase.co"),
            anonKey: "remote-anon-key",
            source: .infoPlist
        )

        XCTAssertEqual(local.targetClassification, .localDev)
        XCTAssertTrue(local.isSafeLocalDevOverride)
        XCTAssertTrue(local.isSessionSnapshotShadowWriteOverrideAllowed)
        XCTAssertEqual(staging.targetClassification, .approvedStaging)
        XCTAssertFalse(staging.isSafeLocalDevOverride)
        XCTAssertTrue(staging.isSessionSnapshotShadowWriteOverrideAllowed)
        XCTAssertEqual(remote.targetClassification, .remote)
        XCTAssertFalse(remote.isSafeLocalDevOverride)
        XCTAssertFalse(remote.isSessionSnapshotShadowWriteOverrideAllowed)
    }

    func testManualUploadRemainsDisabledUnlessFlagAndValidSafeTarget() {
        let store = LocalStore(testStorageRootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let disabled = AppState(localStore: store, userDefaults: makeDefaults(flagEnabled: false), disableCloudBackupForTests: true)

        XCTAssertFalse(disabled.manualSessionSnapshotUploadAvailability.isAvailable)
        XCTAssertTrue(disabled.manualSessionSnapshotUploadAvailability.reason.contains("disabled"))
    }

    func testDiagnosticsRedactAnonKey() {
        let config = SupabaseRuntimeConfiguration(
            url: URL(string: "http://127.0.0.1:54321"),
            anonKey: "abcdefghijklmnopqrstuvwxyz",
            source: .environmentOverride
        )

        XCTAssertEqual(config.redactedAnonKeyDisplay, "abcd...wxyz")
        XCTAssertFalse(config.redactedAnonKeyDisplay.contains("efghijklmnopqrstuv"))
    }

    func testSessionSnapshotFlagDefaultsFalse() {
        let flags = BackendFeatureFlags.load(userDefaults: makeEmptyDefaults(), environment: [:])

        XCTAssertFalse(flags.sessionSnapshotShadowWriteEnabled)
    }

    func testSessionSnapshotEnvironmentOverrideEnablesOnlyWhenAllowed() {
        let disallowed = BackendFeatureFlags.load(
            userDefaults: makeEmptyDefaults(),
            environment: ["session_snapshot_shadow_write_enabled": "true"],
            allowSessionSnapshotEnvironmentOverride: false
        )
        let allowed = BackendFeatureFlags.load(
            userDefaults: makeEmptyDefaults(),
            environment: ["session_snapshot_shadow_write_enabled": "true"],
            allowSessionSnapshotEnvironmentOverride: true
        )

        XCTAssertFalse(disallowed.sessionSnapshotShadowWriteEnabled)
        XCTAssertTrue(allowed.sessionSnapshotShadowWriteEnabled)
    }

    func testSessionSnapshotEnvironmentOverrideAcceptsScoutCaptureUppercaseKey() {
        let flags = BackendFeatureFlags.load(
            userDefaults: makeEmptyDefaults(),
            environment: ["SCOUTCAPTURE_SESSION_SNAPSHOT_SHADOW_WRITE_ENABLED": "yes"],
            allowSessionSnapshotEnvironmentOverride: true
        )

        XCTAssertTrue(flags.sessionSnapshotShadowWriteEnabled)
    }

    func testMalformedSessionSnapshotEnvironmentOverrideIsIgnored() {
        let defaults = makeDefaults(flagEnabled: false)
        let flags = BackendFeatureFlags.load(
            userDefaults: defaults,
            environment: ["session_snapshot_shadow_write_enabled": "definitely"],
            allowSessionSnapshotEnvironmentOverride: true
        )

        XCTAssertFalse(flags.sessionSnapshotShadowWriteEnabled)
    }

    func testSessionSnapshotUserDefaultsOverrideStillWorksInDevTests() {
        let flags = BackendFeatureFlags.load(
            userDefaults: makeDefaults(flagEnabled: true),
            environment: [:],
            allowSessionSnapshotEnvironmentOverride: false
        )

        XCTAssertTrue(flags.sessionSnapshotShadowWriteEnabled)
    }

    func testAppStateLocalHealthFlagPathReflectsLocalEnvironmentOverride() {
        let store = LocalStore(testStorageRootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let appState = AppState(
            localStore: store,
            userDefaults: makeEmptyDefaults(),
            environment: [
                "SCOUTCAPTURE_SUPABASE_URL": "http://127.0.0.1:54321",
                "SCOUTCAPTURE_SUPABASE_ANON_KEY": "local-anon-key",
                "session_snapshot_shadow_write_enabled": "true"
            ],
            disableCloudBackupForTests: true
        )

        XCTAssertEqual(appState.supabaseConfiguration.targetClassification, .localDev)
        XCTAssertTrue(appState.supabaseConfiguration.isSafeLocalDevOverride)
        XCTAssertTrue(appState.backendFeatureFlags.sessionSnapshotShadowWriteEnabled)
        XCTAssertTrue(appState.manualSessionSnapshotUploadAvailability.reason.contains("no property context"))
    }

    func testAppStateLocalHealthFlagPathReflectsApprovedStagingEnvironmentOverride() {
        let store = LocalStore(testStorageRootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let appState = AppState(
            localStore: store,
            userDefaults: makeEmptyDefaults(),
            environment: approvedStagingSnapshotEnvironment(),
            disableCloudBackupForTests: true
        )

        XCTAssertEqual(appState.supabaseConfiguration.targetClassification, .approvedStaging)
        XCTAssertTrue(appState.supabaseConfiguration.isSessionSnapshotShadowWriteOverrideAllowed)
        XCTAssertTrue(appState.backendFeatureFlags.sessionSnapshotShadowWriteEnabled)
        XCTAssertTrue(appState.manualSessionSnapshotUploadAvailability.reason.contains("no property context"))
    }

    func testAppStateIgnoresSessionSnapshotEnvironmentOverrideWithoutLocalSupabaseOverride() {
        let store = LocalStore(testStorageRootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let appState = AppState(
            localStore: store,
            userDefaults: makeEmptyDefaults(),
            environment: [
                "SCOUTCAPTURE_SUPABASE_URL": "https://remote.example.supabase.co",
                "SCOUTCAPTURE_SUPABASE_ANON_KEY": "remote-anon-key",
                "session_snapshot_shadow_write_enabled": "true"
            ],
            disableCloudBackupForTests: true
        )

        XCTAssertEqual(appState.supabaseConfiguration.targetClassification, .remote)
        XCTAssertFalse(appState.supabaseConfiguration.isSafeLocalDevOverride)
        XCTAssertFalse(appState.supabaseConfiguration.isSessionSnapshotShadowWriteOverrideAllowed)
        XCTAssertFalse(appState.backendFeatureFlags.sessionSnapshotShadowWriteEnabled)
    }

    func testAppStateIgnoresSessionSnapshotEnvironmentOverrideForProductionRemote() {
        let store = LocalStore(testStorageRootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let appState = AppState(
            localStore: store,
            userDefaults: makeEmptyDefaults(),
            environment: [
                "SCOUTCAPTURE_SUPABASE_URL": "https://chlvazmtucoszicehtnm.supabase.co",
                "SCOUTCAPTURE_SUPABASE_ANON_KEY": "production-anon-key",
                "session_snapshot_shadow_write_enabled": "true"
            ],
            disableCloudBackupForTests: true
        )

        XCTAssertEqual(appState.supabaseConfiguration.targetClassification, .remote)
        XCTAssertFalse(appState.supabaseConfiguration.isSessionSnapshotShadowWriteOverrideAllowed)
        XCTAssertFalse(appState.backendFeatureFlags.sessionSnapshotShadowWriteEnabled)
    }

    func testManualSnapshotUploadTargetUsesActiveSessionFirst() throws {
        let fixture = try makeStoreWithPropertyAndSessions(sessionStarts: [100, 300])
        let appState = AppState(
            localStore: fixture.store,
            userDefaults: makeEmptyDefaults(),
            environment: localSnapshotEnvironment(),
            disableCloudBackupForTests: true
        )
        appState.properties = [fixture.property]
        appState.selectedPropertyID = fixture.property.id
        appState.currentSession = fixture.sessions[0]

        let target = try XCTUnwrap(appState.manualSessionSnapshotUploadTarget)
        XCTAssertEqual(target.source, .activeSession)
        XCTAssertEqual(target.propertyID, fixture.property.id)
        XCTAssertEqual(target.propertyName, fixture.property.name)
        XCTAssertEqual(target.sessionID, fixture.sessions[0].id)
        XCTAssertTrue(appState.manualSessionSnapshotUploadAvailability.isAvailable)
        XCTAssertEqual(appState.localDiagnostics.sessionSnapshotUpload.attemptedCount, 0)
    }

    func testManualSnapshotUploadTargetFallsBackToPropertyHistorySessionSource() throws {
        let fixture = try makeStoreWithPropertyAndSessions(sessionStarts: [100, 300])
        let appState = AppState(
            localStore: fixture.store,
            userDefaults: makeEmptyDefaults(),
            environment: localSnapshotEnvironment(),
            disableCloudBackupForTests: true
        )
        appState.properties = [fixture.property]
        appState.selectedPropertyID = fixture.property.id
        appState.currentSession = nil

        let target = try XCTUnwrap(appState.manualSessionSnapshotUploadTarget)
        let historySessions = appState.sessions(for: fixture.property.id)
        XCTAssertEqual(historySessions.map(\.id), fixture.sessions.map(\.id))
        XCTAssertEqual(target.source, .mostRecentLocalSession)
        XCTAssertEqual(target.sessionID, fixture.sessions[1].id)
        XCTAssertEqual(target.sessionStatus, .completed)
        XCTAssertEqual(appState.manualSessionSnapshotUploadTargetResolution.sessionsFoundForPropertyCount, 2)
        XCTAssertTrue(appState.manualSessionSnapshotUploadAvailability.isAvailable)
        XCTAssertEqual(appState.localDiagnostics.sessionSnapshotUpload.attemptedCount, 0)
    }

    func testManualSnapshotUploadTargetDisabledWithoutPropertyOrSessionTarget() throws {
        let store = LocalStore(testStorageRootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let appState = AppState(
            localStore: store,
            userDefaults: makeEmptyDefaults(),
            environment: localSnapshotEnvironment(),
            disableCloudBackupForTests: true
        )

        XCTAssertNil(appState.manualSessionSnapshotUploadTarget)
        XCTAssertFalse(appState.manualSessionSnapshotUploadAvailability.isAvailable)
        XCTAssertTrue(appState.manualSessionSnapshotUploadAvailability.reason.contains("no property context"))

        let property = try store.createProperty(Property(id: UUID(), orgId: UUID(), name: "Empty Property"))
        appState.properties = [property]
        appState.selectedPropertyID = property.id

        XCTAssertNil(appState.manualSessionSnapshotUploadTarget)
        XCTAssertFalse(appState.manualSessionSnapshotUploadAvailability.isAvailable)
        let resolution = appState.manualSessionSnapshotUploadTargetResolution
        XCTAssertEqual(resolution.selectedPropertyID, property.id)
        XCTAssertEqual(resolution.sessionsFoundForPropertyCount, 0)
        XCTAssertFalse(resolution.localSessionIndexAvailable)
        XCTAssertTrue(appState.manualSessionSnapshotUploadAvailability.reason.contains("no local session"))
        XCTAssertTrue(appState.manualSessionSnapshotUploadAvailability.reason.contains(property.id.uuidString))
        XCTAssertTrue(appState.manualSessionSnapshotUploadAvailability.reason.contains("sessions_found=0"))
        XCTAssertTrue(appState.manualSessionSnapshotUploadAvailability.reason.contains("local_session_index_available=false"))
        XCTAssertEqual(appState.localDiagnostics.sessionSnapshotUpload.attemptedCount, 0)
    }

    func testLocalDevSnapshotTestSessionCreationProducesSessionJSONAndUploadTarget() throws {
        let store = LocalStore(testStorageRootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let property = try store.createProperty(Property(id: UUID(), orgId: UUID(), name: "Simulator Snapshot Property"))
        let appState = AppState(
            localStore: store,
            userDefaults: makeEmptyDefaults(),
            environment: localSnapshotEnvironment(),
            disableCloudBackupForTests: true
        )
        appState.properties = [property]
        appState.selectedPropertyID = property.id

        XCTAssertTrue(appState.manualSessionSnapshotTestSessionCreationAvailability.isAvailable)
        let result = appState.createManualSessionSnapshotTestSessionForLocalDev()

        XCTAssertTrue(result.created)
        let sessionID = try XCTUnwrap(result.sessionID)
        let persisted = try XCTUnwrap(appState.sessions(for: property.id).first { $0.id == sessionID })
        XCTAssertEqual(persisted.status, .completed)
        XCTAssertEqual(persisted.notes, "Snapshot test session - local/dev only")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.sessionJSONURL(propertyID: property.id, sessionID: sessionID).path))
        let metadata = try store.loadSessionMetadata(propertyID: property.id, sessionID: sessionID)
        XCTAssertEqual(metadata.sessionID, sessionID)
        XCTAssertEqual(metadata.propertyID, property.id)
        XCTAssertEqual(metadata.shots.count, 0)

        let target = try XCTUnwrap(appState.manualSessionSnapshotUploadTarget)
        XCTAssertEqual(target.source, .mostRecentLocalSession)
        XCTAssertEqual(target.sessionID, sessionID)
    }

    func testSnapshotTestSessionCreationIsUnavailableWithoutLocalDevOverride() throws {
        let store = LocalStore(testStorageRootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let property = try store.createProperty(Property(id: UUID(), orgId: UUID(), name: "Remote Property"))
        let appState = AppState(
            localStore: store,
            userDefaults: makeEmptyDefaults(),
            environment: [:],
            disableCloudBackupForTests: true
        )
        appState.properties = [property]
        appState.selectedPropertyID = property.id

        XCTAssertFalse(appState.manualSessionSnapshotTestSessionCreationAvailability.isAvailable)
        let result = appState.createManualSessionSnapshotTestSessionForLocalDev()
        XCTAssertFalse(result.created)
        XCTAssertTrue(appState.sessions(for: property.id).isEmpty)
    }
}
