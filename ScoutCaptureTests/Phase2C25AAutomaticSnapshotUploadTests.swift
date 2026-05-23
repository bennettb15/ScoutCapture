import XCTest
@testable import ScoutCapture

@MainActor
final class Phase2C25AAutomaticSnapshotUploadTests: XCTestCase {
    private func makeTempStorageRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScoutCapture-2C25A-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeDefaults(
        shadowWriteEnabled: Bool = true,
        autoUploadEnabled: Bool = false,
        orgAllowlist: [UUID] = [],
        propertyAllowlist: [UUID] = []
    ) -> UserDefaults {
        let defaults = UserDefaults(suiteName: "ScoutCapture-2C25A-\(UUID().uuidString)") ?? .standard
        defaults.set(shadowWriteEnabled, forKey: "session_snapshot_shadow_write_enabled")
        defaults.set(autoUploadEnabled, forKey: "session_snapshot_auto_upload_enabled")
        if !orgAllowlist.isEmpty {
            defaults.set(orgAllowlist.map(\.uuidString).joined(separator: ","), forKey: "session_snapshot_auto_upload_org_allowlist")
        }
        if !propertyAllowlist.isEmpty {
            defaults.set(propertyAllowlist.map(\.uuidString).joined(separator: ","), forKey: "session_snapshot_auto_upload_property_allowlist")
        }
        return defaults
    }

    private func localEnvironment(_ extras: [String: String] = [:]) -> [String: String] {
        var environment = [
            "SCOUTCAPTURE_SUPABASE_URL": "http://127.0.0.1:54321",
            "SCOUTCAPTURE_SUPABASE_ANON_KEY": "local-anon-key"
        ]
        extras.forEach { environment[$0.key] = $0.value }
        return environment
    }

    private func makeFixture(
        autoUploadEnabled: Bool = false,
        allowGeneratedOrg: Bool = false,
        orgAllowlist: [UUID] = [],
        propertyAllowlist: [UUID] = [],
        environmentExtras: [String: String] = [:],
        storageUploadOverride: AppState.SessionSnapshotStorageUploadOverride? = nil,
        rowInsertOverride: AppState.SessionSnapshotRowInsertOverride? = nil
    ) throws -> (store: LocalStore, appState: AppState, property: Property, session: Session, orgID: UUID) {
        let root = try makeTempStorageRoot()
        let store = LocalStore(testStorageRootURL: root)
        let orgID = UUID()
        _ = try store.createOrganization(Organization(id: orgID, name: "Automatic Snapshot Org"))
        let property = try store.createProperty(Property(id: UUID(), orgId: orgID, name: "Automatic Snapshot Property"))
        let session = try store.upsertSession(
            Session(
                id: UUID(),
                propertyID: property.id,
                startedAt: Date(timeIntervalSinceReferenceDate: 100),
                status: .completed,
                endedAt: Date(timeIntervalSinceReferenceDate: 200),
                exportedAt: nil,
                isSealed: true,
                firstDeliveredAt: nil,
                reExportExpiresAt: nil
            )
        )
        try saveMetadata(store: store, property: property, session: session, orgID: orgID)

        let appState = AppState(
            localStore: store,
            userDefaults: makeDefaults(
                autoUploadEnabled: autoUploadEnabled,
                orgAllowlist: allowGeneratedOrg ? [orgID] : orgAllowlist,
                propertyAllowlist: propertyAllowlist
            ),
            environment: localEnvironment(environmentExtras),
            sessionSnapshotStorageUploadOverride: storageUploadOverride ?? { _ in },
            sessionSnapshotRowInsertOverride: rowInsertOverride ?? { _ in },
            disableCloudBackupForTests: true
        )
        appState.selectedPropertyID = property.id
        return (store, appState, property, session, orgID)
    }

    private func saveMetadata(store: LocalStore, property: Property, session: Session, orgID: UUID) throws {
        let metadata = SessionMetadata(
            schemaVersion: 12,
            propertyID: property.id,
            sessionID: session.id,
            orgID: orgID,
            propertyNameAtCapture: property.name,
            propertyNameAtExport: nil,
            startedAt: session.startedAt,
            endedAt: session.endedAt,
            status: session.status,
            isBaselineSession: false,
            exportedAt: session.exportedAt,
            isSealed: session.isSealed,
            firstDeliveredAt: session.firstDeliveredAt,
            reExportExpiresAt: session.reExportExpiresAt,
            appVersion: "test-app",
            deviceModel: "test-device",
            osVersion: "test-os",
            shots: [],
            issues: [],
            guidedShots: []
        )
        try store.saveSessionMetadataAtomically(propertyID: property.id, sessionID: session.id, metadata: metadata)
    }

    func testAutoUploadDisabledByDefault() async throws {
        var attemptedStorageUpload = false
        let fixture = try makeFixture(
            storageUploadOverride: { _ in attemptedStorageUpload = true }
        )

        let result = await fixture.appState.attemptAutomaticSessionSnapshotUploadForCompletedSealedCheckpoint(
            session: fixture.session,
            triggerSource: "sealCurrentSessionForExportLater"
        )

        XCTAssertNil(result)
        XCTAssertFalse(attemptedStorageUpload)
        XCTAssertFalse(fixture.appState.backendFeatureFlags.sessionSnapshotAutoUploadEnabled)
        XCTAssertEqual(fixture.appState.localDiagnostics.sessionSnapshotUpload.autoUploadSkippedReason, "auto_upload_disabled")
    }

