import XCTest
@testable import ScoutCapture

final class Phase2C12B2PropertyAccessVisibilityTests: XCTestCase {
    private struct Fixture {
        let suiteName: String
        let defaults: UserDefaults
        let storageRoot: URL
        let localStore: LocalStore
        let appState: AppState
    }

    private func makeFixture() throws -> Fixture {
        let suiteName = "Phase2C12B2PropertyAccessVisibilityTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(true, forKey: "supabase_enabled")
        defaults.set(true, forKey: "shadow_write_enabled")
        defaults.set(false, forKey: "supabase_read_enabled")
        defaults.set(false, forKey: "supabase_property_read_enabled")
        defaults.set(false, forKey: "media_supabase_upload_enabled")
        defaults.set(false, forKey: "sync_delta_enabled")

        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScoutCapture-2C12B2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)

        let localStore = LocalStore(testStorageRootURL: storageRoot)
        let appState = AppState(localStore: localStore, userDefaults: defaults)

        return Fixture(
            suiteName: suiteName,
            defaults: defaults,
            storageRoot: storageRoot,
            localStore: localStore,
            appState: appState
        )
    }

    private func tearDownFixture(_ fixture: Fixture) {
        fixture.defaults.removePersistentDomain(forName: fixture.suiteName)
        try? FileManager.default.removeItem(at: fixture.storageRoot)
    }

    private func seedProperty(
        localStore: LocalStore,
        orgID: UUID,
        name: String
    ) throws -> Property {
        _ = try localStore.createOrganization(Organization(id: orgID, name: "Org \(name)"))
        return try localStore.createProperty(
            Property(
                orgId: orgID,
                folderId: "folder-\(name.lowercased())",
                name: name,
                address: "123 \(name) Street"
            )
        )
    }

    private func seedSession(
        localStore: LocalStore,
        property: Property,
        status: Session.Status,
        isSealed: Bool = false,
        firstDeliveredAt: Date? = nil,
        withCapture: Bool = false,
        startedAt: Date = Date()
    ) throws -> Session {
        let session = Session(
            propertyID: property.id,
            startedAt: startedAt,
            status: status,
            endedAt: status == .completed ? startedAt.addingTimeInterval(60) : nil,
            exportedAt: status == .completed ? startedAt.addingTimeInterval(60) : nil,
            isSealed: isSealed,
            firstDeliveredAt: firstDeliveredAt
        )
        let persisted = try localStore.upsertSession(session)

        guard withCapture else {
            return persisted
        }

        let shotID = UUID()
        let shotKey = ShotMetadata.makeShotKey(
            building: "Building",
            elevation: "North",
            detailType: "Overview",
            angleIndex: 1
        )
        let shot = ShotMetadata(
            shotID: shotID,
            propertyID: property.id,
            sessionID: persisted.id,
            createdAt: startedAt,
            updatedAt: startedAt,
            building: "Building",
            elevation: "North",
            detailType: "Overview",
            angleIndex: 1,
            shotKey: shotKey,
            isGuided: false,
            isFlagged: false,
            issueID: nil,
            issueStatus: nil,
            noteText: nil,
            noteCategory: nil,
            originalFilename: "capture.jpg",
            originalRelativePath: "Originals/capture.jpg",
            originalByteSize: 1024,
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
        let metadata = SessionMetadata(
            schemaVersion: 1,
            propertyID: property.id,
            sessionID: persisted.id,
            orgID: property.orgId,
            orgNameAtCapture: "Test Org",
            propertyNameAtCapture: property.name,
            propertyNameAtExport: property.name,
            startedAt: startedAt,
            sessionStartedAtLocal: "",
            endedAt: persisted.endedAt,
            status: persisted.status,
            isBaselineSession: false,
            exportedAt: persisted.exportedAt,
            isSealed: persisted.isSealed,
            firstDeliveredAt: persisted.firstDeliveredAt,
            reExportExpiresAt: persisted.reExportExpiresAt,
            appVersion: "test",
            deviceModel: "test",
            osVersion: "test",
            shots: [shot],
            issues: [],
            guidedShots: []
        )
        try localStore.saveSessionMetadataAtomically(
            propertyID: property.id,
            sessionID: persisted.id,
            metadata: metadata
        )

        return persisted
    }

    private func configureAuthenticatedContext(
        _ appState: AppState,
        memberships: [ActiveOrganizationMembership],
        activeOrganizationID: UUID?
    ) async {
        await MainActor.run {
            appState._debugSetOfflineReplayEnvironmentForTests(
                activeOrganizationID: activeOrganizationID,
                ready: true,
                clientConfigured: true,
                authenticated: true,
                authenticationReady: true,
                authenticatedUserID: UUID()
            )
            appState._debugSetOrganizationContextForTests(
                memberships: memberships,
                activeOrganizationID: activeOrganizationID,
                ready: true
            )
            appState._debugRefreshPropertiesLocallyForTests()
        }
    }

    func testOrgScopeMemberSeesAllActiveOrgProperties() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        let orgID = UUID()
        let first = try seedProperty(localStore: fixture.localStore, orgID: orgID, name: "One")
        let second = try seedProperty(localStore: fixture.localStore, orgID: orgID, name: "Two")

        await configureAuthenticatedContext(
            fixture.appState,
            memberships: [
                ActiveOrganizationMembership(id: orgID, name: "Org", role: "viewer", accessScope: "org")
            ],
            activeOrganizationID: orgID
        )

        let visiblePropertyIDs = await MainActor.run { Set(fixture.appState.properties.map(\.id)) }
        XCTAssertEqual(visiblePropertyIDs, Set([first.id, second.id]))
    }

    func testPropertyScopeMemberSeesOnlyAuthorizedProperties() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        let orgID = UUID()
        let visibleProperty = try seedProperty(localStore: fixture.localStore, orgID: orgID, name: "Visible")
        let hiddenProperty = try seedProperty(localStore: fixture.localStore, orgID: orgID, name: "Hidden")

        await configureAuthenticatedContext(
            fixture.appState,
            memberships: [
                ActiveOrganizationMembership(id: orgID, name: "Org", role: "viewer", accessScope: "property")
            ],
            activeOrganizationID: orgID
        )

        await MainActor.run {
            fixture.appState._debugSetAuthorizedPropertyIDsForTests(
                orgID: orgID,
                propertyIDs: Set([visibleProperty.id])
            )
        }

        let visiblePropertyIDs = await MainActor.run { Set(fixture.appState.properties.map(\.id)) }
        XCTAssertEqual(visiblePropertyIDs, Set([visibleProperty.id]))
        XCTAssertFalse(visiblePropertyIDs.contains(hiddenProperty.id))
    }

    func testPropertyScopeMemberWithZeroAuthorizedPropertiesStaysEmptyWithoutFallback() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        let orgID = UUID()
        _ = try seedProperty(localStore: fixture.localStore, orgID: orgID, name: "Cached")

        await configureAuthenticatedContext(
            fixture.appState,
            memberships: [
                ActiveOrganizationMembership(id: orgID, name: "Org", role: "viewer", accessScope: "property")
            ],
            activeOrganizationID: orgID
        )

        await MainActor.run {
            fixture.appState._debugSetAuthorizedPropertyIDsForTests(
                orgID: orgID,
                propertyIDs: Set<UUID>()
            )
        }

        let visibleProperties = await MainActor.run { fixture.appState.properties }
        let visibleOrganizations = await MainActor.run { fixture.appState.organizations }

        XCTAssertTrue(visibleProperties.isEmpty)
        XCTAssertEqual(visibleOrganizations.map(\.id), [orgID])
    }

    func testRevokedPropertyDisappearsEvenIfCachedLocally() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        let orgID = UUID()
        let first = try seedProperty(localStore: fixture.localStore, orgID: orgID, name: "First")
        let second = try seedProperty(localStore: fixture.localStore, orgID: orgID, name: "Second")
        let secondSession = try seedSession(
            localStore: fixture.localStore,
            property: second,
            status: .draft,
            withCapture: true
        )

        await configureAuthenticatedContext(
            fixture.appState,
            memberships: [
                ActiveOrganizationMembership(id: orgID, name: "Org", role: "viewer", accessScope: "property")
            ],
            activeOrganizationID: orgID
        )

        await MainActor.run {
            fixture.appState._debugSetAuthorizedPropertyIDsForTests(
                orgID: orgID,
                propertyIDs: Set([first.id, second.id])
            )
            fixture.appState.selectedPropertyID = second.id
            fixture.appState.currentSession = secondSession
            fixture.appState._debugSetAuthorizedPropertyIDsForTests(
                orgID: orgID,
                propertyIDs: Set([first.id])
            )
        }

        let visiblePropertyIDs = await MainActor.run { Set(fixture.appState.properties.map(\.id)) }
        let selectedPropertyID = await MainActor.run { fixture.appState.selectedPropertyID }
        let currentSession = await MainActor.run { fixture.appState.currentSession }

        XCTAssertEqual(visiblePropertyIDs, Set([first.id]))
        XCTAssertNil(selectedPropertyID)
        XCTAssertNil(currentSession)
    }

    func testActiveOrgScopeChangeFromPropertyToOrgRestoresAllProperties() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        let orgID = UUID()
        let first = try seedProperty(localStore: fixture.localStore, orgID: orgID, name: "First")
        let second = try seedProperty(localStore: fixture.localStore, orgID: orgID, name: "Second")

        await configureAuthenticatedContext(
            fixture.appState,
            memberships: [
                ActiveOrganizationMembership(id: orgID, name: "Org", role: "viewer", accessScope: "property")
            ],
            activeOrganizationID: orgID
        )

        await MainActor.run {
            fixture.appState._debugSetAuthorizedPropertyIDsForTests(
                orgID: orgID,
                propertyIDs: Set([first.id])
            )
            fixture.appState._debugSetOrganizationContextForTests(
                memberships: [
                    ActiveOrganizationMembership(id: orgID, name: "Org", role: "viewer", accessScope: "org")
                ],
                activeOrganizationID: orgID,
                ready: true
            )
            fixture.appState._debugRefreshPropertiesLocallyForTests()
        }

        let visiblePropertyIDs = await MainActor.run { Set(fixture.appState.properties.map(\.id)) }
        XCTAssertEqual(visiblePropertyIDs, Set([first.id, second.id]))
    }

    func testHiddenPropertiesAreRemovedFromSessionDraftAndPendingCaches() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        let orgID = UUID()
        let visibleProperty = try seedProperty(localStore: fixture.localStore, orgID: orgID, name: "Visible")
        let hiddenProperty = try seedProperty(localStore: fixture.localStore, orgID: orgID, name: "Hidden")

        _ = try seedSession(
            localStore: fixture.localStore,
            property: visibleProperty,
            status: .draft,
            withCapture: true,
            startedAt: Date(timeIntervalSinceReferenceDate: 10)
        )
        _ = try seedSession(
            localStore: fixture.localStore,
            property: visibleProperty,
            status: .completed,
            isSealed: true,
            withCapture: false,
            startedAt: Date(timeIntervalSinceReferenceDate: 20)
        )
        _ = try seedSession(
            localStore: fixture.localStore,
            property: hiddenProperty,
            status: .draft,
            withCapture: true,
            startedAt: Date(timeIntervalSinceReferenceDate: 30)
        )
        _ = try seedSession(
            localStore: fixture.localStore,
            property: hiddenProperty,
            status: .completed,
            isSealed: true,
            withCapture: false,
            startedAt: Date(timeIntervalSinceReferenceDate: 40)
        )

        await configureAuthenticatedContext(
            fixture.appState,
            memberships: [
                ActiveOrganizationMembership(id: orgID, name: "Org", role: "viewer", accessScope: "property")
            ],
            activeOrganizationID: orgID
        )

        await MainActor.run {
            fixture.appState._debugSetAuthorizedPropertyIDsForTests(
                orgID: orgID,
                propertyIDs: Set([visibleProperty.id])
            )
        }

        let sessionIndexKeys = await MainActor.run { Set(fixture.appState.sessionIndexByProperty.keys) }
        let draftKeys = await MainActor.run { Set(fixture.appState.draftSessionByProperty.keys) }
        let pendingKeys = await MainActor.run { Set(fixture.appState.pendingExportSessionByProperty.keys) }

        XCTAssertEqual(sessionIndexKeys, Set([visibleProperty.id]))
        XCTAssertEqual(draftKeys, Set([visibleProperty.id]))
        XCTAssertEqual(pendingKeys, Set([visibleProperty.id]))
        XCTAssertFalse(sessionIndexKeys.contains(hiddenProperty.id))
        XCTAssertFalse(draftKeys.contains(hiddenProperty.id))
        XCTAssertFalse(pendingKeys.contains(hiddenProperty.id))
    }
}
