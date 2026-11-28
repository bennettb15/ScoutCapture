import XCTest
@testable import ScoutCapture

@MainActor
private final class RecordingSessionReader: SessionReadRepository {
    private(set) var deletedCalls: [(organizationID: UUID, propertyID: UUID?)] = []

    func ids(organizationID: UUID, propertyID: UUID, sessionID: UUID?) async throws -> [UUID] { [] }
    func activityLookup(ids: [UUID]) async throws -> [SessionActivityLookupRecord] { [] }
    func delta(organizationID: UUID, updatedAfter: Date?) async throws -> [RemoteSessionDeltaRecord] { [] }
    func updatedAt(sessionID: UUID, propertyID: UUID, organizationID: UUID) async throws -> Date? { nil }
    func divergence(organizationID: UUID) async throws -> [DivergenceRemoteSessionRecord] { [] }
    func remoteOnlyDetails(organizationID: UUID) async throws -> [RemoteOnlySessionDetailSessionRecord] { [] }
    func canonical(organizationID: UUID, propertyID: UUID, sessionID: UUID?) async throws -> [CanonicalReadRemoteSessionRecord] { [] }
    func canonical(ids: [UUID]) async throws -> [CanonicalReadRemoteSessionRecord] { [] }
    func activeParent(sessionID: UUID) async throws -> SessionSnapshotRemoteSessionPreflightRow? { nil }
    func lifecycle(sessionID: UUID, propertyID: UUID, organizationID: UUID) async throws -> RemoteSessionLifecycleReplayRecord? { nil }
    func coordination(sessionID: UUID, propertyID: UUID, organizationID: UUID) async throws -> RemoteSessionCoordinationRecord? { nil }
    func deletePreflight(sessionID: UUID, propertyID: UUID, organizationID: UUID) async throws -> RemoteSessionDeletePreflightRecord? { nil }
    func activePropertySessions(propertyID: UUID, organizationID: UUID) async throws -> [RemotePropertySessionLockRecord] { [] }
    func identities(organizationID: UUID) async throws -> [SessionIdentityRecord] { [] }
    func identity(sessionID: UUID, propertyID: UUID, organizationID: UUID) async throws -> SessionIdentityRecord? { nil }
    func reportSession(sessionID: UUID, propertyID: UUID) async throws -> FastRuntimeReportRemoteSessionRecord? { nil }
    func finalizedCandidates(propertyID: UUID, organizationID: UUID) async throws -> [RemoteSessionDeltaRecord] { [] }
    func captureProfile(sessionID: UUID, propertyID: UUID, organizationID: UUID) async throws -> SessionCaptureProfileWriteResult? { nil }
    func recentlyDeleted(organizationID: UUID, propertyID: UUID?) async throws -> [SessionRecentlyDeletedRecord] {
        deletedCalls.append((organizationID, propertyID))
        return []
    }
}

final class SessionReadRepositoryTests: XCTestCase {
    @MainActor
    func testRecentlyDeletedUsesInjectedReaderWithoutSupabaseClient() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionReadRepositoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "SessionReadRepositoryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "supabase_enabled")
        defaults.set(false, forKey: "supabase_read_enabled")
        defaults.set(false, forKey: "supabase_property_read_enabled")

        let reader = RecordingSessionReader()
        let appState = AppState(
            localStore: LocalStore(testStorageRootURL: root),
            userDefaults: defaults,
            environment: [:],
            sessionReadRepository: reader,
            disableCloudBackupForTests: true
        )
        defer { appState.shutdown() }
        let organizationID = UUID()
        let propertyID = UUID()
        appState._debugSetOfflineReplayEnvironmentForTests(
            activeOrganizationID: organizationID,
            clientConfigured: false,
            authenticated: true
        )

        let rows = try await appState.fetchRecentlyDeletedSessionsRemote(propertyID: propertyID)
        XCTAssertTrue(rows.isEmpty)
        XCTAssertEqual(reader.deletedCalls.count, 1)
        XCTAssertEqual(reader.deletedCalls.first?.organizationID, organizationID)
        XCTAssertEqual(reader.deletedCalls.first?.propertyID, propertyID)
    }
}
