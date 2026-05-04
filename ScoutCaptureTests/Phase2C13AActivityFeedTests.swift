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
                actorUserID: nil,
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
                actorUserID: nil,
                eventType: "member.revoked",
                payload: [
                    "actor_name": "Brian",
                    "member_email": "john@example.com"
                ],
                createdAt: Date(timeIntervalSinceReferenceDate: 200)
            )
        )

        XCTAssertEqual(item.displayTitle, "Member revoked")
        XCTAssertEqual(item.displaySubtitle, "Brian revoked access for john@example.com")
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
                actorUserID: nil,
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

    func testFetchActivityFeedClampsLimitBeforeFetching() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        let orgID = UUID()
        var capturedLimits: [Int] = []

        fixture.appState._debugSetActivityFeedFetchOverrideForTests { _, _, overrideLimit in
            capturedLimits.append(overrideLimit)
            return []
        }

        _ = try await fixture.appState.fetchActivityFeed(orgID: orgID, limit: -10)
        _ = try await fixture.appState.fetchActivityFeed(orgID: orgID, limit: 0)
        _ = try await fixture.appState.fetchActivityFeed(orgID: orgID, limit: 50)
        _ = try await fixture.appState.fetchActivityFeed(orgID: orgID, limit: 250)

        XCTAssertEqual(capturedLimits, [1, 1, 50, 100])
    }

    func testActivityFeedMapperPreservesNewestFirstInputOrder() {
        let fixture = try! makeFixture()
        defer { tearDownFixture(fixture) }

        let orgID = UUID()
        let newestID = UUID()
        let olderID = UUID()
        let oldestID = UUID()

        let items = fixture.appState._debugMakeActivityFeedItemsForTests(events: [
            AppState.DebugActivityFeedEventInput(
                id: newestID,
                orgID: orgID,
                sessionID: nil,
                actorUserID: nil,
                eventType: "session.completed",
                payload: [:],
                createdAt: Date(timeIntervalSinceReferenceDate: 300)
            ),
            AppState.DebugActivityFeedEventInput(
                id: olderID,
                orgID: orgID,
                sessionID: nil,
                actorUserID: nil,
                eventType: "session.started",
                payload: [:],
                createdAt: Date(timeIntervalSinceReferenceDate: 200)
            ),
            AppState.DebugActivityFeedEventInput(
                id: oldestID,
                orgID: orgID,
                sessionID: nil,
                actorUserID: nil,
                eventType: "member.accepted",
                payload: [:],
                createdAt: Date(timeIntervalSinceReferenceDate: 100)
            )
        ])

        XCTAssertEqual(items.map(\.id), [newestID, olderID, oldestID])
    }

    func testBlankUnknownEventAndMalformedPayloadUseSafeFallbacks() {
        let fixture = try! makeFixture()
        defer { tearDownFixture(fixture) }

        let item = fixture.appState._debugMakeActivityFeedItemForTests(
            event: AppState.DebugActivityFeedEventInput(
                id: UUID(),
                orgID: UUID(),
                sessionID: nil,
                actorUserID: nil,
                eventType: "   ",
                payload: [
                    "actor_name": .object(["nested": .string("ignored")]),
                    "property_name": .array([.string("ignored")]),
                    "session_title": .null,
                    "target_user_id": .string("not-a-uuid")
                ],
                createdAt: Date(timeIntervalSinceReferenceDate: 700)
            )
        )

        XCTAssertEqual(item.displayTitle, "Activity event")
        XCTAssertEqual(item.displaySubtitle, "Organization activity")
        XCTAssertFalse(item.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertFalse(item.displaySubtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func testPropertyAccessGrantedUsesActorPropertyAndTargetContext() async {
        let fixture = try! makeFixture()
        defer { tearDownFixture(fixture) }

        let actorUserID = UUID()
        let targetUserID = UUID()
        let orgID = UUID()
        let propertyID = UUID()

        await fixture.appState._debugSetActiveOrganizationMembersForTests([
            OrganizationAccessMember(
                id: actorUserID,
                email: "brian@example.com",
                fullName: "Brian",
                role: "owner",
                accessScope: "org"
            ),
            OrganizationAccessMember(
                id: targetUserID,
                email: "target@example.com",
                fullName: nil,
                role: "viewer",
                accessScope: "property"
            )
        ])

        let item = fixture.appState._debugMakeActivityFeedItemForTests(
            event: AppState.DebugActivityFeedEventInput(
                id: UUID(),
                orgID: orgID,
                sessionID: nil,
                actorUserID: actorUserID,
                eventType: "property.access.granted",
                payload: [
                    "target_user_id": .string(targetUserID.uuidString.lowercased()),
                    "property_name": .string("ALDI")
                ],
                createdAt: Date(timeIntervalSinceReferenceDate: 500)
            ),
            propertyID: propertyID,
            propertyName: "ALDI"
        )

        XCTAssertEqual(item.displayTitle, "Property access granted")
        XCTAssertEqual(item.displaySubtitle, "Brian granted ALDI access to target@example.com")
    }

    func testMemberInvitedUsesActorRoleAndTargetEmailContext() async {
        let fixture = try! makeFixture()
        defer { tearDownFixture(fixture) }

        let actorUserID = UUID()
        let orgID = UUID()

        await fixture.appState._debugSetActiveOrganizationMembersForTests([
            OrganizationAccessMember(
                id: actorUserID,
                email: "brian@example.com",
                fullName: "Brian",
                role: "owner",
                accessScope: "org"
            )
        ])

        let item = fixture.appState._debugMakeActivityFeedItemForTests(
            event: AppState.DebugActivityFeedEventInput(
                id: UUID(),
                orgID: orgID,
                sessionID: nil,
                actorUserID: actorUserID,
                eventType: "member.invited",
                payload: [
                    "target_email": .string("invitee@example.com"),
                    "role": .string("viewer")
                ],
                createdAt: Date(timeIntervalSinceReferenceDate: 600)
            )
        )

        XCTAssertEqual(item.displayTitle, "Member invited")
        XCTAssertEqual(item.displaySubtitle, "Brian invited invitee@example.com as Viewer")
    }
}
