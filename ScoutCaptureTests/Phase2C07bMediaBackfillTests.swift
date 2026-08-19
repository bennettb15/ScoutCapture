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

    private func createOriginalFile(
        storageRoot: URL,
        propertyID: UUID,
        sessionID: UUID,
        shot: ShotMetadata
    ) throws {
        let originals = storageRoot
            .appendingPathComponent("SCOUT/Properties/\(propertyID.uuidString)/Sessions/\(sessionID.uuidString)/Originals", isDirectory: true)
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        try Data("media".utf8).write(to: originals.appendingPathComponent(shot.originalFilename))
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
        XCTAssertTrue(summary.items.contains {
            $0.category == .legacyOrgReconciliation &&
                $0.propertyID == propertyID &&
                $0.severity == .info
        })
        XCTAssertTrue(summary.items.contains {
            $0.category == .legacyOrgReconciliation &&
                $0.shotID == shotID &&
                $0.severity == .info
        })
    }

    func testDivergenceAuditDeduplicatesLegacyCaptureProfileNullAgainstRemoteValue() throws {
        let activeOrganizationID = UUID()
        let propertyID = UUID()
        let sessionID = UUID()
        let fixture = try makeAppStateWithSingleSession(uploadStates: [])
        defer {
            fixture.appState.shutdown()
            try? FileManager.default.removeItem(at: fixture.storageRoot)
        }

        let summary = fixture.appState._debugDivergenceAuditSummaryForTests(
            properties: [
                Property(
                    id: propertyID,
                    orgId: activeOrganizationID,
                    captureProfile: nil,
                    name: "Local",
                    address: "123 Main Street"
                )
            ],
            sessions: [
                Session(id: sessionID, propertyID: propertyID, captureProfile: nil)
            ],
            shots: [],
            remote: AppState.DebugDivergenceRemoteInput(
                propertyIDs: [propertyID.uuidString],
                sessions: [(id: sessionID.uuidString, propertyID: propertyID.uuidString)],
                propertyCaptureProfiles: [propertyID.uuidString.lowercased(): CaptureProfile.residential.rawValue],
                sessionCaptureProfiles: [sessionID.uuidString.lowercased(): CaptureProfile.residential.rawValue],
                orgID: activeOrganizationID
            ),
            activeOrganizationID: activeOrganizationID
        )

        XCTAssertEqual(summary.items.filter { $0.category == .captureProfile }.count, 0)
        XCTAssertEqual(summary.items.filter { $0.category == .legacyCaptureProfile }.count, 2)
        XCTAssertTrue(summary.items.allSatisfy { $0.category != .legacyCaptureProfile || $0.severity == .info })
    }

    func testDivergenceAuditReclassifiesResolvableRemoteShotNullPropertyAsLegacySchema() throws {
        let activeOrganizationID = UUID()
        let propertyID = UUID()
        let sessionID = UUID()
        let shotID = UUID()
        let fixture = try makeAppStateWithSingleSession(uploadStates: [])
        defer {
            fixture.appState.shutdown()
            try? FileManager.default.removeItem(at: fixture.storageRoot)
        }

        let summary = fixture.appState._debugDivergenceAuditSummaryForTests(
            properties: [],
            sessions: [],
            shots: [],
            remote: AppState.DebugDivergenceRemoteInput(
                propertyIDs: [propertyID.uuidString],
                sessions: [(id: sessionID.uuidString, propertyID: propertyID.uuidString)],
                shots: [(id: shotID.uuidString, propertyID: nil, sessionID: sessionID.uuidString)],
                orgID: activeOrganizationID
            ),
            activeOrganizationID: activeOrganizationID
        )

        XCTAssertTrue(summary.items.contains {
            $0.category == .legacyRemoteSchema &&
                $0.shotID == shotID &&
                $0.propertyID == propertyID &&
                $0.sessionID == sessionID &&
                $0.severity == .info
        })
        XCTAssertFalse(summary.items.contains { $0.category == .missingParent && $0.shotID == shotID })
    }

    func testDivergenceAuditKeepsTrueRemoteShotMissingParentAsWarning() throws {
        let activeOrganizationID = UUID()
        let shotID = UUID()
        let fixture = try makeAppStateWithSingleSession(uploadStates: [])
        defer {
            fixture.appState.shutdown()
            try? FileManager.default.removeItem(at: fixture.storageRoot)
        }

        let summary = fixture.appState._debugDivergenceAuditSummaryForTests(
            properties: [],
            sessions: [],
            shots: [],
            remote: AppState.DebugDivergenceRemoteInput(
                propertyIDs: [],
                shots: [(id: shotID.uuidString, propertyID: nil, sessionID: nil)],
                orgID: activeOrganizationID
            ),
            activeOrganizationID: activeOrganizationID
        )

        XCTAssertTrue(summary.items.contains {
            $0.category == .missingParent &&
                $0.shotID == shotID &&
                $0.severity == .warning
        })
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
        XCTAssertEqual(fixture.appState._debugDivergenceSeverityForTests(category: .legacyCaptureProfile), .info)
        XCTAssertEqual(fixture.appState._debugDivergenceSeverityForTests(category: .legacyRemoteSchema), .info)
        XCTAssertEqual(fixture.appState._debugDivergenceSeverityForTests(category: .legacyOrgReconciliation), .info)
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
                ),
                AppState.DivergenceAuditItem(
                    category: .legacyRemoteSchema,
                    entityType: "shot",
                    entityID: propertyID,
                    reason: "legacy remote row remains inspectable"
                )
            ]
        )

        let snapshot = AppState.divergenceAuditSnapshotText(summary)

        XCTAssertTrue(snapshot.contains("Core Sync Health"))
        XCTAssertTrue(snapshot.contains("Active Sync Issues"))
        XCTAssertTrue(snapshot.contains("Recoverable Issues"))
        XCTAssertTrue(snapshot.contains("Historical / Informational States"))
        XCTAssertTrue(snapshot.contains("Grouped Historical Summaries"))
        XCTAssertTrue(snapshot.contains("Matched Properties: 1"))
        XCTAssertTrue(snapshot.contains("Needs Review | media_drift"))
        XCTAssertTrue(snapshot.contains("Info | legacy_remote_schema"))
        XCTAssertTrue(snapshot.contains("[path]"))
        XCTAssertFalse(snapshot.contains("/private/tmp"))
        XCTAssertFalse(snapshot.contains("abc"))
    }

    @MainActor
    func testSyncDebtInspectorClassifiesOldRemoteOnlySessionAsHistorical() throws {
        let activeOrganizationID = UUID()
        let propertyID = UUID()
        let remoteSessionID = UUID()
        let remoteUpdatedAt = Date(timeIntervalSinceReferenceDate: 100)
        let cursor = Date(timeIntervalSinceReferenceDate: 200)
        let fixture = try makeAppStateWithSingleSession(uploadStates: [], extraOrganizationIDs: [activeOrganizationID])
        defer {
            fixture.appState.shutdown()
            try? FileManager.default.removeItem(at: fixture.storageRoot)
        }

        fixture.appState._debugWriteSyncCursorForTests(entity: "sessions", orgID: activeOrganizationID, date: cursor)
        let localProperties = [
            Property(
                id: propertyID,
                orgId: activeOrganizationID,
                name: "Local",
                address: "123 Main Street"
            )
        ]
        let remote = AppState.DebugDivergenceRemoteInput(
            propertyIDs: [propertyID.uuidString],
            sessions: [(id: remoteSessionID.uuidString, propertyID: propertyID.uuidString)],
            sessionUpdatedAts: [remoteSessionID.uuidString.lowercased(): remoteUpdatedAt],
            orgID: activeOrganizationID
        )
        let summary = fixture.appState._debugDivergenceAuditSummaryForTests(
            properties: localProperties,
            sessions: [],
            shots: [],
            remote: remote,
            activeOrganizationID: activeOrganizationID
        )

        let report = fixture.appState._debugSyncDebtInspectionReportForTests(
            properties: localProperties,
            sessions: [],
            shots: [],
            remote: remote,
            divergenceAuditSummary: summary,
            activeOrganizationID: activeOrganizationID
        )

        let item = try XCTUnwrap(report.divergenceItems.first { $0.category == .remoteOnlySession })
        XCTAssertEqual(item.classification, .historicalRemoteOnly)
        XCTAssertTrue(item.classificationReason.contains("sync cursor"))
    }

    @MainActor
    func testSyncDebtInspectorClassifiesRemoteOnlySessionWithLocalParentAsHydrationDebt() throws {
        let activeOrganizationID = UUID()
        let propertyID = UUID()
        let remoteSessionID = UUID()
        let fixture = try makeAppStateWithSingleSession(uploadStates: [], extraOrganizationIDs: [activeOrganizationID])
        defer {
            fixture.appState.shutdown()
            try? FileManager.default.removeItem(at: fixture.storageRoot)
        }

        let localProperties = [
            Property(
                id: propertyID,
                orgId: activeOrganizationID,
                name: "Local",
                address: "123 Main Street"
            )
        ]
        let remote = AppState.DebugDivergenceRemoteInput(
            propertyIDs: [propertyID.uuidString],
            sessions: [(id: remoteSessionID.uuidString, propertyID: propertyID.uuidString)],
            sessionUpdatedAts: [remoteSessionID.uuidString.lowercased(): Date(timeIntervalSinceReferenceDate: 300)],
            orgID: activeOrganizationID
        )
        let summary = fixture.appState._debugDivergenceAuditSummaryForTests(
            properties: localProperties,
            sessions: [],
            shots: [],
            remote: remote,
            activeOrganizationID: activeOrganizationID
        )

        let report = fixture.appState._debugSyncDebtInspectionReportForTests(
            properties: localProperties,
            sessions: [],
            shots: [],
            remote: remote,
            divergenceAuditSummary: summary,
            activeOrganizationID: activeOrganizationID
        )

        let item = try XCTUnwrap(report.divergenceItems.first { $0.category == .remoteOnlySession })
        XCTAssertEqual(item.classification, .missingLocalHydration)
        XCTAssertTrue(item.classificationReason.contains("local property"))
    }

    @MainActor
    func testRemoteOnlySessionDetailReportRedactsSensitiveText() throws {
        let activeOrganizationID = UUID()
        let propertyID = UUID()
        let remoteSessionID = UUID()
        let fixture = try makeAppStateWithSingleSession(uploadStates: [], extraOrganizationIDs: [activeOrganizationID])
        defer {
            fixture.appState.shutdown()
            try? FileManager.default.removeItem(at: fixture.storageRoot)
        }

        let localProperties = [
            Property(
                id: propertyID,
                orgId: activeOrganizationID,
                name: "/private/tmp token abc https://example.test/media?signature=secret",
                address: "123 Main Street"
            )
        ]
        let report = fixture.appState._debugRemoteOnlySessionDetailReportForTests(
            localProperties: localProperties,
            localSessions: [],
            remote: AppState.DebugRemoteOnlySessionDetailInput(
                properties: localProperties,
                sessions: [
                    AppState.DebugRemoteOnlySessionInput(
                        id: remoteSessionID,
                        propertyID: propertyID,
                        status: "completed",
                        completedAt: "2026-01-01T01:00:00Z",
                        updatedAt: Date(timeIntervalSinceReferenceDate: 400)
                    )
                ],
                orgID: activeOrganizationID
            ),
            activeOrganizationID: activeOrganizationID
        )

        let text = AppState.remoteOnlySessionDetailReportText(report)
        XCTAssertTrue(text.contains("[path]"))
        XCTAssertTrue(text.contains("[redacted]"))
        XCTAssertTrue(text.contains("[url]"))
        XCTAssertFalse(text.contains("/private/tmp"))
        XCTAssertFalse(text.contains("abc"))
        XCTAssertFalse(text.contains("signature=secret"))
    }

    @MainActor
    func testRemoteOnlySessionDetailClassifiesDeletedAsHistorical() throws {
        let activeOrganizationID = UUID()
        let propertyID = UUID()
        let remoteSessionID = UUID()
        let fixture = try makeAppStateWithSingleSession(uploadStates: [], extraOrganizationIDs: [activeOrganizationID])
        defer {
            fixture.appState.shutdown()
            try? FileManager.default.removeItem(at: fixture.storageRoot)
        }

        let localProperties = [Property(id: propertyID, orgId: activeOrganizationID, name: "Local")]
        let report = fixture.appState._debugRemoteOnlySessionDetailReportForTests(
            localProperties: localProperties,
            localSessions: [],
            remote: AppState.DebugRemoteOnlySessionDetailInput(
                properties: localProperties,
                sessions: [
                    AppState.DebugRemoteOnlySessionInput(
                        id: remoteSessionID,
                        propertyID: propertyID,
                        status: "completed",
                        updatedAt: Date(timeIntervalSinceReferenceDate: 400),
                        deletedAt: Date(timeIntervalSinceReferenceDate: 450)
                    )
                ],
                orgID: activeOrganizationID
            ),
            activeOrganizationID: activeOrganizationID
        )

        let item = try XCTUnwrap(report.items.first)
        XCTAssertEqual(item.classification, .historicalRemoteOnly)
        XCTAssertTrue(item.appearsDeleted)
        XCTAssertTrue(item.labels.contains(.historicalDeleted))
    }

    @MainActor
    func testRemoteOnlySessionDetailClassifiesEmptyDraftShellAsInformational() throws {
        let activeOrganizationID = UUID()
        let propertyID = UUID()
        let remoteSessionID = UUID()
        let fixture = try makeAppStateWithSingleSession(uploadStates: [], extraOrganizationIDs: [activeOrganizationID])
        defer {
            fixture.appState.shutdown()
            try? FileManager.default.removeItem(at: fixture.storageRoot)
        }

        let localProperties = [Property(id: propertyID, orgId: activeOrganizationID, name: "Local")]
        let report = fixture.appState._debugRemoteOnlySessionDetailReportForTests(
            localProperties: localProperties,
            localSessions: [],
            remote: AppState.DebugRemoteOnlySessionDetailInput(
                properties: localProperties,
                sessions: [
                    AppState.DebugRemoteOnlySessionInput(
                        id: remoteSessionID,
                        propertyID: propertyID,
                        status: "draft",
                        updatedAt: Date(timeIntervalSinceReferenceDate: 500)
                    )
                ],
                observations: [],
                orgID: activeOrganizationID
            ),
            activeOrganizationID: activeOrganizationID
        )

        let item = try XCTUnwrap(report.items.first)
        XCTAssertEqual(item.classification, .emptyRemoteDraftShell)
        XCTAssertTrue(item.parentPropertyExistsLocally)
        XCTAssertEqual(item.localPropertyName, "Local")
        XCTAssertEqual(item.remoteShotCount, 0)
        XCTAssertEqual(item.remoteIssueObservationCount, 0)
        XCTAssertTrue(item.labels.contains(.cautionDraftIncomplete))
        XCTAssertTrue(item.labels.contains(.notRecommendedForHydration))
    }

    @MainActor
    func testRemoteOnlySessionDetailDraftWithRemoteShotsStaysHydrationDebt() throws {
        let activeOrganizationID = UUID()
        let propertyID = UUID()
        let remoteSessionID = UUID()
        let fixture = try makeAppStateWithSingleSession(uploadStates: [], extraOrganizationIDs: [activeOrganizationID])
        defer {
            fixture.appState.shutdown()
            try? FileManager.default.removeItem(at: fixture.storageRoot)
        }

        let localProperties = [Property(id: propertyID, orgId: activeOrganizationID, name: "Local")]
        let report = fixture.appState._debugRemoteOnlySessionDetailReportForTests(
            localProperties: localProperties,
            localSessions: [],
            remote: AppState.DebugRemoteOnlySessionDetailInput(
                properties: localProperties,
                sessions: [
                    AppState.DebugRemoteOnlySessionInput(
                        id: remoteSessionID,
                        propertyID: propertyID,
                        status: "draft",
                        updatedAt: Date(timeIntervalSinceReferenceDate: 500)
                    )
                ],
                shots: [
                    AppState.DebugRemoteOnlySessionShotInput(sessionID: remoteSessionID)
                ],
                observations: [],
                orgID: activeOrganizationID
            ),
            activeOrganizationID: activeOrganizationID
        )

        let item = try XCTUnwrap(report.items.first)
        XCTAssertEqual(item.classification, .missingLocalHydration)
        XCTAssertTrue(item.appearsDraft)
        XCTAssertEqual(item.remoteShotCount, 1)
        XCTAssertFalse(item.labels.contains(.notRecommendedForHydration))
    }

    @MainActor
    func testRemoteOnlySessionDetailCompletedEmptySessionDoesNotClassifyAsShell() throws {
        let activeOrganizationID = UUID()
        let propertyID = UUID()
        let remoteSessionID = UUID()
        let fixture = try makeAppStateWithSingleSession(uploadStates: [], extraOrganizationIDs: [activeOrganizationID])
        defer {
            fixture.appState.shutdown()
            try? FileManager.default.removeItem(at: fixture.storageRoot)
        }

        let localProperties = [Property(id: propertyID, orgId: activeOrganizationID, name: "Local")]
        let report = fixture.appState._debugRemoteOnlySessionDetailReportForTests(
            localProperties: localProperties,
            localSessions: [],
            remote: AppState.DebugRemoteOnlySessionDetailInput(
                properties: localProperties,
                sessions: [
                    AppState.DebugRemoteOnlySessionInput(
                        id: remoteSessionID,
                        propertyID: propertyID,
                        status: "completed",
                        completedAt: "2026-01-01T01:00:00Z",
                        updatedAt: Date(timeIntervalSinceReferenceDate: 500)
                    )
                ],
                observations: [],
                orgID: activeOrganizationID
            ),
            activeOrganizationID: activeOrganizationID
        )

        let item = try XCTUnwrap(report.items.first)
        XCTAssertEqual(item.classification, .missingLocalHydration)
        XCTAssertTrue(item.appearsCompleted)
        XCTAssertTrue(item.labels.contains(.completedNoRemoteShots))
        XCTAssertFalse(item.labels.contains(.notRecommendedForHydration))
    }

    @MainActor
    func testRemoteOnlySessionDetailMissingParentStaysTrueParityOrManualReview() throws {
        let activeOrganizationID = UUID()
        let missingPropertyID = UUID()
        let remoteSessionID = UUID()
        let fixture = try makeAppStateWithSingleSession(uploadStates: [], extraOrganizationIDs: [activeOrganizationID])
        defer {
            fixture.appState.shutdown()
            try? FileManager.default.removeItem(at: fixture.storageRoot)
        }

        let report = fixture.appState._debugRemoteOnlySessionDetailReportForTests(
            localProperties: [],
            localSessions: [],
            remote: AppState.DebugRemoteOnlySessionDetailInput(
                properties: [],
                sessions: [
                    AppState.DebugRemoteOnlySessionInput(
                        id: remoteSessionID,
                        propertyID: missingPropertyID,
                        status: "draft",
                        updatedAt: Date(timeIntervalSinceReferenceDate: 500)
                    )
                ],
                observations: [],
                orgID: activeOrganizationID
            ),
            activeOrganizationID: activeOrganizationID
        )

        let item = try XCTUnwrap(report.items.first)
        XCTAssertEqual(item.classification, .trueParityDebt)
        XCTAssertFalse(item.parentPropertyExistsLocally)
        XCTAssertTrue(item.labels.contains(.parentMissingLocally))
        XCTAssertFalse(item.labels.contains(.notRecommendedForHydration))
    }

    @MainActor
    func testRemoteOnlySessionDetailMarksDraftAsCautionIncomplete() throws {
        let activeOrganizationID = UUID()
        let propertyID = UUID()
        let remoteSessionID = UUID()
        let fixture = try makeAppStateWithSingleSession(uploadStates: [], extraOrganizationIDs: [activeOrganizationID])
        defer {
            fixture.appState.shutdown()
            try? FileManager.default.removeItem(at: fixture.storageRoot)
        }

        let localProperties = [Property(id: propertyID, orgId: activeOrganizationID, name: "Local")]
        let report = fixture.appState._debugRemoteOnlySessionDetailReportForTests(
            localProperties: localProperties,
            localSessions: [],
            remote: AppState.DebugRemoteOnlySessionDetailInput(
                properties: localProperties,
                sessions: [
                    AppState.DebugRemoteOnlySessionInput(
                        id: remoteSessionID,
                        propertyID: propertyID,
                        status: "draft",
                        updatedAt: Date(timeIntervalSinceReferenceDate: 500)
                    )
                ],
                orgID: activeOrganizationID
            ),
            activeOrganizationID: activeOrganizationID
        )

        let item = try XCTUnwrap(report.items.first)
        XCTAssertTrue(item.appearsDraft)
        XCTAssertTrue(item.labels.contains(.cautionDraftIncomplete))
    }

    @MainActor
    func testRemoteOnlySessionDetailDeletedDraftStaysHistorical() throws {
        let activeOrganizationID = UUID()
        let propertyID = UUID()
        let remoteSessionID = UUID()
        let fixture = try makeAppStateWithSingleSession(uploadStates: [], extraOrganizationIDs: [activeOrganizationID])
        defer {
            fixture.appState.shutdown()
            try? FileManager.default.removeItem(at: fixture.storageRoot)
        }

        let localProperties = [Property(id: propertyID, orgId: activeOrganizationID, name: "Local")]
        let report = fixture.appState._debugRemoteOnlySessionDetailReportForTests(
            localProperties: localProperties,
            localSessions: [],
            remote: AppState.DebugRemoteOnlySessionDetailInput(
                properties: localProperties,
                sessions: [
                    AppState.DebugRemoteOnlySessionInput(
                        id: remoteSessionID,
                        propertyID: propertyID,
                        status: "draft",
                        updatedAt: Date(timeIntervalSinceReferenceDate: 500),
                        deletedAt: Date(timeIntervalSinceReferenceDate: 600)
                    )
                ],
                observations: [],
                orgID: activeOrganizationID
            ),
            activeOrganizationID: activeOrganizationID
        )

        let item = try XCTUnwrap(report.items.first)
        XCTAssertEqual(item.classification, .historicalRemoteOnly)
        XCTAssertTrue(item.appearsDeleted)
        XCTAssertTrue(item.labels.contains(.historicalDeleted))
        XCTAssertFalse(item.labels.contains(.notRecommendedForHydration))
    }

    @MainActor
    func testRemoteOnlySessionDetailActionableHydrationCountDropsForShellsAndReportIncludesRows() throws {
        let activeOrganizationID = UUID()
        let propertyID = UUID()
        let shellSessionID = UUID()
        let actionableSessionID = UUID()
        let fixture = try makeAppStateWithSingleSession(uploadStates: [], extraOrganizationIDs: [activeOrganizationID])
        defer {
            fixture.appState.shutdown()
            try? FileManager.default.removeItem(at: fixture.storageRoot)
        }

        let localProperties = [Property(id: propertyID, orgId: activeOrganizationID, name: "Local")]
        let report = fixture.appState._debugRemoteOnlySessionDetailReportForTests(
            localProperties: localProperties,
            localSessions: [],
            remote: AppState.DebugRemoteOnlySessionDetailInput(
                properties: localProperties,
                sessions: [
                    AppState.DebugRemoteOnlySessionInput(
                        id: shellSessionID,
                        propertyID: propertyID,
                        status: "draft",
                        updatedAt: Date(timeIntervalSinceReferenceDate: 500)
                    ),
                    AppState.DebugRemoteOnlySessionInput(
                        id: actionableSessionID,
                        propertyID: propertyID,
                        status: "draft",
                        updatedAt: Date(timeIntervalSinceReferenceDate: 600)
                    )
                ],
                shots: [
                    AppState.DebugRemoteOnlySessionShotInput(sessionID: actionableSessionID)
                ],
                observations: [],
                orgID: activeOrganizationID
            ),
            activeOrganizationID: activeOrganizationID
        )

        XCTAssertEqual(report.items.filter { $0.classification == .emptyRemoteDraftShell }.count, 1)
        XCTAssertEqual(report.items.filter { $0.classification == .missingLocalHydration }.count, 1)

        let text = AppState.remoteOnlySessionDetailReportText(report)
        XCTAssertTrue(text.contains(shellSessionID.uuidString))
        XCTAssertTrue(text.contains("classification: empty_remote_draft_shell"))
        XCTAssertTrue(text.contains("not_recommended_for_hydration"))
    }

    @MainActor
    func testRemoteOnlySessionDetailCompletedWithStoragePathsMarksCandidate() throws {
        let activeOrganizationID = UUID()
        let propertyID = UUID()
        let remoteSessionID = UUID()
        let fixture = try makeAppStateWithSingleSession(uploadStates: [], extraOrganizationIDs: [activeOrganizationID])
        defer {
            fixture.appState.shutdown()
            try? FileManager.default.removeItem(at: fixture.storageRoot)
        }

        let localProperties = [Property(id: propertyID, orgId: activeOrganizationID, name: "Local")]
        let report = fixture.appState._debugRemoteOnlySessionDetailReportForTests(
            localProperties: localProperties,
            localSessions: [],
            remote: AppState.DebugRemoteOnlySessionDetailInput(
                properties: localProperties,
                sessions: [
                    AppState.DebugRemoteOnlySessionInput(
                        id: remoteSessionID,
                        propertyID: propertyID,
                        status: "completed",
                        completedAt: "2026-01-01T01:00:00Z",
                        updatedAt: Date(timeIntervalSinceReferenceDate: 500)
                    )
                ],
                shots: [
                    AppState.DebugRemoteOnlySessionShotInput(
                        sessionID: remoteSessionID,
                        storageBucket: "operational-media",
                        storagePath: "org/session/shot.heic"
                    ),
                    AppState.DebugRemoteOnlySessionShotInput(sessionID: remoteSessionID)
                ],
                observations: [
                    AppState.DebugRemoteOnlySessionObservationInput(sessionID: remoteSessionID)
                ],
                orgID: activeOrganizationID
            ),
            activeOrganizationID: activeOrganizationID
        )

        let item = try XCTUnwrap(report.items.first)
        XCTAssertTrue(item.appearsCompleted)
        XCTAssertEqual(item.remoteShotCount, 2)
        XCTAssertEqual(item.remoteShotsWithStoragePathCount, 1)
        XCTAssertEqual(item.remoteIssueObservationCount, 1)
        XCTAssertTrue(item.labels.contains(.possibleHydrationCandidate))
    }

    @MainActor
    func testRemoteOnlySessionDetailInspectorDoesNotCreateLocalFolders() throws {
        let activeOrganizationID = UUID()
        let propertyID = UUID()
        let remoteSessionID = UUID()
        let fixture = try makeAppStateWithSingleSession(uploadStates: [], extraOrganizationIDs: [activeOrganizationID])
        defer {
            fixture.appState.shutdown()
            try? FileManager.default.removeItem(at: fixture.storageRoot)
        }

        let remoteSessionFolder = fixture.storageRoot
            .appendingPathComponent("SCOUT/Properties/\(propertyID.uuidString)/Sessions/\(remoteSessionID.uuidString)", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: remoteSessionFolder.path))

        let localProperties = [Property(id: propertyID, orgId: activeOrganizationID, name: "Local")]
        let report = fixture.appState._debugRemoteOnlySessionDetailReportForTests(
            localProperties: localProperties,
            localSessions: [],
            remote: AppState.DebugRemoteOnlySessionDetailInput(
                properties: localProperties,
                sessions: [
                    AppState.DebugRemoteOnlySessionInput(
                        id: remoteSessionID,
                        propertyID: propertyID,
                        status: "completed",
                        updatedAt: Date(timeIntervalSinceReferenceDate: 500)
                    )
                ],
                orgID: activeOrganizationID
            ),
            activeOrganizationID: activeOrganizationID
        )

        let item = try XCTUnwrap(report.items.first)
        XCTAssertFalse(item.localSessionFolderExists)
        XCTAssertFalse(item.localSessionJSONExists)
        XCTAssertFalse(item.localOriginalsFolderExists)
        XCTAssertFalse(FileManager.default.fileExists(atPath: remoteSessionFolder.path))
        XCTAssertEqual(fixture.appState.sessions(for: fixture.propertyID).count, 1)
    }

    @MainActor
    func testSyncDebtInspectorClassifiesRemoteOnlyShotLegacyArtifactAndManualReviewFallback() throws {
        let activeOrganizationID = UUID()
        let propertyID = UUID()
        let sessionID = UUID()
        let legacyShotID = UUID()
        let unknownShotID = UUID()
        let fixture = try makeAppStateWithSingleSession(uploadStates: [], extraOrganizationIDs: [activeOrganizationID])
        defer {
            fixture.appState.shutdown()
            try? FileManager.default.removeItem(at: fixture.storageRoot)
        }

        let localProperties = [
            Property(
                id: propertyID,
                orgId: activeOrganizationID,
                name: "Local",
                address: "123 Main Street"
            )
        ]
        let localSessions = [Session(id: sessionID, propertyID: propertyID)]
        let remote = AppState.DebugDivergenceRemoteInput(
            propertyIDs: [propertyID.uuidString],
            sessions: [(id: sessionID.uuidString, propertyID: propertyID.uuidString)],
            shots: [
                (id: legacyShotID.uuidString, propertyID: propertyID.uuidString, sessionID: sessionID.uuidString),
                (id: unknownShotID.uuidString, propertyID: propertyID.uuidString, sessionID: sessionID.uuidString)
            ],
            shotLifecycleStates: [legacyShotID.uuidString.lowercased(): "superseded"],
            orgID: activeOrganizationID
        )
        let summary = fixture.appState._debugDivergenceAuditSummaryForTests(
            properties: localProperties,
            sessions: localSessions,
            shots: [],
            remote: remote,
            activeOrganizationID: activeOrganizationID
        )

        let report = fixture.appState._debugSyncDebtInspectionReportForTests(
            properties: localProperties,
            sessions: localSessions,
            shots: [],
            remote: remote,
            divergenceAuditSummary: summary,
            activeOrganizationID: activeOrganizationID
        )

        let legacy = try XCTUnwrap(report.divergenceItems.first { $0.shotID == legacyShotID })
        let unknown = try XCTUnwrap(report.divergenceItems.first { $0.shotID == unknownShotID })
        XCTAssertEqual(legacy.classification, .knownLegacyArtifact)
        XCTAssertEqual(unknown.classification, .manualReview)
    }

    func testDivergenceAuditSummarySeparatesOperationalAndHistoricalCounts() throws {
        let summary = AppState.DivergenceAuditSummary(
            ranAt: Date(timeIntervalSince1970: 0),
            activeOrganizationID: UUID(),
            remoteScopeAvailable: true,
            localPropertyCount: 0,
            remotePropertyCount: 0,
            localSessionCount: 0,
            remoteSessionCount: 0,
            localShotCount: 0,
            remoteShotCount: 0,
            matchedPropertyCount: 0,
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
                    category: .missingParent,
                    entityType: "shot",
                    entityID: UUID(),
                    reason: "true missing parent"
                ),
                AppState.DivergenceAuditItem(
                    category: .mediaDrift,
                    entityType: "shot",
                    entityID: UUID(),
                    reason: "retry-capped"
                ),
                AppState.DivergenceAuditItem(
                    category: .legacyCaptureProfile,
                    entityType: "property",
                    entityID: UUID(),
                    reason: "legacy null"
                ),
                AppState.DivergenceAuditItem(
                    category: .legacyRemoteSchema,
                    entityType: "shot",
                    entityID: UUID(),
                    reason: "legacy null property_id"
                ),
                AppState.DivergenceAuditItem(
                    category: .legacyOrgReconciliation,
                    entityType: "property",
                    entityID: UUID(),
                    reason: "historical org metadata reconciled"
                )
            ]
        )

        XCTAssertEqual(summary.activeSyncIssueCount, 1)
        XCTAssertEqual(summary.recoverableIssueCount, 1)
        XCTAssertEqual(summary.historicalInformationalCount, 3)
    }

    func testDivergenceAuditGroupedHistoricalSummariesCountAffectedEntities() throws {
        let propertyA = UUID()
        let propertyB = UUID()
        let sessionA = UUID()
        let sessionB = UUID()
        let shotA = UUID()
        let shotB = UUID()
        let items: [AppState.DivergenceAuditItem] = [
            AppState.DivergenceAuditItem(
                category: .legacyOrgReconciliation,
                entityType: "property",
                entityID: propertyA,
                propertyID: propertyA,
                reason: "historical org reconciled"
            ),
            AppState.DivergenceAuditItem(
                category: .legacyOrgReconciliation,
                entityType: "shot",
                entityID: shotA,
                propertyID: propertyA,
                sessionID: sessionA,
                shotID: shotA,
                reason: "historical org reconciled"
            ),
            AppState.DivergenceAuditItem(
                category: .legacyRemoteSchema,
                entityType: "shot",
                entityID: shotA,
                propertyID: propertyA,
                sessionID: sessionA,
                shotID: shotA,
                reason: "legacy remote schema"
            ),
            AppState.DivergenceAuditItem(
                category: .legacyRemoteSchema,
                entityType: "shot",
                entityID: shotB,
                propertyID: propertyB,
                sessionID: sessionB,
                shotID: shotB,
                reason: "legacy remote schema"
            ),
            AppState.DivergenceAuditItem(
                category: .legacyCaptureProfile,
                entityType: "property",
                entityID: propertyA,
                propertyID: propertyA,
                reason: "legacy capture profile"
            ),
            AppState.DivergenceAuditItem(
                category: .legacyCaptureProfile,
                entityType: "session",
                entityID: sessionB,
                propertyID: propertyB,
                sessionID: sessionB,
                reason: "legacy capture profile"
            )
        ]

        let groups = AppState.DivergenceAuditSummary.groupedHistoricalFindings(in: items)
        let staleOrg = try XCTUnwrap(groups.first { $0.category == .legacyOrgReconciliation })
        let legacySchema = try XCTUnwrap(groups.first { $0.category == .legacyRemoteSchema })
        let legacyProfile = try XCTUnwrap(groups.first { $0.category == .legacyCaptureProfile })

        XCTAssertEqual(staleOrg.totalCount, 2)
        XCTAssertEqual(staleOrg.affectedPropertyCount, 1)
        XCTAssertEqual(staleOrg.affectedSessionCount, 1)
        XCTAssertEqual(staleOrg.affectedShotCount, 1)
        XCTAssertEqual(legacySchema.totalCount, 2)
        XCTAssertEqual(legacySchema.affectedPropertyCount, 2)
        XCTAssertEqual(legacySchema.affectedSessionCount, 2)
        XCTAssertEqual(legacySchema.affectedShotCount, 2)
        XCTAssertEqual(legacyProfile.totalCount, 2)
        XCTAssertEqual(legacyProfile.affectedPropertyCount, 2)
        XCTAssertEqual(legacyProfile.affectedSessionCount, 1)
    }

    func testDivergenceAuditGroupedHistoricalSummariesPreserveRawFindingsAndSamplesOnly() throws {
        let propertyID = UUID()
        let rawItems = (0..<8).map { index in
            AppState.DivergenceAuditItem(
                category: .legacyCaptureProfile,
                entityType: "session",
                entityID: UUID(),
                propertyID: propertyID,
                sessionID: UUID(),
                reason: "legacy capture profile \(index)"
            )
        }

        let groups = AppState.DivergenceAuditSummary.groupedHistoricalFindings(
            in: rawItems,
            sampleLimit: 3
        )
        let group = try XCTUnwrap(groups.first { $0.category == .legacyCaptureProfile })

        XCTAssertEqual(rawItems.count, 8)
        XCTAssertEqual(group.totalCount, 8)
        XCTAssertEqual(group.sampleItems.count, 3)
        XCTAssertEqual(group.affectedPropertyCount, 1)
        XCTAssertEqual(group.affectedSessionCount, 8)
    }

    func testDivergenceAuditFindingFilterMatchesSeverityCategoryAndText() throws {
        let propertyID = UUID()
        let sessionID = UUID()
        let shotID = UUID()
        let items: [AppState.DivergenceAuditItem] = [
            AppState.DivergenceAuditItem(
                category: .missingParent,
                entityType: "shot",
                entityID: shotID,
                propertyID: propertyID,
                sessionID: sessionID,
                shotID: shotID,
                reason: "True parent break"
            ),
            AppState.DivergenceAuditItem(
                category: .legacyCaptureProfile,
                entityType: "session",
                entityID: sessionID,
                propertyID: propertyID,
                sessionID: sessionID,
                reason: "Legacy profile null"
            ),
            AppState.DivergenceAuditItem(
                category: .mediaDrift,
                entityType: "shot",
                entityID: UUID(),
                reason: "Retry-capped upload"
            )
        ]

        let warnings = AppState.DivergenceAuditSummary.filteredItems(
            items,
            matching: AppState.DivergenceAuditFindingFilter(severity: .warning)
        )
        let legacyProfiles = AppState.DivergenceAuditSummary.filteredItems(
            items,
            matching: AppState.DivergenceAuditFindingFilter(category: .legacyCaptureProfile)
        )
        let sessionMatches = AppState.DivergenceAuditSummary.filteredItems(
            items,
            matching: AppState.DivergenceAuditFindingFilter(entityType: "session")
        )
        let idSearchMatches = AppState.DivergenceAuditSummary.filteredItems(
            items,
            matching: AppState.DivergenceAuditFindingFilter(searchText: shotID.uuidString.lowercased())
        )
        let reasonSearchMatches = AppState.DivergenceAuditSummary.filteredItems(
            items,
            matching: AppState.DivergenceAuditFindingFilter(searchText: "retry-capped")
        )

        XCTAssertEqual(warnings.map(\.category), [.missingParent])
        XCTAssertEqual(legacyProfiles.map(\.category), [.legacyCaptureProfile])
        XCTAssertEqual(sessionMatches.map(\.entityType), ["session"])
        XCTAssertEqual(idSearchMatches.map(\.shotID), [shotID])
        XCTAssertEqual(reasonSearchMatches.map(\.category), [.mediaDrift])
        XCTAssertEqual(items.count, 3)
    }

    func testDivergenceAuditFindingFilterDoesNotChangeSnapshotOutput() throws {
        let shotID = UUID()
        let summary = AppState.DivergenceAuditSummary(
            ranAt: Date(timeIntervalSince1970: 0),
            activeOrganizationID: UUID(),
            remoteScopeAvailable: true,
            localPropertyCount: 0,
            remotePropertyCount: 0,
            localSessionCount: 0,
            remoteSessionCount: 0,
            localShotCount: 0,
            remoteShotCount: 0,
            matchedPropertyCount: 0,
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
                    category: .missingParent,
                    entityType: "shot",
                    entityID: shotID,
                    shotID: shotID,
                    reason: "True parent break"
                ),
                AppState.DivergenceAuditItem(
                    category: .legacyCaptureProfile,
                    entityType: "session",
                    entityID: UUID(),
                    reason: "Legacy profile null"
                )
            ]
        )

        let filtered = summary.filteredItems(
            matching: AppState.DivergenceAuditFindingFilter(category: .missingParent)
        )
        let snapshot = AppState.divergenceAuditSnapshotText(summary)

        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(summary.items.count, 2)
        XCTAssertTrue(snapshot.contains("Warning | missing_parent"))
        XCTAssertTrue(snapshot.contains("Info | legacy_capture_profile"))
    }

    func testMediaRecoveryInspectionMapsRetryCappedLocalMediaAndFileExists() async throws {
        let now = Date()
        let fixture = try makeAppStateWithSingleSession(
            uploadStates: [("failed", 5, now)]
        )
        defer {
            fixture.appState.shutdown()
            try? FileManager.default.removeItem(at: fixture.storageRoot)
        }

        let shot = try XCTUnwrap(fixture.shots.first)
        try createOriginalFile(
            storageRoot: fixture.storageRoot,
            propertyID: fixture.propertyID,
            sessionID: fixture.sessionID,
            shot: shot
        )

        let summary = await fixture.appState.inspectMediaRecoveryCandidates()

        XCTAssertEqual(summary.candidatesFound, 1)
        let candidate = try XCTUnwrap(summary.candidates.first)
        XCTAssertEqual(candidate.shotID, shot.shotID)
        XCTAssertTrue(candidate.fileExists)
        XCTAssertEqual(candidate.localFilename, shot.originalFilename)
        XCTAssertEqual(candidate.classification, .needsManualReview)
        XCTAssertTrue(candidate.sourceReasons.contains("retry_capped_media"))
    }

    func testMediaRecoveryInspectionFlagsStaleLocalOrg() throws {
        let now = Date()
        let staleOrganizationID = UUID()
        let activeOrganizationID = UUID()
        let fixture = try makeAppStateWithSingleSession(
            uploadStates: [("failed", 5, now)],
            propertyOrganizationID: staleOrganizationID,
            metadataOrganizationID: staleOrganizationID,
            extraOrganizationIDs: [activeOrganizationID]
        )
        defer {
            fixture.appState.shutdown()
            try? FileManager.default.removeItem(at: fixture.storageRoot)
        }

        let shot = try XCTUnwrap(fixture.shots.first)
        try createOriginalFile(
            storageRoot: fixture.storageRoot,
            propertyID: fixture.propertyID,
            sessionID: fixture.sessionID,
            shot: shot
        )

        let summary = fixture.appState._debugMediaRecoveryInspectionSummaryForTests(
            properties: [
                Property(
                    id: fixture.propertyID,
                    orgId: staleOrganizationID,
                    name: "Property",
                    address: "123 Main Street"
                )
            ],
            sessions: [
                Session(id: fixture.sessionID, propertyID: fixture.propertyID, startedAt: now, status: .draft)
            ],
            shots: [
                AppState.DebugDivergenceLocalShotInput(
                    shot: shot,
                    propertyID: fixture.propertyID,
                    sessionID: fixture.sessionID,
                    metadataOrgID: staleOrganizationID,
                    metadataCaptureProfile: nil
                )
            ],
            remote: AppState.DebugDivergenceRemoteInput(
                propertyIDs: [fixture.propertyID.uuidString],
                sessions: [(fixture.sessionID.uuidString, fixture.propertyID.uuidString)],
                orgID: activeOrganizationID
            ),
            activeOrganizationID: activeOrganizationID
        )

        let candidate = try XCTUnwrap(summary.candidates.first)
        XCTAssertTrue(candidate.staleLocalOrg)
        XCTAssertEqual(candidate.classification, .needsOrgReconciliation)
    }

    func testMediaRecoveryClassificationMapping() {
        XCTAssertEqual(
            AppState.mediaRecoveryClassification(
                fileExists: false,
                staleLocalOrg: false,
                remotePreflightAvailable: true,
                remotePropertyExists: true,
                remoteSessionExists: true,
                remoteShotExists: false,
                remoteStoragePathPresent: nil,
                remoteUploadState: nil
            ),
            .missingLocalFile
        )
        XCTAssertEqual(
            AppState.mediaRecoveryClassification(
                fileExists: true,
                staleLocalOrg: false,
                remotePreflightAvailable: true,
                remotePropertyExists: true,
                remoteSessionExists: true,
                remoteShotExists: true,
                remoteStoragePathPresent: true,
                remoteUploadState: "uploaded"
            ),
            .alreadyRemoteComplete
        )
        XCTAssertEqual(
            AppState.mediaRecoveryClassification(
                fileExists: true,
                staleLocalOrg: false,
                remotePreflightAvailable: true,
                remotePropertyExists: false,
                remoteSessionExists: true,
                remoteShotExists: false,
                remoteStoragePathPresent: nil,
                remoteUploadState: nil
            ),
            .missingRemoteParent
        )
        XCTAssertEqual(
            AppState.mediaRecoveryClassification(
                fileExists: true,
                staleLocalOrg: false,
                remotePreflightAvailable: true,
                remotePropertyExists: true,
                remoteSessionExists: true,
                remoteShotExists: false,
                remoteStoragePathPresent: nil,
                remoteUploadState: nil
            ),
            .retryable
        )
    }

    func testMediaRecoveryImportanceHintMapping() {
        XCTAssertEqual(
            AppState.mediaRecoveryImportanceHint(
                sessionStatus: "completed",
                sessionIsSealed: false,
                shotIsFlagged: false
            ),
            "Completed or sealed session; likely important."
        )
        XCTAssertEqual(
            AppState.mediaRecoveryImportanceHint(
                sessionStatus: "draft",
                sessionIsSealed: false,
                shotIsFlagged: false
            ),
            "Draft session; manual review before any future repair."
        )
        XCTAssertEqual(
            AppState.mediaRecoveryImportanceHint(
                sessionStatus: "draft",
                sessionIsSealed: false,
                shotIsFlagged: true
            ),
            "Flagged shot; likely needs review."
        )
    }

    func testMediaRecoverySnapshotTextIncludesCountsAndRedactsSensitiveValues() throws {
        let now = Date(timeIntervalSince1970: 0)
        let fixture = try makeAppStateWithSingleSession(uploadStates: [])
        defer {
            fixture.appState.shutdown()
            try? FileManager.default.removeItem(at: fixture.storageRoot)
        }

        let shotID = UUID()
        var shot = makeShot(
            propertyID: fixture.propertyID,
            sessionID: fixture.sessionID,
            shotID: shotID,
            uploadState: "failed",
            uploadAttempts: 5,
            angleIndex: 1,
            shotKey: "building|front|overview|1",
            updatedAt: now
        )
        shot.lastUploadError = "Failed at /private/tmp/secret.heic with bearer abc"

        let summary = fixture.appState._debugMediaRecoveryInspectionSummaryForTests(
            properties: [
                Property(
                    id: fixture.propertyID,
                    name: "Property",
                    address: "123 Main Street"
                )
            ],
            sessions: [
                Session(
                    id: fixture.sessionID,
                    propertyID: fixture.propertyID,
                    startedAt: now,
                    status: .completed,
                    isSealed: true
                )
            ],
            shots: [
                AppState.DebugDivergenceLocalShotInput(
                    shot: shot,
                    propertyID: fixture.propertyID,
                    sessionID: fixture.sessionID,
                    metadataOrgID: nil,
                    metadataCaptureProfile: nil
                )
            ],
            inspectedAt: now
        )

        let snapshot = AppState.mediaRecoverySnapshotText(summary)

        XCTAssertTrue(snapshot.contains("Media Recovery Candidates"))
        XCTAssertTrue(snapshot.contains("Candidates Found: 1"))
        XCTAssertTrue(snapshot.contains("Completed or sealed session; likely important."))
        XCTAssertTrue(snapshot.contains("Retry-capped does not mean lost"))
        XCTAssertTrue(snapshot.contains("[path]"))
        XCTAssertFalse(snapshot.contains("/private/tmp"))
        XCTAssertFalse(snapshot.contains("abc"))
    }

    func testMediaRecoveryInspectionSanitizesErrorAndDoesNotExposeFullPath() throws {
        let now = Date()
        let fixture = try makeAppStateWithSingleSession(uploadStates: [])
        defer {
            fixture.appState.shutdown()
            try? FileManager.default.removeItem(at: fixture.storageRoot)
        }

        let shotID = UUID()
        var shot = makeShot(
            propertyID: fixture.propertyID,
            sessionID: fixture.sessionID,
            shotID: shotID,
            uploadState: "failed",
            uploadAttempts: 5,
            angleIndex: 1,
            shotKey: "building|front|overview|1",
            updatedAt: now
        )
        shot.lastUploadError = "Failed reading /private/tmp/secret.heic with token abc"

        let summary = fixture.appState._debugMediaRecoveryInspectionSummaryForTests(
            properties: [
                Property(
                    id: fixture.propertyID,
                    name: "Property",
                    address: "123 Main Street"
                )
            ],
            sessions: [
                Session(id: fixture.sessionID, propertyID: fixture.propertyID, startedAt: now, status: .draft)
            ],
            shots: [
                AppState.DebugDivergenceLocalShotInput(
                    shot: shot,
                    propertyID: fixture.propertyID,
                    sessionID: fixture.sessionID,
                    metadataOrgID: nil,
                    metadataCaptureProfile: nil
                )
            ]
        )

        let candidate = try XCTUnwrap(summary.candidates.first)
        XCTAssertEqual(candidate.localFilename, "\(shotID.uuidString).heic")
        XCTAssertFalse(candidate.localFilename?.contains("/") ?? true)
        XCTAssertFalse(candidate.lastUploadError?.contains("/private/tmp") ?? true)
        XCTAssertFalse(candidate.lastUploadError?.contains("abc") ?? true)
    }

    func testMediaRecoveryRetryBlockedWhenLocalFileMissing() async throws {
        let now = Date()
        let activeOrganizationID = UUID()
        let fixture = try makeAppStateWithSingleSession(
            uploadStates: [("failed", 5, now)],
            propertyOrganizationID: activeOrganizationID
        )
        defer {
            fixture.appState.shutdown()
            try? FileManager.default.removeItem(at: fixture.storageRoot)
        }
        await fixture.appState._debugSetOfflineReplayEnvironmentForTests(
            activeOrganizationID: activeOrganizationID,
            clientConfigured: false
        )
        fixture.appState._debugSetMediaRecoveryRemoteSnapshotForTests(
            AppState.DebugDivergenceRemoteInput(
                propertyIDs: [fixture.propertyID.uuidString],
                sessions: [(fixture.sessionID.uuidString, fixture.propertyID.uuidString)],
                orgID: activeOrganizationID
            )
        )

        let result = await fixture.appState.retryMediaRecoveryCandidate(
            propertyID: fixture.propertyID,
            sessionID: fixture.sessionID,
            shotID: try XCTUnwrap(fixture.shots.first?.shotID)
        )

        XCTAssertEqual(result.status, .blocked)
        XCTAssertTrue(result.message.localizedCaseInsensitiveContains("local media file is missing"))
    }

    func testMediaRecoveryRetryBlockedWhenRemoteParentMissing() async throws {
        let now = Date()
        let activeOrganizationID = UUID()
        let fixture = try makeAppStateWithSingleSession(
            uploadStates: [("failed", 5, now)],
            propertyOrganizationID: activeOrganizationID
        )
        defer {
            fixture.appState.shutdown()
            try? FileManager.default.removeItem(at: fixture.storageRoot)
        }
        let shot = try XCTUnwrap(fixture.shots.first)
        try createOriginalFile(
            storageRoot: fixture.storageRoot,
            propertyID: fixture.propertyID,
            sessionID: fixture.sessionID,
            shot: shot
        )
        await fixture.appState._debugSetOfflineReplayEnvironmentForTests(
            activeOrganizationID: activeOrganizationID,
            clientConfigured: false
        )
        fixture.appState._debugSetMediaRecoveryRemoteSnapshotForTests(
            AppState.DebugDivergenceRemoteInput(
                propertyIDs: [],
                orgID: activeOrganizationID
            )
        )

        let result = await fixture.appState.retryMediaRecoveryCandidate(
            propertyID: fixture.propertyID,
            sessionID: fixture.sessionID,
            shotID: shot.shotID
        )

        XCTAssertEqual(result.status, .blocked)
        XCTAssertTrue(result.message.localizedCaseInsensitiveContains("remote property"))
    }

    func testMediaRecoveryRetryBlockedWhenAlreadyRemoteComplete() async throws {
        let now = Date()
        let activeOrganizationID = UUID()
        let fixture = try makeAppStateWithSingleSession(
            uploadStates: [("failed", 5, now)],
            propertyOrganizationID: activeOrganizationID
        )
        defer {
            fixture.appState.shutdown()
            try? FileManager.default.removeItem(at: fixture.storageRoot)
        }
        let shot = try XCTUnwrap(fixture.shots.first)
        try createOriginalFile(
            storageRoot: fixture.storageRoot,
            propertyID: fixture.propertyID,
            sessionID: fixture.sessionID,
            shot: shot
        )
        await fixture.appState._debugSetOfflineReplayEnvironmentForTests(
            activeOrganizationID: activeOrganizationID,
            clientConfigured: false
        )
        fixture.appState._debugSetMediaRecoveryRemoteSnapshotForTests(
            AppState.DebugDivergenceRemoteInput(
                propertyIDs: [fixture.propertyID.uuidString],
                sessions: [(fixture.sessionID.uuidString, fixture.propertyID.uuidString)],
                shots: [(shot.shotID.uuidString, fixture.propertyID.uuidString, fixture.sessionID.uuidString)],
                orgID: activeOrganizationID
            )
        )

        let result = await fixture.appState.retryMediaRecoveryCandidate(
            propertyID: fixture.propertyID,
            sessionID: fixture.sessionID,
            shotID: shot.shotID
        )

        XCTAssertEqual(result.status, .blocked)
        XCTAssertTrue(result.message.localizedCaseInsensitiveContains("already"))
    }

    func testMediaRecoveryRetryUsesActiveReconciledOrgAndMarksUploadedAfterSuccess() async throws {
        let now = Date()
        let staleOrganizationID = UUID()
        let activeOrganizationID = UUID()
        let fixture = try makeAppStateWithSingleSession(
            uploadStates: [("failed", 5, now)],
            propertyOrganizationID: staleOrganizationID,
            metadataOrganizationID: staleOrganizationID,
            extraOrganizationIDs: [activeOrganizationID]
        )
        defer {
            fixture.appState.shutdown()
            try? FileManager.default.removeItem(at: fixture.storageRoot)
        }
        let shot = try XCTUnwrap(fixture.shots.first)
        try createOriginalFile(
            storageRoot: fixture.storageRoot,
            propertyID: fixture.propertyID,
            sessionID: fixture.sessionID,
            shot: shot
        )
        await fixture.appState._debugSetOfflineReplayEnvironmentForTests(
            activeOrganizationID: activeOrganizationID,
            clientConfigured: false
        )
        fixture.appState._debugSetMediaRecoveryRemoteSnapshotForTests(
            AppState.DebugDivergenceRemoteInput(
                propertyIDs: [fixture.propertyID.uuidString],
                sessions: [(fixture.sessionID.uuidString, fixture.propertyID.uuidString)],
                orgID: activeOrganizationID
            )
        )
        var retryOrgID: UUID?
        fixture.appState._debugSetMediaRecoveryUploadOverrideForTests { orgID, _, _, _ in
            retryOrgID = orgID
        }

        let result = await fixture.appState.retryMediaRecoveryCandidate(
            propertyID: fixture.propertyID,
            sessionID: fixture.sessionID,
            shotID: shot.shotID
        )
        let metadata = try fixture.appState._debugLoadSessionMetadataForTests(
            propertyID: fixture.propertyID,
            sessionID: fixture.sessionID
        )
        let updatedShot = try XCTUnwrap(metadata.shots.first { $0.shotID == shot.shotID })

        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(retryOrgID, activeOrganizationID)
        XCTAssertEqual(updatedShot.uploadState, "uploaded")
        XCTAssertNil(updatedShot.lastUploadError)
    }

    func testMediaRecoveryInspectionAfterOrgSwitchDropsPreviousOrgCandidates() throws {
        let now = Date()
        let oldOrganizationID = UUID()
        let newOrganizationID = UUID()
        let fixture = try makeAppStateWithSingleSession(
            uploadStates: [("failed", 5, now)],
            propertyOrganizationID: oldOrganizationID,
            metadataOrganizationID: oldOrganizationID,
            extraOrganizationIDs: [newOrganizationID]
        )
        defer {
            fixture.appState.shutdown()
            try? FileManager.default.removeItem(at: fixture.storageRoot)
        }
        let shot = try XCTUnwrap(fixture.shots.first)

        let oldSummary = fixture.appState._debugMediaRecoveryInspectionSummaryForTests(
            properties: [Property(id: fixture.propertyID, orgId: oldOrganizationID, name: "Property", address: "123 Main")],
            sessions: [Session(id: fixture.sessionID, propertyID: fixture.propertyID, startedAt: now, status: .draft)],
            shots: [
                AppState.DebugDivergenceLocalShotInput(
                    shot: shot,
                    propertyID: fixture.propertyID,
                    sessionID: fixture.sessionID,
                    metadataOrgID: oldOrganizationID,
                    metadataCaptureProfile: nil
                )
            ],
            remote: AppState.DebugDivergenceRemoteInput(
                propertyIDs: [fixture.propertyID.uuidString],
                sessions: [(fixture.sessionID.uuidString, fixture.propertyID.uuidString)],
                orgID: oldOrganizationID
            ),
            activeOrganizationID: oldOrganizationID
        )
        let newSummary = fixture.appState._debugMediaRecoveryInspectionSummaryForTests(
            properties: [Property(id: fixture.propertyID, orgId: oldOrganizationID, name: "Property", address: "123 Main")],
            sessions: [Session(id: fixture.sessionID, propertyID: fixture.propertyID, startedAt: now, status: .draft)],
            shots: [
                AppState.DebugDivergenceLocalShotInput(
                    shot: shot,
                    propertyID: fixture.propertyID,
                    sessionID: fixture.sessionID,
                    metadataOrgID: oldOrganizationID,
                    metadataCaptureProfile: nil
                )
            ],
            remote: AppState.DebugDivergenceRemoteInput(propertyIDs: [], orgID: newOrganizationID),
            activeOrganizationID: newOrganizationID
        )

        XCTAssertEqual(oldSummary.candidatesFound, 1)
        XCTAssertEqual(newSummary.candidatesFound, 0)
    }

    func testMediaRecoveryInspectionIgnoresStaleDivergenceAuditSnapshot() throws {
        let now = Date()
        let oldOrganizationID = UUID()
        let activeOrganizationID = UUID()
        let fixture = try makeAppStateWithSingleSession(uploadStates: [])
        defer {
            fixture.appState.shutdown()
            try? FileManager.default.removeItem(at: fixture.storageRoot)
        }
        let shot = makeShot(
            propertyID: fixture.propertyID,
            sessionID: fixture.sessionID,
            uploadState: "failed",
            uploadAttempts: 1,
            angleIndex: 1,
            shotKey: "building|front|overview|1",
            updatedAt: now
        )
        let staleAudit = AppState.DivergenceAuditSummary(
            ranAt: now,
            activeOrganizationID: oldOrganizationID,
            remoteScopeAvailable: true,
            localPropertyCount: 1,
            remotePropertyCount: 1,
            localSessionCount: 1,
            remoteSessionCount: 1,
            localShotCount: 1,
            remoteShotCount: 0,
            matchedPropertyCount: 1,
            matchedSessionCount: 1,
            matchedShotCount: 0,
            localOnlyPropertyCount: 0,
            remoteOnlyPropertyCount: 0,
            localOnlySessionCount: 0,
            remoteOnlySessionCount: 0,
            localOnlyShotCount: 1,
            remoteOnlyShotCount: 0,
            staleOrgReconciledPropertyCount: 0,
            staleOrgReconciledShotCount: 0,
            items: [
                AppState.DivergenceAuditItem(
                    category: .localOnlyShot,
                    entityType: "shot",
                    entityID: shot.shotID,
                    propertyID: fixture.propertyID,
                    sessionID: fixture.sessionID,
                    shotID: shot.shotID,
                    orgID: oldOrganizationID,
                    reason: "Local-only shot."
                )
            ]
        )
        let summary = fixture.appState._debugMediaRecoveryInspectionSummaryForTests(
            properties: [Property(id: fixture.propertyID, orgId: activeOrganizationID, name: "Property", address: "123 Main")],
            sessions: [Session(id: fixture.sessionID, propertyID: fixture.propertyID, startedAt: now, status: .draft)],
            shots: [
                AppState.DebugDivergenceLocalShotInput(
                    shot: shot,
                    propertyID: fixture.propertyID,
                    sessionID: fixture.sessionID,
                    metadataOrgID: activeOrganizationID,
                    metadataCaptureProfile: nil
                )
            ],
            remote: AppState.DebugDivergenceRemoteInput(
                propertyIDs: [fixture.propertyID.uuidString],
                sessions: [(fixture.sessionID.uuidString, fixture.propertyID.uuidString)],
                orgID: activeOrganizationID
            ),
            divergenceAuditSummary: staleAudit,
            activeOrganizationID: activeOrganizationID
        )

        XCTAssertEqual(summary.candidatesFound, 0)
    }

    func testMediaRecoveryInspectionExcludesRetryCappedMediaFromWrongOrg() throws {
        let now = Date()
        let wrongOrganizationID = UUID()
        let activeOrganizationID = UUID()
        let fixture = try makeAppStateWithSingleSession(
            uploadStates: [("failed", 5, now)],
            propertyOrganizationID: wrongOrganizationID,
            metadataOrganizationID: wrongOrganizationID,
            extraOrganizationIDs: [activeOrganizationID]
        )
        defer {
            fixture.appState.shutdown()
            try? FileManager.default.removeItem(at: fixture.storageRoot)
        }
        let shot = try XCTUnwrap(fixture.shots.first)
        let summary = fixture.appState._debugMediaRecoveryInspectionSummaryForTests(
            properties: [Property(id: fixture.propertyID, orgId: wrongOrganizationID, name: "Property", address: "123 Main")],
            sessions: [Session(id: fixture.sessionID, propertyID: fixture.propertyID, startedAt: now, status: .draft)],
            shots: [
                AppState.DebugDivergenceLocalShotInput(
                    shot: shot,
                    propertyID: fixture.propertyID,
                    sessionID: fixture.sessionID,
                    metadataOrgID: wrongOrganizationID,
                    metadataCaptureProfile: nil
                )
            ],
            remote: AppState.DebugDivergenceRemoteInput(propertyIDs: [], orgID: activeOrganizationID),
            activeOrganizationID: activeOrganizationID
        )

        XCTAssertEqual(summary.candidatesFound, 0)
    }

    func testMediaRecoveryRetryBlockedForCandidateOrgMismatch() async throws {
        let now = Date()
        let wrongOrganizationID = UUID()
        let activeOrganizationID = UUID()
        let fixture = try makeAppStateWithSingleSession(
            uploadStates: [("failed", 5, now)],
            propertyOrganizationID: wrongOrganizationID,
            metadataOrganizationID: wrongOrganizationID,
            extraOrganizationIDs: [activeOrganizationID]
        )
        defer {
            fixture.appState.shutdown()
            try? FileManager.default.removeItem(at: fixture.storageRoot)
        }
        let shot = try XCTUnwrap(fixture.shots.first)
        try createOriginalFile(
            storageRoot: fixture.storageRoot,
            propertyID: fixture.propertyID,
            sessionID: fixture.sessionID,
            shot: shot
        )
        await fixture.appState._debugSetOfflineReplayEnvironmentForTests(
            activeOrganizationID: activeOrganizationID,
            clientConfigured: false
        )
        fixture.appState._debugSetMediaRecoveryRemoteSnapshotForTests(
            AppState.DebugDivergenceRemoteInput(
                propertyIDs: [fixture.propertyID.uuidString],
                sessions: [(fixture.sessionID.uuidString, fixture.propertyID.uuidString)],
                orgID: wrongOrganizationID
            )
        )

        let result = await fixture.appState.retryMediaRecoveryCandidate(
            propertyID: fixture.propertyID,
            sessionID: fixture.sessionID,
            shotID: shot.shotID
        )

        XCTAssertEqual(result.status, .blocked)
        XCTAssertTrue(result.message.localizedCaseInsensitiveContains("remote property"))
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
