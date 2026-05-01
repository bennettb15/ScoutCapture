import XCTest
import Supabase
@testable import ScoutCapture

@MainActor
final class Phase2C13AActivityFeedTests: XCTestCase {
    private struct Fixture {
        let suiteName: String
        let defaults: UserDefaults
        let storageRoot: URL
        let appState: AppState
    }

    private func makeFixture() throws -> Fixture {
        let suiteName = "Phase2C13AActivityFeedTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(true, forKey: "supabase_enabled")
        defaults.set(false, forKey: "shadow_write_enabled")
        defaults.set(false, forKey: "supabase_read_enabled")
        defaults.set(false, forKey: "supabase_property_read_enabled")
        defaults.set(false, forKey: "media_supabase_upload_enabled")
        defaults.set(false, forKey: "sync_delta_enabled")

        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScoutCapture-2C13A-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)

        return Fixture(
            suiteName: suiteName,
            defaults: defaults,
            storageRoot: storageRoot,
            appState: AppState(
                localStore: LocalStore(testStorageRootURL: storageRoot),
                userDefaults: defaults
            )
        )
    }

    private func tearDownFixture(_ fixture: Fixture) {
        fixture.defaults.removePersistentDomain(forName: fixture.suiteName)
        try? FileManager.default.removeItem(at: fixture.storageRoot)
    }

    func testKnownSessionStartedEventMapsToReadableTitleAndPropertySubtitle() {
        let fixture = try! makeFixture()
        defer { tearDownFixture(fixture) }

        let item = fixture.appState._debugMakeActivityFeedItemForTests(
            event: AppState.DebugActivityFeedEventInput(
                id: UUID(),
                orgID: UUID(),
                sessionID: UUID(),
                eventType: "session.started",
                payload: [:],
                createdAt: Date(timeIntervalSinceReferenceDate: 100)
            ),
            propertyID: UUID(),
            propertyName: "ALDI"
        )

        XCTAssertEqual(item.displayTitle, "Session started")
        XCTAssertEqual(item.displaySubtitle, "For ALDI")
    }

    func testMemberRevokedEventUsesActorAndSubjectFallbacks() {
        let fixture = try! makeFixture()
        defer { tearDownFixture(fixture) }

        let item = fixture.appState._debugMakeActivityFeedItemForTests(
            event: AppState.DebugActivityFeedEventInput(
                id: UUID(),
                orgID: UUID(),
                sessionID: UUID(),
                eventType: "member.revoked",
                payload: [
                    "actor_name": "Brian",
                    "member_email": "john@example.com"
                ],
                createdAt: Date(timeIntervalSinceReferenceDate: 200)
            )
        )

        XCTAssertEqual(item.displayTitle, "Member revoked")
        XCTAssertEqual(item.displaySubtitle, "Brian revoked john@example.com")
    }

    func testUnknownEventFallsBackToRawEventTypeAndSessionIdentifier() {
        let fixture = try! makeFixture()
        defer { tearDownFixture(fixture) }
        let sessionID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

        let item = fixture.appState._debugMakeActivityFeedItemForTests(
            event: AppState.DebugActivityFeedEventInput(
                id: UUID(),
                orgID: UUID(),
                sessionID: sessionID,
                eventType: "custom.audit.event",
                payload: [:],
                createdAt: Date(timeIntervalSinceReferenceDate: 300)
            )
        )

        XCTAssertEqual(item.displayTitle, "custom.audit.event")
        XCTAssertEqual(item.displaySubtitle, "Session AAAAAAAA")
    }

    func testFetchActivityFeedOverrideReceivesOrgPropertyAndLimit() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        let orgID = UUID()
        let propertyID = UUID()
        let sessionID = UUID()
        var capturedOrgID: UUID?
        var capturedPropertyID: UUID?
        var capturedLimit: Int?

        fixture.appState._debugSetActivityFeedFetchOverrideForTests { overrideOrgID, overridePropertyID, overrideLimit in
            capturedOrgID = overrideOrgID
            capturedPropertyID = overridePropertyID
            capturedLimit = overrideLimit
            return [
                AppState.ActivityFeedItem(
                    id: UUID(),
                    orgID: overrideOrgID,
                    sessionID: sessionID,
                    eventType: "session.started",
                    payload: [:],
                    createdAt: Date(timeIntervalSinceReferenceDate: 400),
                    displayTitle: "Session started",
                    displaySubtitle: "For ALDI"
                )
            ]
        }

        let items = try await fixture.appState.fetchActivityFeed(
            orgID: orgID,
            propertyID: propertyID,
            limit: 25
        )

        XCTAssertEqual(capturedOrgID, orgID)
        XCTAssertEqual(capturedPropertyID, propertyID)
        XCTAssertEqual(capturedLimit, 25)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.displayTitle, "Session started")
    }
}
