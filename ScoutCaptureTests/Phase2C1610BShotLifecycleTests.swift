import XCTest
@testable import ScoutCapture

final class Phase2C1610BShotLifecycleTests: XCTestCase {
    private func makeTempStorageRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScoutCapture-2C1610Lifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeShot(
        shotID: UUID = UUID(),
        propertyID: UUID = UUID(),
        sessionID: UUID = UUID(),
        createdAt: Date = Date(timeIntervalSinceReferenceDate: 100),
        originalFilename: String = "shot.heic",
        originalRelativePath: String = "Originals/shot.heic",
        lifecycleState: ShotLifecycleState = .active,
        retiredAt: Date? = nil,
        retiredReason: String? = nil,
        retiredByUserID: UUID? = nil,
        supersededByShotID: UUID? = nil,
        supersedesShotID: UUID? = nil,
        replacementReason: String? = nil,
        hiddenFromReports: Bool? = nil,
        hiddenFromGallery: Bool? = nil,
        lifecycleUpdatedAt: Date? = nil
    ) -> ShotMetadata {
        ShotMetadata(
            shotID: shotID,
            propertyID: propertyID,
            sessionID: sessionID,
            createdAt: createdAt,
            capturedAtLocal: nil,
            updatedAt: createdAt,
            building: "Building",
            elevation: "North",
            detailType: "Overview",
            angleIndex: 1,
            trade: nil,
            priority: nil,
            shotKey: "building|north|overview|1",
            isGuided: false,
            isFlagged: false,
            issueID: nil,
            issueStatus: nil,
            captureKind: nil,
            firstCaptureKind: nil,
            noteText: nil,
            noteCategory: nil,
            originalFilename: originalFilename,
            originalRelativePath: originalRelativePath,
            originalByteSize: 128,
            storageBucket: nil,
            storagePath: nil,
            checksumSHA256: nil,
            byteSize: 128,
            uploadState: "pending",
            uploadAttempts: 0,
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
            imageHeight: nil,
            lifecycleState: lifecycleState,
            retiredAt: retiredAt,
            retiredReason: retiredReason,
            retiredByUserID: retiredByUserID,
            supersededByShotID: supersededByShotID,
            supersedesShotID: supersedesShotID,
            replacementReason: replacementReason,
            hiddenFromReports: hiddenFromReports,
            hiddenFromGallery: hiddenFromGallery,
            lifecycleUpdatedAt: lifecycleUpdatedAt
        )
    }

    @MainActor
    private func makeLocalStoreFixture() throws -> (
        localStore: LocalStore,
        storageRoot: URL,
        propertyID: UUID,
        sessionID: UUID
    ) {
        let storageRoot = try makeTempStorageRoot()
        let localStore = LocalStore(testStorageRootURL: storageRoot)
        let orgID = UUID()
        let propertyID = UUID()
        let sessionID = UUID()

        _ = try localStore.createOrganization(Organization(id: orgID, name: "Org"))
        _ = try localStore.createProperty(
            Property(
                id: propertyID,
                orgId: orgID,
                name: "Property",
                address: "123 Main"
            )
        )
        _ = try localStore.upsertSession(
            Session(
                id: sessionID,
                propertyID: propertyID,
                startedAt: Date(timeIntervalSinceReferenceDate: 50),
                status: .draft
            )
        )
        try localStore.ensureSessionMetadata(
            for: Session(
                id: sessionID,
                propertyID: propertyID,
                startedAt: Date(timeIntervalSinceReferenceDate: 50),
                status: .draft
            )
        )

        return (localStore, storageRoot, propertyID, sessionID)
    }

    private func roundTrip(_ shot: ShotMetadata) throws -> ShotMetadata {
        let data = try JSONEncoder().encode(shot)
        return try JSONDecoder().decode(ShotMetadata.self, from: data)
    }

