import XCTest
@testable import ScoutCapture

final class Phase2C14B3SessionDeletedAtReadSupportTests: XCTestCase {
    private struct Fixture {
        let defaultsSuiteName: String
        let storageRoot: URL
        let defaults: UserDefaults
        let localStore: LocalStore
        let appState: AppState
    }

    private func makeFixture() throws -> Fixture {
        let suiteName = "Phase2C14B3SessionDeletedAtReadSupportTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(false, forKey: "supabase_enabled")
        defaults.set(false, forKey: "shadow_write_enabled")
        defaults.set(false, forKey: "supabase_read_enabled")
        defaults.set(false, forKey: "supabase_property_read_enabled")
        defaults.set(false, forKey: "media_supabase_upload_enabled")
        defaults.set(true, forKey: "sync_delta_enabled")

        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScoutCapture-2C14B3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)

        let localStore = LocalStore(testStorageRootURL: storageRoot)
        let appState = AppState(localStore: localStore, userDefaults: defaults)
        return Fixture(
            defaultsSuiteName: suiteName,
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

    private func seedProperty(_ fixture: Fixture, orgID: UUID, propertyID: UUID) throws {
        _ = try fixture.localStore.createOrganization(Organization(id: orgID, name: "Org"))
        _ = try fixture.localStore.createProperty(
            Property(
                id: propertyID,
                orgId: orgID,
                folderId: "00001",
                name: "Session DeletedAt Property",
                address: "123 Main Street",
                street: "123 Main Street",
                city: "Atlanta",
                state: "GA",
                zip: "30301"
            )
        )
    }

    @MainActor
    private func prepareAppState(_ appState: AppState, orgID: UUID) {
        appState.refreshProperties()
        appState._debugSetOrganizationContextForTests(
            memberships: [
                ActiveOrganizationMembership(
                    id: orgID,
                    name: "Org",
                    role: "owner"
                )
            ],
            activeOrganizationID: orgID,
            ready: true
        )
    }

    private func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private func makeSessionDelta(
        id: UUID,
        orgID: UUID,
        propertyID: UUID,
        status: String = "completed",
        startedAt: Date,
        completedAt: Date? = nil,
        updatedAt: Date,
        deletedAt: Date?
    ) -> AppState.DebugRemoteSessionDeltaInput {
        AppState.DebugRemoteSessionDeltaInput(
            id: id,
            orgID: orgID,
            propertyID: propertyID,
            title: "Remote Session",
            status: status,
            startedAt: iso8601(startedAt),
            completedAt: completedAt.map(iso8601),
            updatedAt: updatedAt,
            deletedAt: deletedAt
        )
    }

    func testSessionDeletedAtDecodesNilWhenMissing() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "propertyID": "22222222-2222-2222-2222-222222222222",
          "startedAt": "2026-05-08T12:00:00Z",
          "status": "draft"
        }
        """.data(using: .utf8)!

        let session = try decoder.decode(Session.self, from: data)

        XCTAssertNil(session.deletedAt)
        XCTAssertEqual(session.status, .draft)
    }

    func testSessionDeletedAtEncodesAndDecodesWhenPresent() throws {
        let deletedAt = Date(timeIntervalSinceReferenceDate: 800)
        let session = Session(
            id: UUID(),
            propertyID: UUID(),
            startedAt: Date(timeIntervalSinceReferenceDate: 700),
            status: .completed,
            endedAt: Date(timeIntervalSinceReferenceDate: 750),
            exportedAt: Date(timeIntervalSinceReferenceDate: 760),
            isSealed: true,
            firstDeliveredAt: Date(timeIntervalSinceReferenceDate: 770),
            reExportExpiresAt: Date(timeIntervalSinceReferenceDate: 780),
            notes: "preserve me",
            deletedAt: deletedAt
        )
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let decoded = try decoder.decode(Session.self, from: encoder.encode(session))

        XCTAssertEqual(decoded.deletedAt, deletedAt)
        XCTAssertEqual(decoded.exportedAt, session.exportedAt)
        XCTAssertEqual(decoded.isSealed, true)
        XCTAssertEqual(decoded.firstDeliveredAt, session.firstDeliveredAt)
        XCTAssertEqual(decoded.reExportExpiresAt, session.reExportExpiresAt)
        XCTAssertEqual(decoded.notes, "preserve me")
    }

    func testRemoteDeletedAtAppliesWithoutHardDeletingLocalSession() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }
        let orgID = UUID()
        let propertyID = UUID()
        let sessionID = UUID()
        let deletedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        try seedProperty(fixture, orgID: orgID, propertyID: propertyID)
        await prepareAppState(fixture.appState, orgID: orgID)

        let result = await MainActor.run {
            fixture.appState._debugApplySyncDeltaSessionsForTests(
                records: [
                    makeSessionDelta(
                        id: sessionID,
                        orgID: orgID,
                        propertyID: propertyID,
                        startedAt: Date(timeIntervalSinceReferenceDate: 900),
                        completedAt: Date(timeIntervalSinceReferenceDate: 950),
                        updatedAt: Date(timeIntervalSinceReferenceDate: 1_010),
                        deletedAt: deletedAt
                    )
                ],
                orgID: orgID
            )
        }

        let rawSessions = try fixture.localStore.fetchSessionsForCacheBuild(propertyID: propertyID)
        let normalSessions = try fixture.localStore.fetchSessions(propertyID: propertyID)
        let recentlyDeleted = await MainActor.run {
            fixture.appState.recentlyDeletedSessions()
        }

        XCTAssertEqual(result.applied, 1)
        XCTAssertEqual(result.skipped, 0)
        XCTAssertEqual(rawSessions.first(where: { $0.id == sessionID })?.deletedAt, deletedAt)
        XCTAssertTrue(normalSessions.isEmpty)
        XCTAssertEqual(recentlyDeleted.map(\.id), [sessionID])
    }

    func testNormalSessionHelpersExcludeDeletedSessions() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }
        let orgID = UUID()
        let propertyID = UUID()
        let activeSessionID = UUID()
        let deletedSessionID = UUID()
        try seedProperty(fixture, orgID: orgID, propertyID: propertyID)

        _ = try fixture.localStore.upsertSession(
            Session(
                id: activeSessionID,
                propertyID: propertyID,
                startedAt: Date(timeIntervalSinceReferenceDate: 100),
                status: .completed
            )
        )
        _ = try fixture.localStore.upsertSession(
            Session(
                id: deletedSessionID,
                propertyID: propertyID,
                startedAt: Date(timeIntervalSinceReferenceDate: 200),
                status: .completed,
                deletedAt: Date(timeIntervalSinceReferenceDate: 300)
            )
        )
        await prepareAppState(fixture.appState, orgID: orgID)

        let normalIDs = await MainActor.run {
            fixture.appState.sessions(for: propertyID).map(\.id)
        }
        let recentlyDeletedIDs = await MainActor.run {
            fixture.appState.recentlyDeletedSessions().map(\.id)
        }

        XCTAssertEqual(normalIDs, [activeSessionID])
        XCTAssertEqual(recentlyDeletedIDs, [deletedSessionID])
    }

    func testDeletedPendingSessionDoesNotAppearInPendingExportHelper() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }
        let orgID = UUID()
        let propertyID = UUID()
        try seedProperty(fixture, orgID: orgID, propertyID: propertyID)
        _ = try fixture.localStore.upsertSession(
            Session(
                propertyID: propertyID,
                startedAt: Date(timeIntervalSinceReferenceDate: 400),
                status: .completed,
                endedAt: Date(timeIntervalSinceReferenceDate: 450),
                exportedAt: nil,
                isSealed: true,
                deletedAt: Date(timeIntervalSinceReferenceDate: 500)
            )
        )
        await prepareAppState(fixture.appState, orgID: orgID)

        let pending = await MainActor.run {
            fixture.appState.latestPendingExportSession(for: propertyID)
        }

        XCTAssertNil(pending)
    }
}