    func testEnableAloneDoesNotWorkWithoutAllowlist() async throws {
        var attemptedStorageUpload = false
        let fixture = try makeFixture(
            autoUploadEnabled: true,
            storageUploadOverride: { _ in attemptedStorageUpload = true }
        )

        let result = await fixture.appState.attemptAutomaticSessionSnapshotUploadForCompletedSealedCheckpoint(
            session: fixture.session,
            triggerSource: "sealCurrentSessionForExportLater"
        )

        XCTAssertNil(result)
        XCTAssertFalse(attemptedStorageUpload)
        XCTAssertTrue(fixture.appState.backendFeatureFlags.sessionSnapshotAutoUploadEnabled)
        XCTAssertEqual(fixture.appState.localDiagnostics.sessionSnapshotUpload.autoUploadSkippedReason, "allowlist_empty")
    }

    func testEnvironmentEnableAloneDoesNotCreateAllowlist() {
        let flags = BackendFeatureFlags.load(
            userDefaults: makeDefaults(autoUploadEnabled: false),
            environment: localEnvironment(["SCOUTCAPTURE_SESSION_SNAPSHOT_AUTO_UPLOAD_ENABLED": "true"])
        )

        XCTAssertTrue(flags.sessionSnapshotAutoUploadEnabled)
        XCTAssertFalse(flags.sessionSnapshotAutoUploadHasAllowlist)
    }

    func testKillSwitchDisablesEvenWhenFlagAndAllowlistMatch() async throws {
        var attemptedStorageUpload = false
        let fixture = try makeFixture(
            autoUploadEnabled: true,
            propertyAllowlist: [],
            environmentExtras: [
                "SCOUTCAPTURE_SESSION_SNAPSHOT_AUTO_UPLOAD_KILL_SWITCH": "true",
                "SCOUTCAPTURE_SESSION_SNAPSHOT_AUTO_UPLOAD_PROPERTY_ALLOWLIST": "placeholder"
            ],
            storageUploadOverride: { _ in attemptedStorageUpload = true }
        )
        let matchingDefaults = makeDefaults(
            autoUploadEnabled: true,
            propertyAllowlist: [fixture.property.id]
        )
        let matchingAppState = AppState(
            localStore: fixture.store,
            userDefaults: matchingDefaults,
            environment: localEnvironment(["SCOUTCAPTURE_SESSION_SNAPSHOT_AUTO_UPLOAD_KILL_SWITCH": "true"]),
            sessionSnapshotStorageUploadOverride: { _ in attemptedStorageUpload = true },
            sessionSnapshotRowInsertOverride: { _ in },
            disableCloudBackupForTests: true
        )

        let result = await matchingAppState.attemptAutomaticSessionSnapshotUploadForCompletedSealedCheckpoint(
            session: fixture.session,
            triggerSource: "sealCurrentSessionForExportLater"
        )

        XCTAssertNil(result)
        XCTAssertFalse(attemptedStorageUpload)
        XCTAssertTrue(matchingAppState.backendFeatureFlags.sessionSnapshotAutoUploadKillSwitch)
        XCTAssertEqual(matchingAppState.localDiagnostics.sessionSnapshotUpload.autoUploadSkippedReason, "kill_switch_active")
    }

    func testOrgAllowlistIsLoadedForGuardedAutoUpload() {
        let orgID = UUID()
        let flags = BackendFeatureFlags.load(
            userDefaults: makeDefaults(autoUploadEnabled: true, orgAllowlist: [orgID]),
            environment: localEnvironment()
        )

        XCTAssertTrue(flags.sessionSnapshotAutoUploadEnabled)
        XCTAssertTrue(flags.sessionSnapshotAutoUploadHasAllowlist)
        XCTAssertTrue(flags.sessionSnapshotAutoUploadOrgAllowlist.contains(orgID))
    }

    func testAllowedPropertyPermitsGuardedAutoPath() async throws {
        var insertCount = 0
        let fixture = try makeFixture(autoUploadEnabled: false)
        let appState = AppState(
            localStore: fixture.store,
            userDefaults: makeDefaults(autoUploadEnabled: true, propertyAllowlist: [fixture.property.id]),
            environment: localEnvironment(),
            sessionSnapshotStorageUploadOverride: { _ in },
            sessionSnapshotRowInsertOverride: { _ in insertCount += 1 },
            disableCloudBackupForTests: true
        )

        let result = await appState.attemptAutomaticSessionSnapshotUploadForCompletedSealedCheckpoint(
            session: fixture.session,
            triggerSource: "sealCurrentSessionForExportLater"
        )

        XCTAssertEqual(result?.outcome, .succeeded)
        XCTAssertEqual(insertCount, 1)
    }

