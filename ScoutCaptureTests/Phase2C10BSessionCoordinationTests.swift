import XCTest
@testable import ScoutCapture

@MainActor
final class Phase2C10BSessionCoordinationTests: XCTestCase {
    private struct Fixture {
        let defaultsSuiteName: String
        let defaults: UserDefaults
        let storageRoot: URL
        let localStore: LocalStore
        let appState: AppState
        let organizationID: UUID
        let userID: UUID
        let property: Property
        let session: Session
        let metadata: SessionMetadata
    }

    private func makeDefaultsSuite(
        sessionCoordinationEnabled: Bool = true
    ) -> (suiteName: String, defaults: UserDefaults) {
        let suite = "Phase2C10BSessionCoordinationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        defaults.set(true, forKey: "supabase_enabled")
        defaults.set(true, forKey: "shadow_write_enabled")
        defaults.set(false, forKey: "supabase_read_enabled")
        defaults.set(false, forKey: "supabase_property_read_enabled")
        defaults.set(false, forKey: "media_supabase_upload_enabled")
        defaults.set(true, forKey: "sync_delta_enabled")
        defaults.set(sessionCoordinationEnabled, forKey: "session_coordination_enabled")
        return (suite, defaults)
    }

    private func makeTempStorageRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScoutCapture-2C10B-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeFixture(
        sessionCoordinationEnabled: Bool = true,
        sessionOverride: AppState.SessionShadowWriteOverride? = { _, _, _ in }
    ) throws -> Fixture {
        let defaultsFixture = makeDefaultsSuite(sessionCoordinationEnabled: sessionCoordinationEnabled)
        let storageRoot = try makeTempStorageRoot()
        let localStore = LocalStore(testStorageRootURL: storageRoot)
        let organizationID = UUID()
        let userID = UUID()
        _ = try localStore.createOrganization(Organization(id: organizationID, name: "Test Org"))

        let property = try localStore.createProperty(
            Property(
                id: UUID(),
                orgId: organizationID,
                folderId: "00001",
                clientName: "Client",
                clientPhone: "5551234567",
                clientEmail: "client@example.com",
                name: "Coordination Property",
                address: "123 Main Street",
                street: "123 Main Street",
                city: "Atlanta",
                state: "GA",
                zip: "30301",
                baselineSessionID: nil,
                isArchived: false,
                createdAt: Date(timeIntervalSinceReferenceDate: 100),
                updatedAt: Date(timeIntervalSinceReferenceDate: 100)
            )
        )

        let session = try localStore.upsertSession(
            Session(
                id: UUID(),
                propertyID: property.id,
                startedAt: Date(timeIntervalSinceReferenceDate: 200),
                status: .draft,
                endedAt: nil,
                exportedAt: nil,
                isSealed: false
            )
        )
        try localStore.ensureSessionMetadata(for: session)
        var metadata = try localStore.loadSessionMetadata(propertyID: property.id, sessionID: session.id)
        let shotID = UUID()
        let issueID = UUID()
        metadata.shots = [
            ShotMetadata(
                shotID: shotID,
                propertyID: property.id,
                sessionID: session.id,
                createdAt: Date(timeIntervalSinceReferenceDate: 210),
                capturedAtLocal: nil,
                updatedAt: Date(timeIntervalSinceReferenceDate: 211),
                building: "A",
                elevation: "North",
                detailType: "Panel",
                angleIndex: 0,
                trade: "Electrical",
                priority: "High",
                shotKey: "flagged|\(issueID.uuidString.lowercased())",
                isGuided: false,
                isFlagged: true,
                issueID: issueID,
                issueStatus: "active",
                captureKind: nil,
                firstCaptureKind: nil,
                noteText: "Loose outlet cover",
                noteCategory: nil,
                originalFilename: "one.jpg",
                originalRelativePath: "originals/one.jpg",
                originalByteSize: 1024,
                stampedFilename: nil,
                stampedRelativePath: nil,
                captureMode: nil,
                lens: nil,
                exifOrientation: nil,
                orientation: nil,
                latitude: nil,
                longitude: nil,
                accuracyMeters: nil,
                imageWidth: nil,
                imageHeight: nil
            )
        ]
        metadata.issues = [
            IssueMetadata(
                issueID: issueID,
                issueStatus: "active",
                currentReason: "Loose outlet cover"
            )
        ]
        try localStore.saveSessionMetadataAtomically(propertyID: property.id, sessionID: session.id, metadata: metadata)

        let appState = AppState(
            localStore: localStore,
            userDefaults: defaultsFixture.defaults,
            sessionShadowWriteOverride: sessionOverride,
            disableCloudBackupForTests: true
        )
        appState._debugSetOrganizationContextForTests(
            memberships: [
                ActiveOrganizationMembership(id: organizationID, name: "Test Org", role: "owner")
            ],
            activeOrganizationID: organizationID,
            ready: true
        )
        appState._debugSetOfflineReplayEnvironmentForTests(
            activeOrganizationID: organizationID,
            ready: true,
            clientConfigured: true,
            authenticated: true,
            authenticationReady: true,
            authenticatedUserID: userID
        )
        appState.refreshProperties()
        appState.selectProperty(id: property.id)
        appState.currentSession = session

        return Fixture(
            defaultsSuiteName: defaultsFixture.suiteName,
            defaults: defaultsFixture.defaults,
            storageRoot: storageRoot,
            localStore: localStore,
            appState: appState,
            organizationID: organizationID,
            userID: userID,
            property: property,
            session: session,
            metadata: metadata
        )
    }