    func testOldJSONWithoutLifecycleFieldsDecodesAsActive() throws {
        let json = """
        {
          "shotID": "\(UUID().uuidString)",
          "createdAt": 100,
          "updatedAt": 100,
          "building": "Building",
          "elevation": "North",
          "detailType": "Overview",
          "angleIndex": 1,
          "shotKey": "building|north|overview|1",
          "isGuided": false,
          "isFlagged": false,
          "originalFilename": "shot.heic",
          "originalRelativePath": "Originals/shot.heic",
          "uploadState": "pending",
          "uploadAttempts": 0
        }
        """

        let shot = try JSONDecoder().decode(ShotMetadata.self, from: Data(json.utf8))

        XCTAssertEqual(shot.lifecycleState, .active)
        XCTAssertTrue(shot.isActiveForDefaultWorkflows)
        XCTAssertTrue(shot.shouldAppearInDefaultGallery)
        XCTAssertTrue(shot.shouldAppearInDefaultReports)
        XCTAssertTrue(shot.shouldAppearInDefaultExports)
    }

    func testExistingShotDefaultsToActiveForLifecycleHelpers() {
        let shot = makeShot()

        XCTAssertEqual(shot.lifecycleState, .active)
        XCTAssertTrue(shot.isActiveForDefaultWorkflows)
        XCTAssertFalse(shot.isHistorical)
        XCTAssertFalse(shot.isRetired)
        XCTAssertFalse(shot.isSuperseded)
    }

    func testActiveShotAppearsInDefaultWorkflowHelpers() {
        let shot = makeShot()

        XCTAssertTrue(shot.shouldAppearInDefaultGallery)
        XCTAssertTrue(shot.shouldAppearInDefaultReports)
        XCTAssertTrue(shot.shouldAppearInDefaultExports)
    }

    func testActiveShotEncodesAndDecodesSafely() throws {
        let shot = makeShot()

        let decoded = try roundTrip(shot)

        XCTAssertEqual(decoded.lifecycleState, .active)
        XCTAssertNil(decoded.retiredAt)
        XCTAssertNil(decoded.supersededByShotID)
        XCTAssertTrue(decoded.shouldAppearInDefaultGallery)
        XCTAssertTrue(decoded.shouldAppearInDefaultReports)
        XCTAssertTrue(decoded.shouldAppearInDefaultExports)
    }

    func testRetiredAndSupersededStatesAreHistoricalAndHiddenByDefaultHelpers() {
        for state in [ShotLifecycleState.retired, .superseded] {
            XCTAssertFalse(state.isActiveForDefaultWorkflows)
            XCTAssertTrue(state.isHistorical)
            XCTAssertFalse(state.shouldAppearInDefaultGallery)
            XCTAssertFalse(state.shouldAppearInDefaultReports)
            XCTAssertFalse(state.shouldAppearInDefaultExports)
        }

        XCTAssertTrue(ShotLifecycleState.retired.isRetired)
        XCTAssertTrue(ShotLifecycleState.superseded.isSuperseded)
    }

    func testRetiredShotDecodesAsHistoricalAndHiddenByDefault() throws {
        let shot = makeShot(
            lifecycleState: .retired,
            retiredAt: Date(timeIntervalSinceReferenceDate: 200),
            retiredReason: "Duplicate capture",
            retiredByUserID: UUID(),
            lifecycleUpdatedAt: Date(timeIntervalSinceReferenceDate: 201)
        )

        let decoded = try roundTrip(shot)

        XCTAssertEqual(decoded.lifecycleState, .retired)
        XCTAssertTrue(decoded.isHistorical)
        XCTAssertTrue(decoded.isRetired)
        XCTAssertFalse(decoded.shouldAppearInDefaultGallery)
        XCTAssertFalse(decoded.shouldAppearInDefaultReports)
        XCTAssertFalse(decoded.shouldAppearInDefaultExports)
        XCTAssertEqual(decoded.retiredReason, "Duplicate capture")
        XCTAssertNotNil(decoded.retiredAt)
        XCTAssertNotNil(decoded.retiredByUserID)
        XCTAssertNotNil(decoded.lifecycleUpdatedAt)
    }