    func testRandomPropertyAndOrgAreSkipped() async throws {
        var attemptedStorageUpload = false
        let fixture = try makeFixture(
            autoUploadEnabled: true,
            orgAllowlist: [UUID()],
            propertyAllowlist: [UUID()],
            storageUploadOverride: { _ in attemptedStorageUpload = true }
        )

        let result = await fixture.appState.attemptAutomaticSessionSnapshotUploadForCompletedSealedCheckpoint(
            session: fixture.session,
            triggerSource: "sealCurrentSessionForExportLater"
        )

        XCTAssertNil(result)
        XCTAssertFalse(attemptedStorageUpload)
        XCTAssertEqual(fixture.appState.localDiagnostics.sessionSnapshotUpload.autoUploadSkippedReason, "allowlist_no_match")
    }

    func testFailureIsNonBlockingAndDoesNotMutateLifecycleState() async throws {
        let fixture = try makeFixture(
            autoUploadEnabled: true,
            propertyAllowlist: []
        )
        let appState = AppState(
            localStore: fixture.store,
            userDefaults: makeDefaults(autoUploadEnabled: true, propertyAllowlist: [fixture.property.id]),
            environment: localEnvironment(),
            sessionSnapshotStorageUploadOverride: { _ in throw AppState.SessionSnapshotUploadError.remoteUnavailable("test bucket unavailable") },
            sessionSnapshotRowInsertOverride: { _ in XCTFail("row insert should not run after storage failure") },
            disableCloudBackupForTests: true
        )

        let result = await appState.attemptAutomaticSessionSnapshotUploadForCompletedSealedCheckpoint(
            session: fixture.session,
            triggerSource: "sealCurrentSessionForExportLater"
        )
        let persisted = try XCTUnwrap(try fixture.store.fetchSessionsForCacheBuild(propertyID: fixture.property.id).first)

        XCTAssertEqual(result?.outcome, .unavailable)
        XCTAssertEqual(appState.localDiagnostics.sessionSnapshotUpload.lastAutoUploadOutcome, "unavailable")
        XCTAssertEqual(persisted.status, .completed)
        XCTAssertTrue(persisted.isSealed)
        XCTAssertEqual(persisted.endedAt, fixture.session.endedAt)
        XCTAssertFalse(appState.backendFeatureFlags.supabaseReadEnabled)
        XCTAssertEqual(appState.localDiagnostics.sessionSnapshotUpload.lastReadbackStatus, "not_checked")
    }

    func testManualDiagnosticBehaviorUnchangedByAutoKillSwitch() async throws {
        var insertCount = 0
        let fixture = try makeFixture(
            autoUploadEnabled: true,
            propertyAllowlist: [],
            environmentExtras: ["SCOUTCAPTURE_SESSION_SNAPSHOT_AUTO_UPLOAD_KILL_SWITCH": "true"],
            rowInsertOverride: { _ in insertCount += 1 }
        )
        fixture.appState.selectedPropertyID = fixture.property.id

        let result = await fixture.appState.uploadSessionSnapshotShadowWrite(
            propertyID: fixture.property.id,
            sessionID: fixture.session.id,
            kind: .manual,
            trigger: "manual_diagnostic"
        )

        XCTAssertEqual(result.outcome, .succeeded)
        XCTAssertEqual(insertCount, 1)
        XCTAssertEqual(fixture.appState.localDiagnostics.sessionSnapshotUpload.lastKind, "manual")
        XCTAssertEqual(fixture.appState.localDiagnostics.sessionSnapshotUpload.lastTrigger, "manual_diagnostic")
    }

    func testProductionValidationRemainsManualOnlyForAutoUpload() async throws {
        var attemptedStorageUpload = false
        let fixture = try makeFixture(autoUploadEnabled: false)
        let productionEnvironment = [
            "SCOUTCAPTURE_SUPABASE_URL": "https://chlvazmtucoszicehtnm.supabase.co",
            "SCOUTCAPTURE_SUPABASE_ANON_KEY": "production-validation-anon-key",
            "SCOUTCAPTURE_PRODUCTION_SNAPSHOT_VALIDATION_ALLOWED": "true",
            "SCOUTCAPTURE_SESSION_SNAPSHOT_AUTO_UPLOAD_ENABLED": "true",
            "SCOUTCAPTURE_SESSION_SNAPSHOT_AUTO_UPLOAD_PROPERTY_ALLOWLIST": fixture.property.id.uuidString
        ]
        let appState = AppState(
            localStore: fixture.store,
            userDefaults: makeDefaults(autoUploadEnabled: false),
            environment: productionEnvironment,
            sessionSnapshotStorageUploadOverride: { _ in attemptedStorageUpload = true },
            sessionSnapshotRowInsertOverride: { _ in },
            disableCloudBackupForTests: true
        )

        let result = await appState.attemptAutomaticSessionSnapshotUploadForCompletedSealedCheckpoint(
            session: fixture.session,
            triggerSource: "sealCurrentSessionForExportLater"
        )

        XCTAssertNil(result)
        XCTAssertFalse(attemptedStorageUpload)
        XCTAssertEqual(appState.localDiagnostics.sessionSnapshotUpload.autoUploadSkippedReason, "production_validation_manual_only")
    }
}
