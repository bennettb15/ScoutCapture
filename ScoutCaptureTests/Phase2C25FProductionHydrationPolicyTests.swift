import XCTest
@testable import ScoutCapture

@MainActor
final class Phase2C25FProductionHydrationPolicyTests: XCTestCase {
    private struct Fixture {
        var store: LocalStore
        var appState: AppState
        var property: Property
        var session: Session
        var orgID: UUID
        var row: AppState.SessionSnapshotUploadRow
        var object: AppState.SessionSnapshotStorageObject
    }

    private func makeTempStorageRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScoutCapture-2C25F-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: "ScoutCapture-2C25F-\(UUID().uuidString)") ?? .standard
        defaults.set(true, forKey: "session_snapshot_shadow_write_enabled")
        return defaults
    }

    private func environment(
        url: String = "http://127.0.0.1:54321",
        hydrationAllowed: Bool = false
    ) -> [String: String] {
        var environment = [
            "SCOUTCAPTURE_SUPABASE_URL": url,
            "SCOUTCAPTURE_SUPABASE_ANON_KEY": "test-anon-key"
        ]
        if hydrationAllowed {
            environment["SCOUTCAPTURE_PRODUCTION_SNAPSHOT_HYDRATION_ALLOWED"] = "true"
        }
        return environment
    }

    private func makeFixture(
        environment: [String: String]? = nil,
        generatedAt: Date = Date(timeIntervalSinceReferenceDate: 1_000),
        rowTransform: ((AppState.SessionSnapshotUploadRow) -> AppState.SessionSnapshotUploadRow)? = nil,
        rowsFetch: ((AppState.SessionSnapshotUploadRow) -> [AppState.SessionSnapshotUploadRow])? = nil
    ) throws -> Fixture {
        let root = try makeTempStorageRoot()
        let store = LocalStore(testStorageRootURL: root)
        let orgID = UUID()
        _ = try store.createOrganization(Organization(id: orgID, name: "25F Hydration Policy Org"))
        let property = try store.createProperty(Property(id: UUID(), orgId: orgID, name: "25F Hydration Policy Property"))
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

        let artifactAppState = AppState(
            localStore: store,
            userDefaults: makeDefaults(),
            environment: self.environment(),
            sessionSnapshotStorageUploadOverride: { _ in },
            sessionSnapshotRowInsertOverride: { _ in },
            disableCloudBackupForTests: true
        )
        let artifacts = try artifactAppState._debugMakeSessionSnapshotUploadArtifactsForTests(
            propertyID: property.id,
            sessionID: session.id,
            generatedAt: generatedAt
        )
        let row = rowTransform?(artifacts.row) ?? artifacts.row
        let appState = AppState(
            localStore: store,
            userDefaults: makeDefaults(),
            environment: environment ?? self.environment(),
            sessionSnapshotRowsFetchOverride: { _, _, _ in rowsFetch?(row) ?? [row] },
            sessionSnapshotStorageDownloadOverride: { _, _ in artifacts.object.payloadData },
            sessionSnapshotRemoteParentPreflightOverride: { _, _, _ in
                AppState.SessionSnapshotAuthPreflightRemoteParentStatus(
                    propertyExists: true,
                    sessionExists: true,
                    propertyOrgID: orgID,
                    sessionOrgID: orgID,
                    sessionPropertyIDMatches: true,
                    orgIDsMatch: true,
                    errorMessage: nil
                )
            },
            disableCloudBackupForTests: true
        )
        appState.selectedPropertyID = property.id
        appState.currentSession = session
        return Fixture(
            store: store,
            appState: appState,
            property: property,
            session: session,
            orgID: orgID,
            row: row,
            object: artifacts.object
        )
    }

    private func saveMetadata(store: LocalStore, property: Property, session: Session, orgID: UUID) throws {
        let shotID = UUID()
        let issueID = UUID()
        let shot = ShotMetadata(
            shotID: shotID,
            propertyID: property.id,
            sessionID: session.id,
            createdAt: Date(timeIntervalSinceReferenceDate: 120),
            updatedAt: Date(timeIntervalSinceReferenceDate: 130),
            building: "A",
            elevation: "North",
            detailType: "Overview",
            angleIndex: 1,
            shotKey: "a-north-overview-1",
            isGuided: true,
            isFlagged: true,
            issueID: issueID,
            issueStatus: "active",
            noteText: "25F metadata hydration test",
            noteCategory: "general",
            originalFilename: "missing-original.jpg",
            originalRelativePath: "Originals/missing-original.jpg",
            originalByteSize: 123,
            storageBucket: "media",
            storagePath: "remote/media/path.jpg",
            checksumSHA256: String(repeating: "a", count: 64),
            byteSize: 123,
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
        let issue = IssueMetadata(
            issueID: issueID,
            issueStatus: "active",
            currentReason: "Needs repair",
            firstSeenAt: Date(timeIntervalSinceReferenceDate: 120),
            lastSeenAt: Date(timeIntervalSinceReferenceDate: 130),
            lastCaptureSessionId: session.id,
            detailNote: "25F hydrated issue",
            shotKey: shot.shotKey
        )
        let guided = GuidedShot(
            title: "North overview",
            building: "A",
            targetElevation: "North",
            detailType: "Overview",
            angleIndex: 1,
            referenceImagePath: "References/reference.jpg",
            shot: Shot(id: shotID, capturedAt: shot.createdAt),
            isCompleted: true
        )
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
            shots: [shot],
            issues: [issue],
            guidedShots: [guided]
        )
        try store.saveSessionMetadataAtomically(propertyID: property.id, sessionID: session.id, metadata: metadata)
    }

    private func rowWithChecksumMismatch(_ row: AppState.SessionSnapshotUploadRow) -> AppState.SessionSnapshotUploadRow {
        AppState.SessionSnapshotUploadRow(
            id: row.id,
            orgID: row.orgID,
            propertyID: row.propertyID,
            sessionID: row.sessionID,
            snapshotKind: row.snapshotKind,
            snapshotSchemaVersion: row.snapshotSchemaVersion,
            sessionMetadataSchemaVersion: row.sessionMetadataSchemaVersion,
            trigger: row.trigger,
            sessionStatus: row.sessionStatus,
            isSealed: row.isSealed,
            exportedAt: row.exportedAt,
            firstDeliveredAt: row.firstDeliveredAt,
            reExportExpiresAt: row.reExportExpiresAt,
            payloadStorageBucket: row.payloadStorageBucket,
            payloadStoragePath: row.payloadStoragePath,
            payloadByteSize: row.payloadByteSize,
            rawSessionJSONSHA256: row.rawSessionJSONSHA256,
            snapshotPayloadSHA256: String(repeating: "b", count: 64),
            manifest: row.manifest,
            shotCount: row.shotCount,
            issueCount: row.issueCount,
            guidedCount: row.guidedCount,
            mediaManifestCount: row.mediaManifestCount,
            missingLocalOriginalsCount: row.missingLocalOriginalsCount,
            supabaseStorageMetadataCount: row.supabaseStorageMetadataCount,
            createdBy: row.createdBy,
            updatedBy: row.updatedBy,
            createdAt: row.createdAt
        )
    }

    func testProductionHydrationBlockedByDefault() async throws {
        var didFetchRows = false
        let fixture = try makeFixture(
            environment: environment(url: "https://chlvazmtucoszicehtnm.supabase.co"),
            rowsFetch: { row in
                didFetchRows = true
                return [row]
            }
        )

        let result = await fixture.appState.hydrateMetadataFromLatestSessionSnapshot()

        XCTAssertFalse(result.allowed)
        XCTAssertEqual(result.blockedReason, "production_hydration_gate_disabled")
        XCTAssertFalse(didFetchRows)
        XCTAssertEqual(fixture.appState.localDiagnostics.sessionSnapshotUpload.hydrationMode, "blocked_by_default")
    }

    func testProductionRestoreDiagnosticsStillAllowedWithoutHydrationPermission() async throws {
        var didFetchRows = false
        let fixture = try makeFixture(
            environment: environment(url: "https://chlvazmtucoszicehtnm.supabase.co"),
            rowsFetch: { row in
                didFetchRows = true
                return [row]
            }
        )

        let diagnostics = await fixture.appState.validateLatestSessionSnapshotRestoreDiagnostics()

        XCTAssertTrue(didFetchRows)
        XCTAssertEqual(diagnostics.result, .restorableMetadataCandidate)
        XCTAssertTrue(diagnostics.checksumVerified)
        XCTAssertTrue(diagnostics.rowObjectVerified)
        XCTAssertTrue(diagnostics.parentRemoteVerified)
        XCTAssertNil(fixture.appState.localDiagnostics.sessionSnapshotUpload.lastHydrationAt)
    }

    func testProductionHydrationAllowedOnlyWithExplicitGate() async throws {
        let fixture = try makeFixture(
            environment: environment(
                url: "https://chlvazmtucoszicehtnm.supabase.co",
                hydrationAllowed: true
            )
        )

        let result = await fixture.appState.hydrateMetadataFromLatestSessionSnapshot()

        XCTAssertTrue(result.allowed)
        XCTAssertEqual(result.sessionID, fixture.session.id)
        XCTAssertEqual(fixture.appState.localDiagnostics.sessionSnapshotUpload.productionHydrationAllowed, true)
        XCTAssertEqual(fixture.appState.localDiagnostics.sessionSnapshotUpload.hydrationMode, "operator_approved_single_session")
        XCTAssertEqual(fixture.appState.localDiagnostics.sessionSnapshotUpload.hydrationScope, "single_selected_session")
    }

    func testProductionHydrationStillBlocksIfRestoreResultIsNotCandidate() async throws {
        let fixture = try makeFixture(
            environment: environment(
                url: "https://chlvazmtucoszicehtnm.supabase.co",
                hydrationAllowed: true
            ),
            rowTransform: rowWithChecksumMismatch
        )

        let result = await fixture.appState.hydrateMetadataFromLatestSessionSnapshot()

        XCTAssertFalse(result.allowed)
        XCTAssertEqual(result.blockedReason, "checksum_failed")
    }

    func testLocalNewerConflictBlocksEvenWhenProductionGateIsTrue() async throws {
        let fixture = try makeFixture(
            environment: environment(
                url: "https://chlvazmtucoszicehtnm.supabase.co",
                hydrationAllowed: true
            ),
            generatedAt: Date(timeIntervalSinceReferenceDate: 1_000)
        )
        let newerSession = Session(
            id: fixture.session.id,
            propertyID: fixture.property.id,
            startedAt: fixture.session.startedAt,
            status: .completed,
            endedAt: Date(timeIntervalSinceReferenceDate: 2_000),
            exportedAt: nil,
            isSealed: true,
            firstDeliveredAt: nil,
            reExportExpiresAt: nil
        )
        _ = try fixture.store.upsertSession(newerSession)
        try saveMetadata(store: fixture.store, property: fixture.property, session: newerSession, orgID: fixture.orgID)
        fixture.appState.currentSession = newerSession

        let result = await fixture.appState.hydrateMetadataFromLatestSessionSnapshot()

        XCTAssertFalse(result.allowed)
        XCTAssertEqual(result.blockedReason, "local_newer_conflict")
    }

    func testRandomRemoteRemainsBlocked() async throws {
        let fixture = try makeFixture(
            environment: environment(
                url: "https://example.supabase.co",
                hydrationAllowed: true
            )
        )

        let result = await fixture.appState.hydrateMetadataFromLatestSessionSnapshot()

        XCTAssertFalse(result.allowed)
        XCTAssertEqual(result.blockedReason, "unapproved_remote_hydration_disabled")
    }

    func testLocalHydrationBehaviorUnchangedAndDoesNotRestoreMedia() async throws {
        let fixture = try makeFixture()
        try fixture.store.deleteSession(id: fixture.session.id, propertyID: fixture.property.id)
        let mediaURL = fixture.store
            .sessionJSONURL(propertyID: fixture.property.id, sessionID: fixture.session.id)
            .deletingLastPathComponent()
            .appendingPathComponent("Originals/missing-original.jpg")

        let result = await fixture.appState.hydrateMetadataFromLatestSessionSnapshot()

        XCTAssertTrue(result.allowed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: mediaURL.path))
    }

    func testNoAutomaticRestorePathFromDiagnostics() async throws {
        let fixture = try makeFixture()

        _ = await fixture.appState.validateLatestSessionSnapshotRestoreDiagnostics()

        XCTAssertNil(fixture.appState.localDiagnostics.sessionSnapshotUpload.lastHydrationAt)
        XCTAssertFalse(fixture.appState.localDiagnostics.sessionSnapshotUpload.lastHydrationAllowed)
    }
}
