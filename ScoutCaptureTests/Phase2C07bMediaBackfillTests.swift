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

    func testRetryCappedMediaDiagnosticsExposeSafeDetailOnly() throws {
        let now = Date()
        let fixture = try makeAppStateWithSingleSession(
            uploadStates: [
                ("pending", 5, now),
                ("uploaded", 1, now)
            ]
        )
        defer {
            fixture.appState.shutdown()
            try? FileManager.default.removeItem(at: fixture.storageRoot)
        }

        let localStore = fixture.appState.sharedLocalStore
        var metadata = try localStore.loadSessionMetadata(propertyID: fixture.propertyID, sessionID: fixture.sessionID)
        metadata.shots[0].originalFilename = "/private/tmp/hidden/\(fixture.shots[0].shotID.uuidString).heic"
        metadata.shots[0].originalRelativePath = "/private/tmp/hidden/\(fixture.shots[0].shotID.uuidString).heic"
        metadata.shots[0].lastUploadError = "upload failed at /private/tmp/hidden/original.heic"
        metadata.shots[0].storagePath = "sessions/\(fixture.sessionID.uuidString.lowercased())/shots/\(fixture.shots[0].shotID.uuidString.lowercased())/original.heic"
        try localStore.saveSessionMetadataAtomically(propertyID: fixture.propertyID, sessionID: fixture.sessionID, metadata: metadata)

        let items = fixture.appState.diagnosticsRetryCappedMediaItems()

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].shotID, fixture.shots[0].shotID)
        XCTAssertEqual(items[0].sessionID, fixture.sessionID)
        XCTAssertEqual(items[0].propertyID, fixture.propertyID)
        XCTAssertEqual(items[0].uploadState, "pending")
        XCTAssertEqual(items[0].attemptCount, 5)
        XCTAssertEqual(items[0].localFilename, "\(fixture.shots[0].shotID.uuidString).heic")
        XCTAssertEqual(items[0].hasStoragePath, true)
        XCTAssertEqual(items[0].lastUploadError, "upload failed at [path]")
        XCTAssertFalse(items[0].localFilename?.contains("/") ?? true)
        XCTAssertFalse(items[0].lastUploadError?.contains("/private") ?? true)
    }

    func testPendingMediaDiagnosticsExcludeRetryCappedAndUploadedItems() throws {
        let now = Date()
        let fixture = try makeAppStateWithSingleSession(
            uploadStates: [
                ("pending", 1, now),
                ("uploading", 2, now),
                ("failed", 3, now),
                ("pending", 5, now),
                ("uploaded", 1, now)
            ]
        )
        defer {
            fixture.appState.shutdown()
            try? FileManager.default.removeItem(at: fixture.storageRoot)
        }

        let pending = fixture.appState.diagnosticsPendingMediaItems()

        XCTAssertEqual(Set(pending.map(\.shotID)), Set([
            fixture.shots[0].shotID,
            fixture.shots[1].shotID,
            fixture.shots[2].shotID
        ]))
        XCTAssertFalse(pending.contains { $0.shotID == fixture.shots[3].shotID })
        XCTAssertFalse(pending.contains { $0.shotID == fixture.shots[4].shotID })
    }

    func testDivergenceAuditDetectsLocalOnlyCaptureProfileAndMediaDrift() throws {
        let now = Date()
        let organizationID = UUID()
        let fixture = try makeAppStateWithSingleSession(
            uploadStates: [
                ("pending", 1, now),
                ("uploaded", 1, now),
                ("pending", 5, now)
            ],
            propertyOrganizationID: organizationID,
            metadataOrganizationID: organizationID
        )
        defer {
            fixture.appState.shutdown()
            try? FileManager.default.removeItem(at: fixture.storageRoot)
        }

        let localStore = fixture.appState.sharedLocalStore
        var metadata = try localStore.loadSessionMetadata(propertyID: fixture.propertyID, sessionID: fixture.sessionID)
        metadata.shots[0].storagePath = "sessions/\(fixture.sessionID.uuidString.lowercased())/shots/\(fixture.shots[0].shotID.uuidString.lowercased())/original.heic"
        metadata.shots[1].storagePath = nil
        metadata.shots[2].storagePath = nil
        try localStore.saveSessionMetadataAtomically(propertyID: fixture.propertyID, sessionID: fixture.sessionID, metadata: metadata)

        let summary = fixture.appState._debugDivergenceAuditWithEmptyRemoteForTests(activeOrganizationID: organizationID)
        let categories = Set(summary.items.map(\.category))
        let reasons = summary.items.map(\.reason)

        XCTAssertTrue(categories.contains(.localOnlyProperty))
        XCTAssertTrue(categories.contains(.localOnlySession))
        XCTAssertTrue(categories.contains(.localOnlyShot))
        XCTAssertTrue(categories.contains(.captureProfile))
        XCTAssertTrue(categories.contains(.mediaDrift))
        XCTAssertTrue(reasons.contains("Local upload_state is pending but storage path exists."))
        XCTAssertTrue(reasons.contains("Local upload_state is uploaded but storage path is missing."))
        XCTAssertTrue(reasons.contains("Local media upload is retry-capped."))
    }

    func testDivergenceAuditDetectsMissingParentAndStaleOrg() throws {
        let now = Date()
        let activeOrganizationID = UUID()
        let staleOrganizationID = UUID()
        let fixture = try makeAppStateWithSingleSession(
            uploadStates: [
                ("pending", 0, now)
            ],
            propertyOrganizationID: activeOrganizationID,
            metadataOrganizationID: staleOrganizationID,
            extraOrganizationIDs: [staleOrganizationID]
        )
        defer {
            fixture.appState.shutdown()
            try? FileManager.default.removeItem(at: fixture.storageRoot)
        }

        let localStore = fixture.appState.sharedLocalStore
        let property = try XCTUnwrap(try localStore.fetchProperties().first(where: { $0.id == fixture.propertyID }))
        let session = try XCTUnwrap(try localStore.fetchSessionsForCacheBuild(propertyID: fixture.propertyID).first(where: { $0.id == fixture.sessionID }))
        let missingPropertyID = UUID()
        let missingSessionID = UUID()
        let orphanShot = makeShot(
            propertyID: missingPropertyID,
            sessionID: missingSessionID,
            uploadState: "pending",
            uploadAttempts: 0,
            angleIndex: 2,
            shotKey: "building|front|overview|2",
            updatedAt: now
        )

        let summary = fixture.appState._debugDivergenceAuditSummaryForTests(
            properties: [property],
            sessions: [session],
            shots: [
                AppState.DebugDivergenceLocalShotInput(
                    shot: orphanShot,
                    propertyID: fixture.propertyID,
                    sessionID: fixture.sessionID,
                    metadataOrgID: staleOrganizationID,
                    metadataCaptureProfile: nil
                )
            ],
            activeOrganizationID: activeOrganizationID
        )
        let missingParentItems = summary.items.filter { $0.category == .missingParent }
        let staleOrgItems = summary.items.filter { $0.category == .staleOrgMismatch }

        XCTAssertTrue(missingParentItems.contains { $0.propertyID == missingPropertyID })
        XCTAssertTrue(missingParentItems.contains { $0.sessionID == missingSessionID })
        XCTAssertTrue(staleOrgItems.contains { $0.orgID == staleOrganizationID })
    }

    func testDivergenceAuditMatchesRemoteIDsWithCaseNormalizationAndStaleLocalOrg() throws {
        let now = Date()
        let activeOrganizationID = UUID()
        let staleOrganizationID = UUID()
        let propertyID = UUID()
        let sessionID = UUID()
        let shotID = UUID()
        var shot = makeShot(
            propertyID: propertyID,
            sessionID: sessionID,
            shotID: shotID,
            uploadState: "uploaded",
            uploadAttempts: 1,
            angleIndex: 1,
            shotKey: "building|front|overview|1",
            updatedAt: now
        )
        shot.storagePath = "sessions/\(sessionID.uuidString.lowercased())/shots/\(shotID.uuidString.lowercased())/original.heic"

        let fixture = try makeAppStateWithSingleSession(uploadStates: [])
        defer {
            fixture.appState.shutdown()
            try? FileManager.default.removeItem(at: fixture.storageRoot)
        }

        let summary = fixture.appState._debugDivergenceAuditSummaryForTests(
            properties: [
                Property(
                    id: propertyID,
                    orgId: staleOrganizationID,
                    name: "Property",
                    address: "123 Main Street"
                )
            ],
            sessions: [
                Session(id: sessionID, propertyID: propertyID)
            ],
            shots: [
                AppState.DebugDivergenceLocalShotInput(
                    shot: shot,
                    propertyID: propertyID,
                    sessionID: sessionID,
                    metadataOrgID: staleOrganizationID,
                    metadataCaptureProfile: nil
                )
            ],
            remote: AppState.DebugDivergenceRemoteInput(
                propertyIDs: [propertyID.uuidString.uppercased()],
                sessions: [(id: sessionID.uuidString.uppercased(), propertyID: propertyID.uuidString.lowercased())],
                shots: [(id: shotID.uuidString.uppercased(), propertyID: propertyID.uuidString.uppercased(), sessionID: sessionID.uuidString.lowercased())],
                orgID: activeOrganizationID
            ),
            activeOrganizationID: activeOrganizationID
        )

        XCTAssertEqual(summary.matchedPropertyCount, 1)
        XCTAssertEqual(summary.matchedSessionCount, 1)
        XCTAssertEqual(summary.matchedShotCount, 1)
        XCTAssertEqual(summary.remoteOnlyPropertyCount, 0)
        XCTAssertEqual(summary.remoteOnlySessionCount, 0)
        XCTAssertEqual(summary.remoteOnlyShotCount, 0)
        XCTAssertEqual(summary.localOnlyPropertyCount, 0)
        XCTAssertEqual(summary.localOnlySessionCount, 0)
        XCTAssertEqual(summary.localOnlyShotCount, 0)
        XCTAssertEqual(summary.staleOrgReconciledPropertyCount, 1)
        XCTAssertEqual(summary.staleOrgReconciledShotCount, 1)
        XCTAssertFalse(summary.items.contains { $0.category == .remoteOnlyProperty })
        XCTAssertFalse(summary.items.contains { $0.category == .missingParent })
        XCTAssertFalse(summary.items.contains { $0.category == .staleOrgMismatch })
    }

    func testDivergenceAuditStillReportsTrueRemoteOnlyRows() throws {
        let activeOrganizationID = UUID()
        let localPropertyID = UUID()
        let remoteOnlyPropertyID = UUID()
        let fixture = try makeAppStateWithSingleSession(uploadStates: [])
        defer {
            fixture.appState.shutdown()
            try? FileManager.default.removeItem(at: fixture.storageRoot)
        }

        let summary = fixture.appState._debugDivergenceAuditSummaryForTests(
            properties: [
                Property(
                    id: localPropertyID,
                    orgId: activeOrganizationID,
                    name: "Local",
                    address: "123 Main Street"
                )
            ],
            sessions: [],
            shots: [],
            remote: AppState.DebugDivergenceRemoteInput(
                propertyIDs: [
                    localPropertyID.uuidString,
                    remoteOnlyPropertyID.uuidString
                ],
                orgID: activeOrganizationID
            ),
            activeOrganizationID: activeOrganizationID
        )

        XCTAssertEqual(summary.matchedPropertyCount, 1)
        XCTAssertEqual(summary.remoteOnlyPropertyCount, 1)
        XCTAssertTrue(summary.items.contains {
            $0.category == .remoteOnlyProperty &&
                $0.propertyID == remoteOnlyPropertyID
        })
    }

    func testDivergenceAuditSuppressesLocalOnlyShotMissingParentCascade() throws {
        let activeOrganizationID = UUID()
        let localPropertyID = UUID()
        let missingPropertyID = UUID()
        let missingSessionID = UUID()
        let localOnlyShotID = UUID()
        let fixture = try makeAppStateWithSingleSession(uploadStates: [])
        defer {
            fixture.appState.shutdown()
            try? FileManager.default.removeItem(at: fixture.storageRoot)
        }

        let localOnlyShot = makeShot(
            propertyID: missingPropertyID,
            sessionID: missingSessionID,
            shotID: localOnlyShotID,
            uploadState: "pending",
            uploadAttempts: 5,
            angleIndex: 1,
            shotKey: "building|front|overview|1"
        )

        let summary = fixture.appState._debugDivergenceAuditSummaryForTests(
            properties: [
                Property(
                    id: localPropertyID,
                    orgId: activeOrganizationID,
                    name: "Local",
                    address: "123 Main Street"
                )
            ],
            sessions: [],
            shots: [
                AppState.DebugDivergenceLocalShotInput(
                    shot: localOnlyShot,
                    propertyID: localPropertyID,
                    sessionID: missingSessionID,
                    metadataOrgID: activeOrganizationID,
                    metadataCaptureProfile: nil
                )
            ],
            remote: AppState.DebugDivergenceRemoteInput(
                propertyIDs: [localPropertyID.uuidString],
                orgID: activeOrganizationID
            ),
            activeOrganizationID: activeOrganizationID
        )

        XCTAssertEqual(summary.localOnlyShotCount, 1)
        XCTAssertTrue(summary.items.contains { $0.category == .localOnlyShot && $0.shotID == localOnlyShotID })
        XCTAssertFalse(summary.items.contains { $0.category == .missingParent && $0.shotID == localOnlyShotID })
    }

    func testDivergenceAuditSeverityMappingIsConservative() throws {
        let fixture = try makeAppStateWithSingleSession(uploadStates: [])
        defer {
            fixture.appState.shutdown()
            try? FileManager.default.removeItem(at: fixture.storageRoot)
        }

        XCTAssertEqual(fixture.appState._debugDivergenceSeverityForTests(category: .localOnlyShot), .needsReview)
        XCTAssertEqual(fixture.appState._debugDivergenceSeverityForTests(category: .mediaDrift), .needsReview)
        XCTAssertEqual(fixture.appState._debugDivergenceSeverityForTests(category: .captureProfile), .info)
        XCTAssertEqual(fixture.appState._debugDivergenceSeverityForTests(category: .staleOrgMismatch), .info)
        XCTAssertEqual(fixture.appState._debugDivergenceSeverityForTests(category: .missingParent), .warning)
    }

    func testDivergenceAuditSnapshotTextSanitizesPathsAndIncludesCounts() throws {
        let propertyID = UUID()
        let summary = AppState.DivergenceAuditSummary(
            ranAt: Date(timeIntervalSince1970: 0),
            activeOrganizationID: UUID(),
            remoteScopeAvailable: true,
            localPropertyCount: 1,
            remotePropertyCount: 1,
            localSessionCount: 0,
            remoteSessionCount: 0,
            localShotCount: 0,
            remoteShotCount: 0,
            matchedPropertyCount: 1,
            matchedSessionCount: 0,
            matchedShotCount: 0,
            localOnlyPropertyCount: 0,
            remoteOnlyPropertyCount: 0,
            localOnlySessionCount: 0,
            remoteOnlySessionCount: 0,
            localOnlyShotCount: 0,
            remoteOnlyShotCount: 0,
            staleOrgReconciledPropertyCount: 0,
            staleOrgReconciledShotCount: 0,
            items: [
                AppState.DivergenceAuditItem(
                    category: .mediaDrift,
                    entityType: "shot",
                    entityID: propertyID,
                    reason: "failed at /private/tmp/source.heic with token abc"
                )
            ]
        )

        let snapshot = AppState.divergenceAuditSnapshotText(summary)

        XCTAssertTrue(snapshot.contains("Core Sync Health"))
        XCTAssertTrue(snapshot.contains("Matched Properties: 1"))
        XCTAssertTrue(snapshot.contains("Needs Review | media_drift"))
        XCTAssertTrue(snapshot.contains("[path]"))
        XCTAssertFalse(snapshot.contains("/private/tmp"))
        XCTAssertFalse(snapshot.contains("abc"))
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