    func testSupersededShotDecodesAsHistoricalAndHiddenByDefault() throws {
        let replacementID = UUID()
        let shot = makeShot(
            lifecycleState: .superseded,
            supersededByShotID: replacementID,
            replacementReason: "Retake",
            lifecycleUpdatedAt: Date(timeIntervalSinceReferenceDate: 250)
        )

        let decoded = try roundTrip(shot)

        XCTAssertEqual(decoded.lifecycleState, .superseded)
        XCTAssertTrue(decoded.isHistorical)
        XCTAssertTrue(decoded.isSuperseded)
        XCTAssertFalse(decoded.shouldAppearInDefaultGallery)
        XCTAssertFalse(decoded.shouldAppearInDefaultReports)
        XCTAssertFalse(decoded.shouldAppearInDefaultExports)
        XCTAssertEqual(decoded.supersededByShotID, replacementID)
        XCTAssertEqual(decoded.replacementReason, "Retake")
        XCTAssertNotNil(decoded.lifecycleUpdatedAt)
    }

    func testHiddenOverridesAffectGalleryAndReportVisibilityHelpers() {
        let activeHidden = makeShot(
            hiddenFromReports: true,
            hiddenFromGallery: true
        )
        let retiredShown = makeShot(
            lifecycleState: .retired,
            hiddenFromReports: false,
            hiddenFromGallery: false
        )

        XCTAssertFalse(activeHidden.shouldAppearInDefaultGallery)
        XCTAssertFalse(activeHidden.shouldAppearInDefaultReports)
        XCTAssertTrue(activeHidden.shouldAppearInDefaultExports)
        XCTAssertTrue(retiredShown.shouldAppearInDefaultGallery)
        XCTAssertTrue(retiredShown.shouldAppearInDefaultReports)
        XCTAssertFalse(retiredShown.shouldAppearInDefaultExports)
    }

    func testReplacementRelationshipFieldsRoundTrip() throws {
        let olderShotID = UUID()
        let newerShotID = UUID()
        let oldShot = makeShot(
            lifecycleState: .superseded,
            supersededByShotID: newerShotID,
            replacementReason: "Retake requested"
        )
        let newShot = makeShot(
            supersedesShotID: olderShotID,
            replacementReason: "Retake requested"
        )

        let decodedOldShot = try roundTrip(oldShot)
        let decodedNewShot = try roundTrip(newShot)

        XCTAssertEqual(decodedOldShot.supersededByShotID, newerShotID)
        XCTAssertNil(decodedOldShot.supersedesShotID)
        XCTAssertEqual(decodedOldShot.replacementReason, "Retake requested")
        XCTAssertEqual(decodedNewShot.supersedesShotID, olderShotID)
        XCTAssertNil(decodedNewShot.supersededByShotID)
        XCTAssertEqual(decodedNewShot.replacementReason, "Retake requested")
    }

    @MainActor
    func testSameSessionRetakeReplacesCurrentShotWithoutLifecycleLinks() throws {
        let fixture = try makeLocalStoreFixture()
        let shotID = UUID()
        let firstShot = makeShot(
            shotID: shotID,
            propertyID: fixture.propertyID,
            sessionID: fixture.sessionID,
            createdAt: Date(timeIntervalSinceReferenceDate: 100),
            originalFilename: "\(shotID.uuidString).heic",
            originalRelativePath: "Originals/\(shotID.uuidString).heic"
        )
        let retakenShot = makeShot(
            shotID: shotID,
            propertyID: fixture.propertyID,
            sessionID: fixture.sessionID,
            createdAt: Date(timeIntervalSinceReferenceDate: 200),
            originalFilename: "\(shotID.uuidString).heic",
            originalRelativePath: "Originals/\(shotID.uuidString).heic"
        )

        try fixture.localStore.upsertShot(
            propertyID: fixture.propertyID,
            sessionID: fixture.sessionID,
            shot: firstShot,
            matchMode: .append
        )
        try fixture.localStore.upsertShot(
            propertyID: fixture.propertyID,
            sessionID: fixture.sessionID,
            shot: retakenShot,
            matchMode: .append
        )

        let metadata = try fixture.localStore.loadSessionMetadata(
            propertyID: fixture.propertyID,
            sessionID: fixture.sessionID
        )
        let stored = try XCTUnwrap(metadata.shots.first { $0.shotID == shotID })

        XCTAssertEqual(metadata.shots.count, 1)
        XCTAssertEqual(stored.lifecycleState, .active)
        XCTAssertNil(stored.supersedesShotID)
        XCTAssertNil(stored.supersededByShotID)
        XCTAssertNil(stored.replacementReason)
        XCTAssertNil(stored.lifecycleUpdatedAt)
    }

