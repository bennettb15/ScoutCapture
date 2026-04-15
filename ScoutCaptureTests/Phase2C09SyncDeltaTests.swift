import XCTest
@testable import ScoutCapture

final class Phase2C09SyncDeltaTests: XCTestCase {
    private struct Fixture {
        let defaultsSuiteName: String
        let storageRoot: URL
        let defaults: UserDefaults
        let localStore: LocalStore
        let appState: AppState
    }

    private func makeDefaultsSuite() -> (suiteName: String, defaults: UserDefaults) {
        let suite = "Phase2C09SyncDeltaTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return (suite, defaults)
    }

    private func makeTempStorageRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScoutCapture-2C09-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeFixture(
        supabaseEnabled: Bool = false,
        shadowWriteEnabled: Bool = false,
        syncDeltaEnabled: Bool = false
    ) throws -> Fixture {
        let defaultsFixture = makeDefaultsSuite()
        let defaults = defaultsFixture.defaults
        defaults.set(supabaseEnabled, forKey: "supabase_enabled")
        defaults.set(shadowWriteEnabled, forKey: "shadow_write_enabled")
        defaults.set(false, forKey: "supabase_read_enabled")
        defaults.set(false, forKey: "supabase_property_read_enabled")
        defaults.set(false, forKey: "media_supabase_upload_enabled")
        defaults.set(syncDeltaEnabled, forKey: "sync_delta_enabled")

        let storageRoot = try makeTempStorageRoot()
        let localStore = LocalStore(testStorageRootURL: storageRoot)
        let appState = AppState(localStore: localStore, userDefaults: defaults)
        return Fixture(
            defaultsSuiteName: defaultsFixture.suiteName,
            storageRoot: storageRoot,
            defaults: defaults,
            localStore: localStore,
            appState: appState
        )
    }