    private func tearDownFixture(_ fixture: Fixture) {
        fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuiteName)
        try? FileManager.default.removeItem(at: fixture.storageRoot)
    }

    private func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    func testEntryAllowsUnlockedSessionAndClaimsLock() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        fixture.appState._debugSetSessionCoordinationFetchResultForTests(nil)
        let result = await fixture.appState.evaluateSessionEntryCoordination(
            propertyID: fixture.property.id,
            sessionID: fixture.session.id
        )

        XCTAssertEqual(result, .allowed)
        let state = fixture.appState._debugReadSessionCoordinationStateForTests(sessionID: fixture.session.id)
        XCTAssertEqual(state.lockedByUserID, fixture.userID)
        XCTAssertNotNil(state.lockedByDeviceID)
        XCTAssertNotNil(state.lockedAt)
    }

    func testEntryAllowsSameOwnerDeviceLock() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        _ = await fixture.appState.evaluateSessionEntryCoordination(
            propertyID: fixture.property.id,
            sessionID: fixture.session.id
        )
        let claimedState = fixture.appState._debugReadSessionCoordinationStateForTests(sessionID: fixture.session.id)
        fixture.appState._debugSetSessionCoordinationFetchResultForTests(
            AppState.DebugSessionCoordinationRemoteInput(
                sessionID: fixture.session.id,
                orgID: fixture.organizationID,
                propertyID: fixture.property.id,
                lockedByUserID: fixture.userID,
                lockedByDeviceID: claimedState.lockedByDeviceID,
                lockedAt: claimedState.lockedAt.map(iso8601),
                coordinationTier1Snapshot: fixture.appState._debugSessionCoordinationSnapshotStringForTests(metadata: fixture.metadata),
                updatedAt: Date()
            )
        )

        let result = await fixture.appState.evaluateSessionEntryCoordination(
            propertyID: fixture.property.id,
            sessionID: fixture.session.id
        )

        XCTAssertEqual(result, .allowed)
    }

    func testEntryBlocksOtherOwnerLock() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        fixture.appState._debugSetSessionCoordinationFetchResultForTests(
            AppState.DebugSessionCoordinationRemoteInput(
                sessionID: fixture.session.id,
                orgID: fixture.organizationID,
                propertyID: fixture.property.id,
                lockedByUserID: UUID(),
                lockedByDeviceID: "other-device",
                lockedAt: iso8601(Date(timeIntervalSinceReferenceDate: 300)),
                coordinationTier1Snapshot: fixture.appState._debugSessionCoordinationSnapshotStringForTests(metadata: fixture.metadata),
                updatedAt: Date()
            )
        )

        let result = await fixture.appState.evaluateSessionEntryCoordination(
            propertyID: fixture.property.id,
            sessionID: fixture.session.id
        )

        guard case .blocked(let block) = result else {
            return XCTFail("Expected blocked entry")
        }
        XCTAssertFalse(block.ownerDescription.isEmpty)
        XCTAssertNotNil(block.lockedAt)
    }

    func testManualClaimOverridesStaleLock() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        fixture.appState._debugSetSessionCoordinationFetchResultForTests(
            AppState.DebugSessionCoordinationRemoteInput(
                sessionID: fixture.session.id,
                orgID: fixture.organizationID,
                propertyID: fixture.property.id,
                lockedByUserID: UUID(),
                lockedByDeviceID: "other-device",
                lockedAt: iso8601(Date(timeIntervalSinceReferenceDate: 300)),
                coordinationTier1Snapshot: fixture.appState._debugSessionCoordinationSnapshotStringForTests(metadata: fixture.metadata),
                updatedAt: Date()
            )
        )

        let result = await fixture.appState.evaluateSessionEntryCoordination(
            propertyID: fixture.property.id,
            sessionID: fixture.session.id,
            forceClaim: true
        )

        XCTAssertEqual(result, .allowed)
        let state = fixture.appState._debugReadSessionCoordinationStateForTests(sessionID: fixture.session.id)
        XCTAssertEqual(state.lockedByUserID, fixture.userID)
    }

    func testFlagDisabledFallbackPathAllowsEntry() async throws {
        let fixture = try makeFixture(sessionCoordinationEnabled: false)
        defer { tearDownFixture(fixture) }

        fixture.appState._debugSetSessionCoordinationFetchResultForTests(
            AppState.DebugSessionCoordinationRemoteInput(
                sessionID: fixture.session.id,
                orgID: fixture.organizationID,
                propertyID: fixture.property.id,
                lockedByUserID: UUID(),
                lockedByDeviceID: "other-device",
                lockedAt: iso8601(Date(timeIntervalSinceReferenceDate: 300)),
                coordinationTier1Snapshot: nil,
                updatedAt: Date()
            )
        )

        let result = await fixture.appState.evaluateSessionEntryCoordination(
            propertyID: fixture.property.id,
            sessionID: fixture.session.id
        )

        XCTAssertEqual(result, .allowed)
    }

    func testOwnedLockReleaseOnCompletion() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        _ = await fixture.appState.evaluateSessionEntryCoordination(
            propertyID: fixture.property.id,
            sessionID: fixture.session.id
        )
        await fixture.appState.releaseCurrentSessionCoordinationLockIfOwned()

        let state = fixture.appState._debugReadSessionCoordinationStateForTests(sessionID: fixture.session.id)
        XCTAssertNil(state.lockedByUserID)
        XCTAssertNil(state.lockedByDeviceID)
        XCTAssertNil(state.lockedAt)
    }

    func testOwnedLockReleaseDoesNotClearAnotherOwnersLock() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        fixture.appState._debugSetSessionCoordinationStateForTests(
            sessionID: fixture.session.id,
            lockedByUserID: UUID(),
            lockedByDeviceID: "other-device",
            lockedAt: Date()
        )
        await fixture.appState.releaseCurrentSessionCoordinationLockIfOwned()

        let state = fixture.appState._debugReadSessionCoordinationStateForTests(sessionID: fixture.session.id)
        XCTAssertNotNil(state.lockedByUserID)
        XCTAssertEqual(state.lockedByDeviceID, "other-device")
    }

    func testPreCompletionConflictPassesWhenTier1Unchanged() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        let snapshot = fixture.appState._debugSessionCoordinationSnapshotStringForTests(metadata: fixture.metadata)
        fixture.appState._debugSetSessionCoordinationEntrySnapshotForTests(
            sessionID: fixture.session.id,
            snapshot: snapshot
        )
        fixture.appState._debugSetSessionCoordinationFetchResultForTests(
            AppState.DebugSessionCoordinationRemoteInput(
                sessionID: fixture.session.id,
                orgID: fixture.organizationID,
                propertyID: fixture.property.id,
                lockedByUserID: fixture.userID,
                lockedByDeviceID: "same-device",
                lockedAt: iso8601(Date()),
                coordinationTier1Snapshot: snapshot,
                updatedAt: Date()
            )
        )

        let review = await fixture.appState.preCompletionConflictReview(
            propertyID: fixture.property.id,
            sessionID: fixture.session.id
        )
        XCTAssertNil(review)
    }

    func testPreCompletionConflictBlocksWhenPriorityChangesRemotely() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        let snapshot = fixture.appState._debugSessionCoordinationSnapshotStringForTests(metadata: fixture.metadata)
        fixture.appState._debugSetSessionCoordinationEntrySnapshotForTests(sessionID: fixture.session.id, snapshot: snapshot)

        var remoteMetadata = fixture.metadata
        remoteMetadata.shots[0].priority = "Critical"
        fixture.appState._debugSetSessionCoordinationFetchResultForTests(
            AppState.DebugSessionCoordinationRemoteInput(
                sessionID: fixture.session.id,
                orgID: fixture.organizationID,
                propertyID: fixture.property.id,
                lockedByUserID: fixture.userID,
                lockedByDeviceID: "same-device",
                lockedAt: iso8601(Date()),
                coordinationTier1Snapshot: fixture.appState._debugSessionCoordinationSnapshotStringForTests(metadata: remoteMetadata),
                updatedAt: Date()
            )
        )

        let review = await fixture.appState.preCompletionConflictReview(
            propertyID: fixture.property.id,
            sessionID: fixture.session.id
        )
        XCTAssertEqual(review?.diffs.count, 1)
        XCTAssertTrue(review?.diffs.first?.label.contains("Priority") ?? false)
    }

    func testPreCompletionConflictBlocksWhenTradeChangesRemotely() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        let snapshot = fixture.appState._debugSessionCoordinationSnapshotStringForTests(metadata: fixture.metadata)
        fixture.appState._debugSetSessionCoordinationEntrySnapshotForTests(sessionID: fixture.session.id, snapshot: snapshot)

        var remoteMetadata = fixture.metadata
        remoteMetadata.shots[0].trade = "Plumbing"
        fixture.appState._debugSetSessionCoordinationFetchResultForTests(
            AppState.DebugSessionCoordinationRemoteInput(
                sessionID: fixture.session.id,
                orgID: fixture.organizationID,
                propertyID: fixture.property.id,
                lockedByUserID: fixture.userID,
                lockedByDeviceID: "same-device",
                lockedAt: iso8601(Date()),
                coordinationTier1Snapshot: fixture.appState._debugSessionCoordinationSnapshotStringForTests(metadata: remoteMetadata),
                updatedAt: Date()
            )
        )

        let review = await fixture.appState.preCompletionConflictReview(
            propertyID: fixture.property.id,
            sessionID: fixture.session.id
        )
        XCTAssertEqual(review?.diffs.count, 1)
        XCTAssertTrue(review?.diffs.first?.label.contains("Trade") ?? false)
    }

    func testPreCompletionConflictBlocksWhenFlaggedReasonChangesRemotely() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        let snapshot = fixture.appState._debugSessionCoordinationSnapshotStringForTests(metadata: fixture.metadata)
        fixture.appState._debugSetSessionCoordinationEntrySnapshotForTests(sessionID: fixture.session.id, snapshot: snapshot)

        var remoteMetadata = fixture.metadata
        remoteMetadata.issues[0].currentReason = "Panel door obstruction"
        fixture.appState._debugSetSessionCoordinationFetchResultForTests(
            AppState.DebugSessionCoordinationRemoteInput(
                sessionID: fixture.session.id,
                orgID: fixture.organizationID,
                propertyID: fixture.property.id,
                lockedByUserID: fixture.userID,
                lockedByDeviceID: "same-device",
                lockedAt: iso8601(Date()),
                coordinationTier1Snapshot: fixture.appState._debugSessionCoordinationSnapshotStringForTests(metadata: remoteMetadata),
                updatedAt: Date()
            )
        )

        let review = await fixture.appState.preCompletionConflictReview(
            propertyID: fixture.property.id,
            sessionID: fixture.session.id
        )
        XCTAssertEqual(review?.diffs.count, 1)
        XCTAssertTrue(review?.diffs.first?.label.contains("Flagged Reason") ?? false)
    }

    func testStructuralChangesAreIgnoredWhenTier1SnapshotMatches() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        let snapshot = fixture.appState._debugSessionCoordinationSnapshotStringForTests(metadata: fixture.metadata)
        fixture.appState._debugSetSessionCoordinationEntrySnapshotForTests(sessionID: fixture.session.id, snapshot: snapshot)
        fixture.appState._debugSetSessionCoordinationFetchResultForTests(
            AppState.DebugSessionCoordinationRemoteInput(
                sessionID: fixture.session.id,
                orgID: fixture.organizationID,
                propertyID: fixture.property.id,
                lockedByUserID: fixture.userID,
                lockedByDeviceID: "same-device",
                lockedAt: iso8601(Date()),
                coordinationTier1Snapshot: snapshot,
                updatedAt: Date(timeIntervalSinceReferenceDate: 999)
            )
        )

        let review = await fixture.appState.preCompletionConflictReview(
            propertyID: fixture.property.id,
            sessionID: fixture.session.id
        )
        XCTAssertNil(review)
    }

    func testQueueCompatibilityIncludesLockFieldsWhenPresent() async throws {
        struct ForcedFailure: LocalizedError {
            var errorDescription: String? { "forced session shadow write failure" }
        }

        let fixture = try makeFixture(sessionOverride: { _, _, _ in
            throw ForcedFailure()
        })
        defer { tearDownFixture(fixture) }

        _ = await fixture.appState.evaluateSessionEntryCoordination(
            propertyID: fixture.property.id,
            sessionID: fixture.session.id
        )

        let queued = try fixture.localStore.fetchQueuedMutations()
        let sessionMutation = try XCTUnwrap(queued.last(where: { $0.operation == "upsert_session" }))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: sessionMutation.payloadData) as? [String: Any])
        let session = try XCTUnwrap(payload["session"] as? [String: Any])
        XCTAssertNotNil(session["locked_by_user_id"])
        XCTAssertNotNil(session["locked_by_device_id"])
    }

    func testQueueCompatibilityReplaysLegacyPayloadWithoutLockFields() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        let legacyPayload = """
        {
          "property": {
            "id": "\(fixture.property.id.uuidString.lowercased())",
            "org_id": "\(fixture.organizationID.uuidString.lowercased())",
            "name": "Coordination Property",
            "address_line1": "123 Main Street",
            "city": "Atlanta",
            "state": "GA",
            "postal_code": "30301"
          },
          "session": {
            "id": "\(fixture.session.id.uuidString.lowercased())",
            "org_id": "\(fixture.organizationID.uuidString.lowercased())",
            "property_id": "\(fixture.property.id.uuidString.lowercased())",
            "title": "Coordination Property",
            "status": "draft",
            "started_at": "\(iso8601(fixture.session.startedAt))"
          }
        }
        """
        let mutation = LocalStore.QueuedMutation(
            entityType: "session",
            entityID: fixture.session.id,
            organizationID: fixture.organizationID,
            propertyID: fixture.property.id,
            sessionID: fixture.session.id,
            operation: "upsert_session",
            payloadData: try XCTUnwrap(legacyPayload.data(using: .utf8)),
            idempotencyKey: "legacy-\(fixture.session.id.uuidString)"
        )
        _ = try fixture.localStore.appendQueuedMutation(mutation)

        let summary = await fixture.appState._debugPerformOfflineReplayForTests(source: "legacy_session_coordination_payload")
        XCTAssertEqual(summary.succeededCount, 1)
        XCTAssertEqual(try fixture.localStore.fetchQueuedMutations().count, 0)
    }
}