    @MainActor
    func testSameSessionGuidedRetakeDoesNotLeaveExtraActiveDuplicate() throws {
        let fixture = try makeLocalStoreFixture()
        let shotID = UUID()
        let firstShot = makeShot(
            shotID: shotID,
            propertyID: fixture.propertyID,
            sessionID: fixture.sessionID,
            createdAt: Date(timeIntervalSinceReferenceDate: 100),
            originalFilename: "\(shotID.uuidString).heic",
            originalRelativePath: "Originals/\(shotID.uuidString).heic"
        )
        var retakenShot = makeShot(
            shotID: shotID,
            propertyID: fixture.propertyID,
            sessionID: fixture.sessionID,
            createdAt: Date(timeIntervalSinceReferenceDate: 200),
            originalFilename: "\(shotID.uuidString).heic",
            originalRelativePath: "Originals/\(shotID.uuidString).heic"
        )
        retakenShot.isGuided = true

        try fixture.localStore.upsertShot(
            propertyID: fixture.propertyID,
            sessionID: fixture.sessionID,
            shot: firstShot,
            matchMode: .append
        )
        try fixture.localStore.upsertShot(
            propertyID: fixture.propertyID,
            sessionID: fixture.sessionID,
            shot: retakenShot,
            matchMode: .replaceGuidedKey
        )

        let metadata = try fixture.localStore.loadSessionMetadata(
            propertyID: fixture.propertyID,
            sessionID: fixture.sessionID
        )

        XCTAssertEqual(metadata.shots.count, 1)
        XCTAssertEqual(metadata.shots.first?.shotID, shotID)
        XCTAssertEqual(metadata.shots.filter(\.isActiveForDefaultWorkflows).count, 1)
        XCTAssertNil(metadata.shots.first?.supersedesShotID)
        XCTAssertNil(metadata.shots.first?.supersededByShotID)
    }

    @MainActor
    func testGuidedLinkagePointsToCurrentRetakenImageWithoutLifecycleLinks() throws {
        let fixture = try makeLocalStoreFixture()
        let shotID = UUID()
        let retaken = Shot(
            id: shotID,
            capturedAt: Date(timeIntervalSinceReferenceDate: 200),
            imageLocalIdentifier: "Originals/\(shotID.uuidString).heic"
        )
        let guided = GuidedShot(
            title: "North Overview",
            shot: retaken,
            isCompleted: true
        )

        try fixture.localStore.syncGuidedShotsToSessionMetadata(
            propertyID: fixture.propertyID,
            sessionID: fixture.sessionID,
            guidedShots: [guided]
        )

        let metadata = try fixture.localStore.loadSessionMetadata(
            propertyID: fixture.propertyID,
            sessionID: fixture.sessionID
        )

        XCTAssertEqual(metadata.guidedShots.first?.shot?.id, shotID)
        XCTAssertEqual(metadata.guidedShots.first?.shot?.imageLocalIdentifier, retaken.imageLocalIdentifier)
        XCTAssertTrue(metadata.shots.allSatisfy { $0.supersedesShotID == nil && $0.supersededByShotID == nil })
    }

    @MainActor
    func testFlaggedLinkageAndHistoryPointToCurrentRetakenImageWithoutLifecycleLinks() throws {
        let fixture = try makeLocalStoreFixture()
        let observationID = UUID()
        let shotID = UUID()
        let retaken = Shot(
            id: shotID,
            capturedAt: Date(timeIntervalSinceReferenceDate: 200),
            imageLocalIdentifier: "Originals/\(shotID.uuidString).heic"
        )
        let event = ObservationHistoryEvent(
            timestamp: retaken.capturedAt,
            sessionID: fixture.sessionID,
            kind: .retake,
            shotID: shotID
        )
        let observation = Observation(
            id: observationID,
            propertyID: fixture.propertyID,
            sessionID: fixture.sessionID,
            linkedShotID: shotID,
            historyEvents: [event],
            shots: [retaken]
        )

        _ = try fixture.localStore.createObservation(observation)
        let stored = try XCTUnwrap(
            fixture.localStore.fetchObservations(propertyID: fixture.propertyID).first { $0.id == observationID }
        )
        let metadata = try fixture.localStore.loadSessionMetadata(
            propertyID: fixture.propertyID,
            sessionID: fixture.sessionID
        )

        XCTAssertEqual(stored.linkedShotID, shotID)
        XCTAssertEqual(stored.historyEvents.last?.shotID, shotID)
        XCTAssertEqual(stored.shots.last?.imageLocalIdentifier, retaken.imageLocalIdentifier)
        XCTAssertTrue(metadata.shots.allSatisfy { $0.supersedesShotID == nil && $0.supersededByShotID == nil })
    }