    private func tearDownFixture(_ fixture: Fixture) {
        fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuiteName)
        try? FileManager.default.removeItem(at: fixture.storageRoot)
    }

    private func makeOrganization(_ fixture: Fixture, id: UUID) throws {
        _ = try fixture.localStore.createOrganization(Organization(id: id, name: "Org \(id.uuidString.prefix(4))"))
    }

    private func refresh(_ appState: AppState) async {
        await MainActor.run {
            appState.refreshProperties()
        }
    }

    private func configureOrganizationContext(
        _ appState: AppState,
        orgID: UUID
    ) async {
        await MainActor.run {
            appState._debugSetOrganizationContextForTests(
                memberships: [
                    ActiveOrganizationMembership(
                        id: orgID,
                        name: "Test Org",
                        role: "owner"
                    )
                ],
                activeOrganizationID: orgID,
                ready: true
            )
        }
    }

    private func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func makePropertyDelta(
        id: UUID = UUID(),
        orgID: UUID,
        name: String = "Remote Property",
        createdAt: Date,
        updatedAt: Date,
        deletedAt: Date? = nil,
        isArchived: Bool = false
    ) -> AppState.DebugRemotePropertyDeltaInput {
        AppState.DebugRemotePropertyDeltaInput(
            id: id,
            orgID: orgID,
            folderID: "00001",
            clientName: "Client",
            clientEmail: "client@example.com",
            clientPhone: "5551234567",
            name: name,
            addressLine1: "123 Main Street",
            city: "Atlanta",
            state: "GA",
            postalCode: "30301",
            baselineSessionID: nil,
            isArchived: isArchived,
            createdAt: createdAt,
            updatedAt: updatedAt,
            deletedAt: deletedAt
        )
    }

    private func makeSessionDelta(
        id: UUID = UUID(),
        orgID: UUID,
        propertyID: UUID,
        status: String = "completed",
        startedAt: Date,
        completedAt: Date? = nil,
        updatedAt: Date,
        deletedAt: Date? = nil
    ) -> AppState.DebugRemoteSessionDeltaInput {
        AppState.DebugRemoteSessionDeltaInput(
            id: id,
            orgID: orgID,
            propertyID: propertyID,
            title: "Remote Session",
            status: status,
            startedAt: iso8601(startedAt),
            completedAt: completedAt.map { iso8601($0) },
            updatedAt: updatedAt,
            deletedAt: deletedAt
        )
    }

    func testDeltaCursorNilOnFirstPull() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }
        let orgID = UUID()

        let propertyCursor = await MainActor.run {
            fixture.appState._debugReadSyncCursorForTests(entity: "properties", orgID: orgID)
        }
        let sessionCursor = await MainActor.run {
            fixture.appState._debugReadSyncCursorForTests(entity: "sessions", orgID: orgID)
        }

        XCTAssertNil(propertyCursor)
        XCTAssertNil(sessionCursor)
    }

    func testDeltaCursorAdvancesAfterApply() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }
        let orgID = UUID()
        let updatedAt1 = Date(timeIntervalSinceReferenceDate: 100)
        let updatedAt2 = Date(timeIntervalSinceReferenceDate: 200)

        await MainActor.run {
            fixture.appState._debugAdvanceSyncCursorForTests(
                entity: "properties",
                orgID: orgID,
                updatedAts: [updatedAt1, updatedAt2]
            )
        }

        let cursor = await MainActor.run {
            fixture.appState._debugReadSyncCursorForTests(entity: "properties", orgID: orgID)
        }
        XCTAssertEqual(cursor, updatedAt2)
    }

    func testDeltaCursorDoesNotAdvanceOnEmptyBatch() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }
        let orgID = UUID()
        let original = Date(timeIntervalSinceReferenceDate: 100)

        await MainActor.run {
            fixture.appState._debugWriteSyncCursorForTests(entity: "properties", orgID: orgID, date: original)
            fixture.appState._debugAdvanceSyncCursorForTests(entity: "properties", orgID: orgID, updatedAts: [])
        }

        let cursor = await MainActor.run {
            fixture.appState._debugReadSyncCursorForTests(entity: "properties", orgID: orgID)
        }
        XCTAssertEqual(cursor, original)
    }

    func testDeltaCursorNeverRegresses() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }
        let orgID = UUID()
        let newer = Date(timeIntervalSinceReferenceDate: 300)
        let older = Date(timeIntervalSinceReferenceDate: 100)

        await MainActor.run {
            fixture.appState._debugWriteSyncCursorForTests(entity: "sessions", orgID: orgID, date: newer)
            fixture.appState._debugAdvanceSyncCursorForTests(entity: "sessions", orgID: orgID, updatedAts: [older])
        }

        let cursor = await MainActor.run {
            fixture.appState._debugReadSyncCursorForTests(entity: "sessions", orgID: orgID)
        }
        XCTAssertEqual(cursor, newer)
    }

    func testDeltaApplySkipsLocalNewerProperty() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }
        let orgID = UUID()
        let propertyID = UUID()
        try makeOrganization(fixture, id: orgID)

        let localProperty = Property(
            id: propertyID,
            orgId: orgID,
            folderId: "00001",
            clientName: "Local Client",
            name: "Local Property",
            address: "123 Local Street",
            street: "123 Local Street",
            city: "Boston",
            state: "MA",
            zip: "02110",
            createdAt: Date(timeIntervalSinceReferenceDate: 100),
            updatedAt: Date(timeIntervalSinceReferenceDate: 300)
        )
        _ = try fixture.localStore.createProperty(localProperty)
        await refresh(fixture.appState)
        await configureOrganizationContext(fixture.appState, orgID: orgID)

        let result = await MainActor.run {
            fixture.appState._debugApplySyncDeltaPropertiesForTests(
                records: [
                    makePropertyDelta(
                        id: propertyID,
                        orgID: orgID,
                        name: "Remote Older",
                        createdAt: Date(timeIntervalSinceReferenceDate: 100),
                        updatedAt: Date(timeIntervalSinceReferenceDate: 200)
                    )
                ],
                orgID: orgID
            )
        }

        let persisted = try fixture.localStore.fetchProperties().first(where: { $0.id == propertyID })
        XCTAssertEqual(result.applied, 0)
        XCTAssertEqual(result.skipped, 1)
        XCTAssertEqual(persisted?.name, "Local Property")
    }

    func testDeltaApplyUpsertsRemoteNewerProperty() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }
        let orgID = UUID()
        let propertyID = UUID()
        let createdAt = Date(timeIntervalSinceReferenceDate: 100)
        let remoteUpdatedAt = Date(timeIntervalSinceReferenceDate: 400)
        try makeOrganization(fixture, id: orgID)

        _ = try fixture.localStore.createProperty(
            Property(
                id: propertyID,
                orgId: orgID,
                folderId: "00001",
                clientName: "Local Client",
                name: "Old Name",
                address: "123 Local Street",
                street: "123 Local Street",
                city: "Boston",
                state: "MA",
                zip: "02110",
                createdAt: createdAt,
                updatedAt: Date(timeIntervalSinceReferenceDate: 200)
            )
        )
        await refresh(fixture.appState)
        await configureOrganizationContext(fixture.appState, orgID: orgID)

        let result = await MainActor.run {
            fixture.appState._debugApplySyncDeltaPropertiesForTests(
                records: [
                    makePropertyDelta(
                        id: propertyID,
                        orgID: orgID,
                        name: "Remote New Name",
                        createdAt: Date(timeIntervalSinceReferenceDate: 50),
                        updatedAt: remoteUpdatedAt
                    )
                ],
                orgID: orgID
            )
        }

        let persisted = try fixture.localStore.fetchProperties().first(where: { $0.id == propertyID })
        XCTAssertEqual(result.applied, 1)
        XCTAssertEqual(result.skipped, 0)
        XCTAssertEqual(persisted?.name, "Remote New Name")
        XCTAssertEqual(persisted?.createdAt, createdAt)
        XCTAssertEqual(persisted?.updatedAt, remoteUpdatedAt)
    }

    func testDeltaApplyIdempotentProperty() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }
        let orgID = UUID()
        let propertyID = UUID()
        try makeOrganization(fixture, id: orgID)
        await refresh(fixture.appState)
        await configureOrganizationContext(fixture.appState, orgID: orgID)

        let record = makePropertyDelta(
            id: propertyID,
            orgID: orgID,
            name: "Idempotent Property",
            createdAt: Date(timeIntervalSinceReferenceDate: 100),
            updatedAt: Date(timeIntervalSinceReferenceDate: 200)
        )

        let first = await MainActor.run {
            fixture.appState._debugApplySyncDeltaPropertiesForTests(records: [record], orgID: orgID)
        }
        let second = await MainActor.run {
            fixture.appState._debugApplySyncDeltaPropertiesForTests(records: [record], orgID: orgID)
        }

        let persisted = try fixture.localStore.fetchProperties().filter { $0.id == propertyID }
        XCTAssertEqual(first.applied, 1)
        XCTAssertEqual(second.applied, 0)
        XCTAssertEqual(second.skipped, 1)
        XCTAssertEqual(persisted.count, 1)
    }

    func testDeltaApplyMaintainsPropertyOrdering() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }
        let orgID = UUID()
        let propertyB = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let propertyA = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        try makeOrganization(fixture, id: orgID)

        _ = try fixture.localStore.createProperty(
            Property(
                id: propertyB,
                orgId: orgID,
                folderId: "00002",
                name: "Later",
                createdAt: Date(timeIntervalSinceReferenceDate: 300),
                updatedAt: Date(timeIntervalSinceReferenceDate: 300)
            )
        )
        await refresh(fixture.appState)
        await configureOrganizationContext(fixture.appState, orgID: orgID)

        _ = await MainActor.run {
            fixture.appState._debugApplySyncDeltaPropertiesForTests(
                records: [
                    makePropertyDelta(
                        id: propertyA,
                        orgID: orgID,
                        name: "Earlier",
                        createdAt: Date(timeIntervalSinceReferenceDate: 100),
                        updatedAt: Date(timeIntervalSinceReferenceDate: 400)
                    ),
                    makePropertyDelta(
                        id: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!,
                        orgID: orgID,
                        name: "Tie Breaker",
                        createdAt: Date(timeIntervalSinceReferenceDate: 300),
                        updatedAt: Date(timeIntervalSinceReferenceDate: 500)
                    )
                ],
                orgID: orgID
            )
        }

        let orderedIDs = await MainActor.run {
            fixture.appState._debugAllPropertiesForTests()
                .filter { $0.orgId == orgID }
                .map(\.id)
        }
        XCTAssertEqual(
            orderedIDs,
            [
                propertyA,
                propertyB,
                UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
            ]
        )
    }

    func testDeltaApplySoftDeleteArchivesProperty() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }
        let orgID = UUID()
        let propertyID = UUID()
        try makeOrganization(fixture, id: orgID)

        _ = try fixture.localStore.createProperty(
            Property(
                id: propertyID,
                orgId: orgID,
                folderId: "00001",
                name: "Archive Me",
                isArchived: false,
                createdAt: Date(timeIntervalSinceReferenceDate: 100),
                updatedAt: Date(timeIntervalSinceReferenceDate: 200)
            )
        )
        await refresh(fixture.appState)
        await configureOrganizationContext(fixture.appState, orgID: orgID)

        let result = await MainActor.run {
            fixture.appState._debugApplySyncDeltaPropertiesForTests(
                records: [
                    makePropertyDelta(
                        id: propertyID,
                        orgID: orgID,
                        name: "Archive Me",
                        createdAt: Date(timeIntervalSinceReferenceDate: 100),
                        updatedAt: Date(timeIntervalSinceReferenceDate: 300),
                        deletedAt: Date(timeIntervalSinceReferenceDate: 300)
                    )
                ],
                orgID: orgID
            )
        }

        let persisted = try fixture.localStore.fetchProperties().first(where: { $0.id == propertyID })
        XCTAssertEqual(result.applied, 1)
        XCTAssertEqual(persisted?.isArchived, true)
    }

    func testDeltaApplySessionUpsertRemoteAuthoritative() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }
        let orgID = UUID()
        let propertyID = UUID()
        let sessionID = UUID()
        try makeOrganization(fixture, id: orgID)

        _ = try fixture.localStore.createProperty(
            Property(
                id: propertyID,
                orgId: orgID,
                folderId: "00001",
                name: "Session Property",
                createdAt: Date(timeIntervalSinceReferenceDate: 100),
                updatedAt: Date(timeIntervalSinceReferenceDate: 100)
            )
        )
        _ = try fixture.localStore.upsertSession(
            Session(
                id: sessionID,
                propertyID: propertyID,
                startedAt: Date(timeIntervalSinceReferenceDate: 100),
                status: .draft
            )
        )
        await refresh(fixture.appState)
        await configureOrganizationContext(fixture.appState, orgID: orgID)

        let result = await MainActor.run {
            fixture.appState._debugApplySyncDeltaSessionsForTests(
                records: [
                    makeSessionDelta(
                        id: sessionID,
                        orgID: orgID,
                        propertyID: propertyID,
                        status: "completed",
                        startedAt: Date(timeIntervalSinceReferenceDate: 120),
                        completedAt: Date(timeIntervalSinceReferenceDate: 180),
                        updatedAt: Date(timeIntervalSinceReferenceDate: 200)
                    )
                ],
                orgID: orgID
            )
        }

        let persisted = try fixture.localStore.fetchSessions(propertyID: propertyID).first(where: { $0.id == sessionID })
        XCTAssertEqual(result.applied, 1)
        XCTAssertEqual(persisted?.status, .completed)
        XCTAssertEqual(persisted?.startedAt, Date(timeIntervalSinceReferenceDate: 120))
        XCTAssertEqual(persisted?.endedAt, Date(timeIntervalSinceReferenceDate: 180))
    }

    func testDeltaApplySessionSkipsUnknownProperty() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }
        let orgID = UUID()

        let result = await MainActor.run {
            fixture.appState._debugApplySyncDeltaSessionsForTests(
                records: [
                    makeSessionDelta(
                        orgID: orgID,
                        propertyID: UUID(),
                        startedAt: Date(timeIntervalSinceReferenceDate: 100),
                        updatedAt: Date(timeIntervalSinceReferenceDate: 200)
                    )
                ],
                orgID: orgID
            )
        }

        XCTAssertEqual(result.applied, 0)
        XCTAssertEqual(result.skipped, 1)
    }

    func testDeltaApplySessionSkipsSoftDeleted() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }
        let orgID = UUID()
        let propertyID = UUID()
        try makeOrganization(fixture, id: orgID)

        _ = try fixture.localStore.createProperty(
            Property(
                id: propertyID,
                orgId: orgID,
                folderId: "00001",
                name: "Soft Delete Property",
                createdAt: Date(timeIntervalSinceReferenceDate: 100),
                updatedAt: Date(timeIntervalSinceReferenceDate: 100)
            )
        )
        await refresh(fixture.appState)
        await configureOrganizationContext(fixture.appState, orgID: orgID)

        let result = await MainActor.run {
            fixture.appState._debugApplySyncDeltaSessionsForTests(
                records: [
                    makeSessionDelta(
                        orgID: orgID,
                        propertyID: propertyID,
                        startedAt: Date(timeIntervalSinceReferenceDate: 100),
                        updatedAt: Date(timeIntervalSinceReferenceDate: 200),
                        deletedAt: Date(timeIntervalSinceReferenceDate: 200)
                    )
                ],
                orgID: orgID
            )
        }

        let persisted = try fixture.localStore.fetchSessions(propertyID: propertyID)
        XCTAssertEqual(result.applied, 0)
        XCTAssertEqual(result.skipped, 1)
        XCTAssertTrue(persisted.isEmpty)
    }

    func testSyncCursorClearOnOrgSwitch() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }
        let firstOrgID = UUID()
        let secondOrgID = UUID()
        let firstDate = Date(timeIntervalSinceReferenceDate: 100)
        let secondDate = Date(timeIntervalSinceReferenceDate: 200)

        await MainActor.run {
            fixture.appState._debugWriteSyncCursorForTests(entity: "properties", orgID: firstOrgID, date: firstDate)
            fixture.appState._debugWriteSyncCursorForTests(entity: "properties", orgID: secondOrgID, date: secondDate)
            fixture.appState._debugClearSyncCursorsForTests(orgID: firstOrgID)
        }

        let firstCursor = await MainActor.run {
            fixture.appState._debugReadSyncCursorForTests(entity: "properties", orgID: firstOrgID)
        }
        let secondCursor = await MainActor.run {
            fixture.appState._debugReadSyncCursorForTests(entity: "properties", orgID: secondOrgID)
        }

        XCTAssertNil(firstCursor)
        XCTAssertEqual(secondCursor, secondDate)
    }

    func testIsSyncDeltaEnabledGate() async throws {
        let disabledFixture = try makeFixture(supabaseEnabled: true, syncDeltaEnabled: false)
        defer { tearDownFixture(disabledFixture) }
        let enabledFixture = try makeFixture(supabaseEnabled: true, syncDeltaEnabled: true)
        defer { tearDownFixture(enabledFixture) }
        let orgID = UUID()

        await MainActor.run {
            disabledFixture.appState._debugSetSyncDeltaEnvironmentForTests(
                activeOrganizationID: orgID,
                ready: true,
                clientConfigured: true
            )
            enabledFixture.appState._debugSetSyncDeltaEnvironmentForTests(
                activeOrganizationID: orgID,
                ready: true,
                clientConfigured: true
            )
        }

        let disabled = await MainActor.run {
            disabledFixture.appState._debugIsSyncDeltaEnabledForTests()
        }
        let enabled = await MainActor.run {
            enabledFixture.appState._debugIsSyncDeltaEnabledForTests()
        }

        XCTAssertFalse(disabled)
        XCTAssertTrue(enabled)
    }

    func testInFlightGuardPreventsOverlap() async throws {
        let fixture = try makeFixture(supabaseEnabled: true, syncDeltaEnabled: true)
        defer { tearDownFixture(fixture) }
        let orgID = UUID()

        await MainActor.run {
            fixture.appState._debugSetSyncDeltaEnvironmentForTests(
                activeOrganizationID: orgID,
                ready: true,
                clientConfigured: true
            )
            fixture.appState._debugSetSyncDeltaPullInFlightForTests(true)
        }

        await MainActor.run {
            XCTAssertTrue(fixture.appState._debugIsSyncDeltaEnabledForTests())
        }
        await fixture.appState._debugPerformSyncDeltaPullForTests(source: "test_overlap")

        let stillInFlight = fixture.appState._debugIsSyncDeltaPullInFlightForTests()
        XCTAssertTrue(stillInFlight)
    }
}
