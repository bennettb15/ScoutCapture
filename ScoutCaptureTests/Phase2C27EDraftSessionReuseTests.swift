import XCTest
@testable import ScoutCapture

@MainActor
final class Phase2C27EDraftSessionReuseTests: XCTestCase {
    private struct Fixture {
        let suiteName: String
        let defaults: UserDefaults
        let storageRoot: URL
        let localStore: LocalStore
        let appState: AppState
        let property: Property
    }

    private func makeFixture() throws -> Fixture {
        let suiteName = "Phase2C27EDraftSessionReuseTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(false, forKey: "supabase_enabled")
        defaults.set(false, forKey: "shadow_write_enabled")
        defaults.set(false, forKey: "supabase_read_enabled")
        defaults.set(false, forKey: "supabase_property_read_enabled")
        defaults.set(false, forKey: "media_supabase_upload_enabled")

        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScoutCapture-2C27E-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)

        let localStore = LocalStore(testStorageRootURL: storageRoot)
        let orgID = UUID()
        _ = try localStore.createOrganization(Organization(id: orgID, name: "Draft Reuse Org"))
        let property = try localStore.createProperty(
            Property(
                orgId: orgID,
                folderId: "draft-reuse",
                name: "Draft Reuse",
                address: "100 Draft Way"
            )
        )
        let appState = AppState(localStore: localStore, userDefaults: defaults)
        appState._debugRefreshPropertiesLocallyForTests()

        return Fixture(
            suiteName: suiteName,
            defaults: defaults,
            storageRoot: storageRoot,
            localStore: localStore,
            appState: appState,
            property: property
        )
    }

    private func tearDownFixture(_ fixture: Fixture) {
        fixture.defaults.removePersistentDomain(forName: fixture.suiteName)
        try? FileManager.default.removeItem(at: fixture.storageRoot)
    }

    func testPropertyReopenReusesPersistedDraft() throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        fixture.appState.selectProperty(id: fixture.property.id)
        let first = try XCTUnwrap(fixture.appState.startSession())
        fixture.appState.clearCurrentSession()

        fixture.appState.selectProperty(id: fixture.property.id)
        let reopened = try XCTUnwrap(fixture.appState.startSession())

        XCTAssertEqual(reopened.id, first.id)
        XCTAssertEqual(try fixture.localStore.fetchSessions(propertyID: fixture.property.id).count, 1)
        let diagnostics = fixture.appState._debugLocalDiagnosticsForTests().sessionSnapshotUpload
        XCTAssertEqual(diagnostics.lastDraftReuseDecision, "reuse_persisted_draft")
        XCTAssertFalse(diagnostics.lastDraftDuplicateDetected)
    }

    func testForegroundRefreshReusesDraftAfterCacheRebuild() throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        fixture.appState.selectProperty(id: fixture.property.id)
        let first = try XCTUnwrap(fixture.appState.startSession())
        fixture.appState.clearCurrentSession()
        fixture.appState._debugRefreshPropertiesLocallyForTests()

        fixture.appState.selectProperty(id: fixture.property.id)
        let reopened = try XCTUnwrap(fixture.appState.startSession())

        XCTAssertEqual(reopened.id, first.id)
        XCTAssertEqual(
            fixture.appState._debugLocalDiagnosticsForTests()
                .sessionSnapshotUpload
                .lastDraftForegroundRefreshReconciliation,
            "persisted_draft_reattached"
        )
    }

    func testDuplicateDraftCreationLoopIsPrevented() throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        fixture.appState.selectProperty(id: fixture.property.id)
        let first = try XCTUnwrap(fixture.appState.startSession())
        let second = try XCTUnwrap(fixture.appState.startSession())
        fixture.appState.clearCurrentSession()
        let third = try XCTUnwrap(fixture.appState.startSession())

        XCTAssertEqual(second.id, first.id)
        XCTAssertEqual(third.id, first.id)
        XCTAssertEqual(try fixture.localStore.fetchSessions(propertyID: fixture.property.id).count, 1)
        XCTAssertEqual(
            fixture.appState._debugLocalDiagnosticsForTests()
                .sessionSnapshotUpload
                .lastDraftReuseDecision,
            "reuse_persisted_draft"
        )
    }

    func testCompletedAndSealedSessionsDoNotReuseIncorrectly() throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        let completed = Session(
            propertyID: fixture.property.id,
            startedAt: Date().addingTimeInterval(-300),
            status: .completed,
            endedAt: Date().addingTimeInterval(-120),
            isSealed: true
        )
        let sealedDraft = Session(
            propertyID: fixture.property.id,
            startedAt: Date().addingTimeInterval(-60),
            status: .draft,
            isSealed: true
        )
        _ = try fixture.localStore.upsertSession(completed)
        _ = try fixture.localStore.upsertSession(sealedDraft)
        fixture.appState._debugRefreshPropertiesLocallyForTests()

        fixture.appState.selectProperty(id: fixture.property.id)
        let newDraft = try XCTUnwrap(fixture.appState.startSession())

        XCTAssertNotEqual(newDraft.id, completed.id)
        XCTAssertNotEqual(newDraft.id, sealedDraft.id)
        XCTAssertEqual(newDraft.status, .draft)
        XCTAssertFalse(newDraft.isSealed)
        XCTAssertEqual(
            fixture.appState._debugLocalDiagnosticsForTests()
                .sessionSnapshotUpload
                .lastDraftReuseBlockedReason,
            "no_reusable_active_draft_completed_or_sealed_sessions_only"
        )
    }

    func testMissingOrStaleDraftCreatesNewSessionAppropriately() throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        let stale = Session(
            propertyID: fixture.property.id,
            startedAt: Date().addingTimeInterval(-60),
            status: .draft,
            deletedAt: Date()
        )
        _ = try fixture.localStore.upsertSession(stale)
        fixture.appState._debugRefreshPropertiesLocallyForTests()

        fixture.appState.selectProperty(id: fixture.property.id)
        let newDraft = try XCTUnwrap(fixture.appState.startSession())

        XCTAssertNotEqual(newDraft.id, stale.id)
        XCTAssertEqual(newDraft.status, .draft)
        XCTAssertEqual(
            try fixture.localStore.fetchSessions(propertyID: fixture.property.id)
                .filter { $0.deletedAt == nil && $0.status == .draft }
                .map(\.id),
            [newDraft.id]
        )
    }

    func testExistingDuplicateDraftsAreDetectedButPreserved() throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        let older = Session(
            propertyID: fixture.property.id,
            startedAt: Date().addingTimeInterval(-120),
            status: .draft
        )
        let newer = Session(
            propertyID: fixture.property.id,
            startedAt: Date().addingTimeInterval(-60),
            status: .draft
        )
        _ = try fixture.localStore.upsertSession(older)
        _ = try fixture.localStore.upsertSession(newer)
        fixture.appState._debugRefreshPropertiesLocallyForTests()

        fixture.appState.selectProperty(id: fixture.property.id)
        let reused = try XCTUnwrap(fixture.appState.startSession())

        XCTAssertEqual(reused.id, newer.id)
        XCTAssertEqual(try fixture.localStore.fetchSessions(propertyID: fixture.property.id).count, 2)
        let diagnostics = fixture.appState._debugLocalDiagnosticsForTests().sessionSnapshotUpload
        XCTAssertEqual(diagnostics.lastDraftReuseCandidateCount, 2)
        XCTAssertTrue(diagnostics.lastDraftDuplicateDetected)
        XCTAssertEqual(diagnostics.lastDraftReuseDecision, "reuse_persisted_draft")
    }
}