    @MainActor
    func testExportedSessionMetadataDoesNotIncludeDanglingSupersessionLinksForRoutineRetake() throws {
        let fixture = try makeLocalStoreFixture()
        let shotID = UUID()
        try fixture.localStore.upsertShot(
            propertyID: fixture.propertyID,
            sessionID: fixture.sessionID,
            shot: makeShot(
                shotID: shotID,
                propertyID: fixture.propertyID,
                sessionID: fixture.sessionID,
                createdAt: Date(timeIntervalSinceReferenceDate: 100)
            ),
            matchMode: .append
        )
        try fixture.localStore.upsertShot(
            propertyID: fixture.propertyID,
            sessionID: fixture.sessionID,
            shot: makeShot(
                shotID: shotID,
                propertyID: fixture.propertyID,
                sessionID: fixture.sessionID,
                createdAt: Date(timeIntervalSinceReferenceDate: 200)
            ),
            matchMode: .append
        )

        let metadata = try fixture.localStore.loadSessionMetadata(
            propertyID: fixture.propertyID,
            sessionID: fixture.sessionID
        )
        let encoded = try JSONEncoder().encode(metadata)
        let decoded = try JSONDecoder().decode(SessionMetadata.self, from: encoded)

        XCTAssertEqual(decoded.shots.count, 1)
        XCTAssertTrue(decoded.shots.allSatisfy { $0.supersedesShotID == nil && $0.supersededByShotID == nil })
    }

    func testShotLifecycleMigrationAddsNullSafeRemoteColumns() throws {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let repoRoot = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let migrationURL = repoRoot
            .appendingPathComponent("supabase/migrations/20260514_phase_2c_16_10d_shot_lifecycle_schema.sql")
        let sql = try String(contentsOf: migrationURL, encoding: .utf8)

        for column in [
            "lifecycle_state text",
            "retired_at timestamptz",
            "retired_reason text",
            "retired_by uuid",
            "superseded_by_shot_id uuid",
            "supersedes_shot_id uuid",
            "replacement_reason text",
            "hidden_from_reports boolean",
            "hidden_from_gallery boolean",
            "lifecycle_updated_at timestamptz"
        ] {
            XCTAssertTrue(sql.contains(column), "Expected migration to include \(column)")
        }

        XCTAssertTrue(sql.contains("add column if not exists"))
        XCTAssertTrue(sql.contains("shots_lifecycle_state_check"))
        XCTAssertTrue(sql.contains("lifecycle_state is null"))
        XCTAssertTrue(sql.contains("'active'"))
        XCTAssertTrue(sql.contains("'retired'"))
        XCTAssertTrue(sql.contains("'superseded'"))
        XCTAssertFalse(sql.lowercased().contains("not null"))
        XCTAssertFalse(sql.lowercased().contains("references public.shots"))
        XCTAssertFalse(sql.lowercased().contains("update public.shots"))
    }

    func testRemoteDecodeNullLifecycleAsActive() throws {
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "lifecycle_state": null
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let remote = try decoder.decode(RemoteShotMetadataRecord.self, from: Data(json.utf8))
        let merged = remote.merged(withLocal: makeShot(lifecycleState: .active))

        XCTAssertEqual(remote.lifecycleState, .active)
        XCTAssertEqual(merged.lifecycleState, .active)
        XCTAssertTrue(merged.shouldAppearInDefaultGallery)
        XCTAssertTrue(merged.shouldAppearInDefaultReports)
    }

