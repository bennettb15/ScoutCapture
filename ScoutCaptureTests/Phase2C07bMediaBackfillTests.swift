import XCTest
@testable import ScoutCapture

final class Phase2C07bMediaBackfillTests: XCTestCase {
    private func makeDefaultsSuite() -> UserDefaults {
        let suite = "Phase2C07bMediaBackfillTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeTempStorageRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScoutCapture-2C07b-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeShot(
        propertyID: UUID,
        sessionID: UUID,
        shotID: UUID = UUID(),
        uploadState: String,
        uploadAttempts: Int,
        angleIndex: Int,
        shotKey: String,
        updatedAt: Date = Date()
    ) -> ShotMetadata {
        ShotMetadata(
            shotID: shotID,
            propertyID: propertyID,
            sessionID: sessionID,
            createdAt: Date(),
            capturedAtLocal: nil,
            updatedAt: updatedAt,
            building: "Building",
            elevation: "Front",
            detailType: "Overview",
            angleIndex: angleIndex,
            trade: nil,
            priority: nil,
            shotKey: shotKey,
            isGuided: false,
            isFlagged: false,
            issueID: nil,
            issueStatus: nil,
            captureKind: nil,
            firstCaptureKind: nil,
            noteText: nil,
            noteCategory: nil,
            originalFilename: "\(shotID.uuidString).heic",
            originalRelativePath: "Originals/\(shotID.uuidString).heic",
            originalByteSize: 128,
            storageBucket: nil,
            storagePath: nil,
            checksumSHA256: nil,
            byteSize: 128,
            uploadState: uploadState,
            uploadAttempts: uploadAttempts,
            lastUploadError: nil,
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
    }

    private func makeAppStateWithSingleSession(
        uploadStates: [(state: String, attempts: Int, updatedAt: Date)],
        propertyOrganizationID: UUID? = nil,
        metadataOrganizationID: UUID? = nil,
        extraOrganizationIDs: [UUID] = [],
        supabaseEnabled: Bool = false,
        mediaSupabaseUploadEnabled: Bool = false
    ) throws -> (appState: AppState, propertyID: UUID, sessionID: UUID, shots: [ShotMetadata], storageRoot: URL) {
        let storageRoot = try makeTempStorageRoot()
        let defaults = makeDefaultsSuite()
        defaults.set(false, forKey: "scout.backup.automaticEnabled")
        if supabaseEnabled {
            defaults.set(true, forKey: "supabase_enabled")
        }
        if mediaSupabaseUploadEnabled {
            defaults.set(true, forKey: "media_supabase_upload_enabled")
        }
        let localStore = LocalStore(testStorageRootURL: storageRoot)

        let organizationID = propertyOrganizationID ?? UUID()
        let propertyID = UUID()
        let sessionID = UUID()

        for id in Set([organizationID] + extraOrganizationIDs) {
            _ = try localStore.createOrganization(Organization(id: id, name: "Org"))
        }
        _ = try localStore.createProperty(
            Property(
                id: propertyID,
                orgId: organizationID,
                name: "Property",
                address: "123 Main Street"
            )
        )
        _ = try localStore.upsertSession(
            Session(
                id: sessionID,
                propertyID: propertyID,
                startedAt: Date(),
                status: .draft
            )
        )

        var metadata = try localStore.loadSessionMetadata(propertyID: propertyID, sessionID: sessionID)
        metadata.orgID = metadataOrganizationID ?? organizationID
        metadata.shots = uploadStates.enumerated().map { index, state in
            let shotNumber = index + 1
            return makeShot(
                propertyID: propertyID,
                sessionID: sessionID,
                uploadState: state.state,
                uploadAttempts: state.attempts,
                angleIndex: shotNumber,
                shotKey: "building|front|overview|\(shotNumber)",
                updatedAt: state.updatedAt
            )
        }
        try localStore.saveSessionMetadataAtomically(propertyID: propertyID, sessionID: sessionID, metadata: metadata)

        let appState = AppState(
            localStore: localStore,
            userDefaults: defaults,
            disableCloudBackupForTests: true
        )
        appState._debugRefreshPropertiesLocallyForTests()

        return (appState, propertyID, sessionID, metadata.shots, storageRoot)
    }

    func testBackfillDiscoveryIncludesPendingAndUploadingStates() throws {
        let now = Date()
        let fixture = try makeAppStateWithSingleSession(
            uploadStates: [
                ("pending", 0, now),
                ("uploading", 1, now),
                ("uploaded", 2, now)
            ]
        )
        defer {
            fixture.appState.shutdown()
            try? FileManager.default.removeItem(at: fixture.storageRoot)
        }

        let candidates = fixture.appState._debugDiscoverPendingSupabaseMediaBackfillCandidates()

        XCTAssertEqual(
            Set(candidates.map(\.shotID)),
            Set([
                fixture.shots[0].shotID,
                fixture.shots[1].shotID
            ])
        )
        XCTAssertEqual(candidates.map(\.uploadState).sorted(), ["pending", "uploading"])
    }

    func testBackfillDiscoveryExcludesShotsAlreadyInFlight() throws {
        let now = Date()
        let fixture = try makeAppStateWithSingleSession(
            uploadStates: [
                ("pending", 0, now),
                ("uploading", 1, now)
            ]
        )
        defer {
            fixture.appState.shutdown()
            try? FileManager.default.removeItem(at: fixture.storageRoot)
        }

        let inFlightKey = fixture.appState._debugSupabaseUploadOperationKeyForTests(
            sessionID: fixture.sessionID,
            shotID: fixture.shots[1].shotID
        )
        fixture.appState._debugSetInFlightSupabaseMediaOperationsForTests([inFlightKey])

        let candidates = fixture.appState._debugDiscoverPendingSupabaseMediaBackfillCandidates()

        XCTAssertEqual(candidates.map(\.shotID), [fixture.shots[0].shotID])
    }

    func testBackfillRunSkipsRetryCapWithoutMutatingState() async throws {
        let now = Date()
        let fixture = try makeAppStateWithSingleSession(
            uploadStates: [
                ("pending", 5, now)
            ]
        )
        defer {
            fixture.appState.shutdown()
            try? FileManager.default.removeItem(at: fixture.storageRoot)
        }

        let summary = await fixture.appState._debugRunPendingSupabaseMediaBackfillForTests(reason: "retry_cap_test")

        XCTAssertTrue(summary.didStart)
        XCTAssertEqual(summary.discoveredCount, 1)
        XCTAssertEqual(summary.skippedRetryCapCount, 1)
        XCTAssertEqual(summary.attemptedCount, 0)

        let localStore = fixture.appState.sharedLocalStore
        let metadata = try localStore.loadSessionMetadata(propertyID: fixture.propertyID, sessionID: fixture.sessionID)
        XCTAssertEqual(metadata.shots.first?.uploadState, "pending")
        XCTAssertEqual(metadata.shots.first?.uploadAttempts, 5)
    }

    func testBackfillRunIsSingletonGuarded() async throws {
        let fixture = try makeAppStateWithSingleSession(uploadStates: [])
        defer {
            fixture.appState.shutdown()
            try? FileManager.default.removeItem(at: fixture.storageRoot)
        }

        fixture.appState._debugSetSupabaseMediaBackfillInProgressForTests(true)
        let summary = await fixture.appState._debugRunPendingSupabaseMediaBackfillForTests(reason: "guard_test")

        XCTAssertFalse(summary.didStart)
        XCTAssertEqual(summary.discoveredCount, 0)
        XCTAssertEqual(summary.attemptedCount, 0)
    }

    func testBackfillDiscoveryIncludesEligibleFailedShotsAfterCooldown() throws {
        let now = Date()
        let cooledFailedDate = now.addingTimeInterval(-31)
        let fixture = try makeAppStateWithSingleSession(
            uploadStates: [
                ("failed", 2, cooledFailedDate),
                ("uploaded", 1, now)
            ]
        )
        defer {
            fixture.appState.shutdown()
            try? FileManager.default.removeItem(at: fixture.storageRoot)
        }

        let candidates = fixture.appState._debugDiscoverPendingSupabaseMediaBackfillCandidates()

        XCTAssertEqual(candidates.map(\.shotID), [fixture.shots[0].shotID])
        XCTAssertEqual(candidates.map(\.uploadState), ["failed"])
    }

    func testBackfillDiscoverySuppressesFailedShotsInsideCooldown() throws {
        let now = Date()
        let fixture = try makeAppStateWithSingleSession(
            uploadStates: [
                ("failed", 2, now),
                ("pending", 0, now)
            ]
        )
        defer {
            fixture.appState.shutdown()
            try? FileManager.default.removeItem(at: fixture.storageRoot)
        }

        let candidates = fixture.appState._debugDiscoverPendingSupabaseMediaBackfillCandidates()

        XCTAssertEqual(candidates.map(\.shotID), [fixture.shots[1].shotID])
        XCTAssertEqual(candidates.map(\.uploadState), ["pending"])
    }

    func testBackfillDiscoveryIncludesSelectedPendingShotWhenLocalPropertyOrgIsStale() async throws {
        let now = Date()
        let activeOrganizationID = UUID()
        let staleOrganizationID = UUID()
        let fixture = try makeAppStateWithSingleSession(
            uploadStates: [("pending", 0, now)],
            propertyOrganizationID: staleOrganizationID,
            metadataOrganizationID: staleOrganizationID,
            extraOrganizationIDs: [activeOrganizationID],
            supabaseEnabled: true,
            mediaSupabaseUploadEnabled: true
        )
        defer {
            fixture.appState.shutdown()
            try? FileManager.default.removeItem(at: fixture.storageRoot)
        }

        await MainActor.run {
            fixture.appState.selectedPropertyID = fixture.propertyID
            fixture.appState._debugSetOfflineReplayEnvironmentForTests(
                activeOrganizationID: activeOrganizationID,
                ready: true,
                clientConfigured: true
            )
            fixture.appState._debugSetOrganizationContextForTests(
                memberships: [
                    ActiveOrganizationMembership(id: activeOrganizationID, name: "Active Org", role: "owner")
                ],
                activeOrganizationID: activeOrganizationID,
                ready: true
            )
        }

        let candidates = fixture.appState._debugDiscoverPendingSupabaseMediaBackfillCandidates()

        XCTAssertEqual(candidates.map(\.shotID), [fixture.shots[0].shotID])
    }

    func testBackfillDiscoveryStillBlocksWrongOrgPendingShotWhenNotActiveContext() async throws {
        let now = Date()
        let activeOrganizationID = UUID()
        let staleOrganizationID = UUID()
        let fixture = try makeAppStateWithSingleSession(
            uploadStates: [("pending", 0, now)],
            propertyOrganizationID: staleOrganizationID,
            metadataOrganizationID: staleOrganizationID,
            extraOrganizationIDs: [activeOrganizationID],
            supabaseEnabled: true,
            mediaSupabaseUploadEnabled: true
        )
        defer {
            fixture.appState.shutdown()
            try? FileManager.default.removeItem(at: fixture.storageRoot)
        }

        await MainActor.run {
            fixture.appState._debugSetOfflineReplayEnvironmentForTests(
                activeOrganizationID: activeOrganizationID,
                ready: true,
                clientConfigured: true
            )
            fixture.appState._debugSetOrganizationContextForTests(
                memberships: [
                    ActiveOrganizationMembership(id: activeOrganizationID, name: "Active Org", role: "owner")
                ],
                activeOrganizationID: activeOrganizationID,
                ready: true
            )
        }

        let candidates = fixture.appState._debugDiscoverPendingSupabaseMediaBackfillCandidates()

        XCTAssertTrue(candidates.isEmpty)
    }

    func testBackfillRunNoOpsWhenNothingIsEligible() async throws {
        let now = Date()
        let fixture = try makeAppStateWithSingleSession(
            uploadStates: [
                ("uploaded", 1, now),
                ("failed", 3, now)
            ]
        )
        defer {
            fixture.appState.shutdown()
            try? FileManager.default.removeItem(at: fixture.storageRoot)
        }

        let summary = await fixture.appState._debugRunPendingSupabaseMediaBackfillForTests(reason: "noop_test")

        XCTAssertTrue(summary.didStart)
        XCTAssertEqual(summary.discoveredCount, 0)
        XCTAssertEqual(summary.skippedRetryCapCount, 0)
        XCTAssertEqual(summary.attemptedCount, 0)
    }
}