    func testRemoteDecodeRetiredAndSupersededLifecycle() throws {
        let replacementID = UUID()
        let retiredJSON = """
        {
          "id": "\(UUID().uuidString)",
          "lifecycle_state": "retired",
          "retired_at": "2026-05-14T14:00:00Z",
          "retired_reason": "Duplicate",
          "hidden_from_gallery": true,
          "hidden_from_reports": true,
          "lifecycle_updated_at": "2026-05-14T14:01:00Z"
        }
        """
        let supersededJSON = """
        {
          "id": "\(UUID().uuidString)",
          "lifecycle_state": "superseded",
          "superseded_by_shot_id": "\(replacementID.uuidString)",
          "replacement_reason": "Retake"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let retired = try decoder.decode(RemoteShotMetadataRecord.self, from: Data(retiredJSON.utf8))
        let superseded = try decoder.decode(RemoteShotMetadataRecord.self, from: Data(supersededJSON.utf8))

        XCTAssertEqual(retired.lifecycleState, .retired)
        XCTAssertEqual(retired.retiredReason, "Duplicate")
        XCTAssertEqual(retired.hiddenFromGallery, true)
        XCTAssertEqual(retired.hiddenFromReports, true)
        XCTAssertNotNil(retired.retiredAt)
        XCTAssertNotNil(retired.lifecycleUpdatedAt)
        XCTAssertEqual(superseded.lifecycleState, .superseded)
        XCTAssertEqual(superseded.supersededByShotID, replacementID)
        XCTAssertEqual(superseded.replacementReason, "Retake")
    }

    func testRichShotMetadataPayloadIncludesLifecycleFieldsWhenPresent() throws {
        let appState = AppState(disableCloudBackupForTests: true)
        let orgID = UUID()
        let propertyID = UUID()
        let sessionID = UUID()
        let retiredBy = UUID()
        let replacementID = UUID()
        let lifecycleUpdatedAt = Date(timeIntervalSinceReferenceDate: 500)
        let shot = makeShot(
            lifecycleState: .superseded,
            retiredReason: "Superseded by retake",
            retiredByUserID: retiredBy,
            supersededByShotID: replacementID,
            replacementReason: "Retake",
            hiddenFromReports: true,
            hiddenFromGallery: true,
            lifecycleUpdatedAt: lifecycleUpdatedAt
        )

        let payload = try appState._debugEncodeShotRichMetadataPayloadForTests(
            orgID: orgID,
            propertyID: propertyID,
            sessionID: sessionID,
            shot: shot,
            includeInsertDefaults: false,
            updatedBy: UUID()
        )

        XCTAssertEqual(payload["lifecycle_state"] as? String, "superseded")
        XCTAssertEqual(payload["retired_reason"] as? String, "Superseded by retake")
        XCTAssertEqual(payload["retired_by"] as? String, retiredBy.uuidString)
        XCTAssertEqual(payload["superseded_by_shot_id"] as? String, replacementID.uuidString)
        XCTAssertEqual(payload["replacement_reason"] as? String, "Retake")
        XCTAssertEqual(payload["hidden_from_reports"] as? Bool, true)
        XCTAssertEqual(payload["hidden_from_gallery"] as? Bool, true)
        XCTAssertNotNil(payload["lifecycle_updated_at"] as? String)
    }

    func testStoragePayloadDoesNotIncludeLifecycleFields() throws {
        let appState = AppState(disableCloudBackupForTests: true)
        let payload = try appState._debugEncodeShotStoragePayloadForTests(
            orgID: UUID(),
            propertyID: UUID(),
            sessionID: UUID(),
            shotID: UUID(),
            storageBucket: "bucket",
            storagePath: "path/original.heic",
            checksumSHA256: "abc",
            byteSize: 10,
            uploadState: "uploaded",
            uploadAttempts: 1,
            lastUploadError: nil,
            updatedBy: UUID()
        )

        for key in [
            "lifecycle_state",
            "retired_at",
            "retired_reason",
            "retired_by",
            "superseded_by_shot_id",
            "supersedes_shot_id",
            "replacement_reason",
            "hidden_from_reports",
            "hidden_from_gallery",
            "lifecycle_updated_at"
        ] {
            XCTAssertNil(payload[key], "Storage payload should not include \(key)")
        }
    }

    func testLifecycleRichUpdatePayloadDoesNotIncludeStorageFields() throws {
        let appState = AppState(disableCloudBackupForTests: true)
        let shot = makeShot(lifecycleState: .retired, retiredReason: "Duplicate")

        let payload = try appState._debugEncodeShotRichMetadataPayloadForTests(
            orgID: UUID(),
            propertyID: UUID(),
            sessionID: UUID(),
            shot: shot,
            includeInsertDefaults: false,
            updatedBy: UUID()
        )

        XCTAssertEqual(payload["lifecycle_state"] as? String, "retired")
        XCTAssertEqual(payload["retired_reason"] as? String, "Duplicate")
        XCTAssertNil(payload["storage_bucket"])
        XCTAssertNil(payload["storage_path"])
        XCTAssertNil(payload["checksum_sha256"])
        XCTAssertNil(payload["byte_size"])
        XCTAssertNil(payload["last_upload_error"])
        XCTAssertNil(payload["upload_state"])
        XCTAssertNil(payload["upload_attempts"])
    }

    func testDefaultActiveShotDoesNotWriteLifecycleFieldsInRichPayload() throws {
        let appState = AppState(disableCloudBackupForTests: true)

        let payload = try appState._debugEncodeShotRichMetadataPayloadForTests(
            orgID: UUID(),
            propertyID: UUID(),
            sessionID: UUID(),
            shot: makeShot(),
            includeInsertDefaults: false,
            updatedBy: UUID()
        )

        XCTAssertNil(payload["lifecycle_state"])
        XCTAssertNil(payload["retired_at"])
        XCTAssertNil(payload["retired_reason"])
        XCTAssertNil(payload["retired_by"])
        XCTAssertNil(payload["superseded_by_shot_id"])
        XCTAssertNil(payload["supersedes_shot_id"])
        XCTAssertNil(payload["replacement_reason"])
        XCTAssertNil(payload["hidden_from_reports"])
        XCTAssertNil(payload["hidden_from_gallery"])
        XCTAssertNil(payload["lifecycle_updated_at"])
    }

    func testNewActiveReplacementPayloadLinksBackWithoutStorageFields() throws {
        let appState = AppState(disableCloudBackupForTests: true)
        let oldShotID = UUID()
        let shot = makeShot(
            supersedesShotID: oldShotID,
            replacementReason: "Retake"
        )

        let payload = try appState._debugEncodeShotRichMetadataPayloadForTests(
            orgID: UUID(),
            propertyID: UUID(),
            sessionID: UUID(),
            shot: shot,
            includeInsertDefaults: false,
            updatedBy: UUID()
        )

        XCTAssertEqual(payload["lifecycle_state"] as? String, "active")
        XCTAssertEqual(payload["supersedes_shot_id"] as? String, oldShotID.uuidString)
        XCTAssertEqual(payload["replacement_reason"] as? String, "Retake")
        XCTAssertNil(payload["storage_bucket"])
        XCTAssertNil(payload["storage_path"])
        XCTAssertNil(payload["checksum_sha256"])
        XCTAssertNil(payload["byte_size"])
    }

    func testSelfSupersessionIsInvalid() {
        let shotID = UUID()

        let errors = ShotLifecycleRules.validateReplacement(
            shotID: shotID,
            supersededByShotID: shotID
        )

        XCTAssertEqual(errors, [.selfSupersession(shotID: shotID)])
    }

    func testSimpleReplacementCycleIsInvalid() {
        let firstShotID = UUID()
        let secondShotID = UUID()

        let errors = ShotLifecycleRules.validateReplacementLinks(
            supersededByShotIDByShotID: [
                firstShotID: secondShotID,
                secondShotID: firstShotID
            ]
        )

        XCTAssertEqual(errors.count, 1)
        guard case .replacementCycle(let shotIDs) = errors[0] else {
            return XCTFail("Expected replacement cycle error")
        }
        XCTAssertEqual(Set(shotIDs), Set([firstShotID, secondShotID]))
    }
}
