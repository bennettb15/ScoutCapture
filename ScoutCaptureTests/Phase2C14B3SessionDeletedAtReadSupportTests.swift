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

    private func makeFixture(
        captureProfileBackfillFetchOverride: AppState.CaptureProfileBackfillFetchOverride? = nil,
        captureProfileRemotePropertyIDsFetchOverride: AppState.CaptureProfileRemotePropertyIDsFetchOverride? = nil,
        captureProfileBackfillEnsureOverride: AppState.CaptureProfileBackfillEnsureOverride? = nil,
        captureProfileBackfillWriteOverride: AppState.CaptureProfileBackfillWriteOverride? = nil
    ) throws -> Fixture {
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
        let appState = AppState(
            localStore: localStore,
            userDefaults: defaults,
            captureProfileBackfillFetchOverride: captureProfileBackfillFetchOverride,
            captureProfileRemotePropertyIDsFetchOverride: captureProfileRemotePropertyIDsFetchOverride,
            captureProfileBackfillEnsureOverride: captureProfileBackfillEnsureOverride,
            captureProfileBackfillWriteOverride: captureProfileBackfillWriteOverride
        )
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
    private func prepareAppState(_ appState: AppState, orgID: UUID, role: String = "owner") {
        appState.refreshProperties()
        appState._debugSetOrganizationContextForTests(
            memberships: [
                ActiveOrganizationMembership(
                    id: orgID,
                    name: "Org",
                    role: role
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

    func testSessionCaptureProfileCodableRoundTripAndMissingDefaultsNil() throws {
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

        let legacy = try decoder.decode(Session.self, from: data)
        XCTAssertNil(legacy.captureProfile)

        let session = Session(
            id: UUID(),
            propertyID: UUID(),
            startedAt: Date(timeIntervalSinceReferenceDate: 700),
            status: .completed,
            captureProfile: .commercial,
            deletedAt: Date(timeIntervalSinceReferenceDate: 900)
        )
        let roundTripped = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(roundTripped.captureProfile, .commercial)
        XCTAssertEqual(roundTripped.deletedAt, session.deletedAt)
    }

    func testRemoteShotRichMetadataDecodesAndMergesWithoutWipingLocalCacheFields() throws {
        let shotID = UUID()
        let propertyID = UUID()
        let sessionID = UUID()
        let issueID = UUID()
        let updatedBy = UUID()
        let json = """
        {
          "id": "\(shotID.uuidString)",
          "org_id": "\(UUID().uuidString)",
          "property_id": "\(propertyID.uuidString)",
          "session_id": "\(sessionID.uuidString)",
          "created_at": "2026-05-08T12:00:00Z",
          "updated_at": "2026-05-08T12:05:00Z",
          "updated_by": "\(updatedBy.uuidString)",
          "revision": 7,
          "building": "Main",
          "elevation": "north elevation",
          "detail_type": "Window",
          "angle_index": 2,
          "shot_key": "main|north|window|2",
          "logical_shot_identity": "logical",
          "capture_kind": "issue",
          "first_capture_kind": "guided",
          "is_guided": true,
          "is_flagged": true,
          "issue_id": "\(issueID.uuidString)",
          "issue_status": "active",
          "trade": "Glazing",
          "reason": "Cracked pane",
          "priority": "high",
          "capture_mode": "photo",
          "lens": "wide",
          "latitude": 33.75,
          "longitude": -84.39,
          "accuracy_meters": 4.5,
          "image_width": 4032,
          "image_height": 3024,
          "storage_bucket": "capture-media",
          "storage_path": "sessions/s/shot.jpg",
          "checksum_sha256": "abc123",
          "byte_size": 12345,
          "upload_state": "uploaded",
          "upload_attempts": 3,
          "last_upload_error": null,
          "deleted_at": null
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let remote = try decoder.decode(RemoteShotMetadataRecord.self, from: json)
        let local = ShotMetadata(
            shotID: shotID,
            propertyID: UUID(),
            sessionID: sessionID,
            createdAt: Date(timeIntervalSinceReferenceDate: 100),
            capturedAtLocal: "May 8, 2026 at 8:00 AM",
            updatedAt: Date(timeIntervalSinceReferenceDate: 100),
            building: "Local Building",
            elevation: "South",
            detailType: "Door",
            angleIndex: 1,
            trade: nil,
            priority: nil,
            shotKey: "local|south|door|1",
            isGuided: false,
            isFlagged: false,
            issueID: nil,
            issueStatus: nil,
            captureKind: nil,
            firstCaptureKind: nil,
            noteText: "local note",
            noteCategory: "local category",
            originalFilename: "/private/local/original.jpg",
            originalRelativePath: "Originals/original.jpg",
            originalByteSize: 999,
            storageBucket: nil,
            storagePath: nil,
            checksumSHA256: nil,
            byteSize: nil,
            uploadState: "pending",
            uploadAttempts: 1,
            lastUploadError: "keep if remote nil",
            stampedFilename: "/private/local/stamped.jpg",
            stampedRelativePath: "Stamped/stamped.jpg",
            captureMode: nil,
            lens: nil,
            exifOrientation: 1,
            latitude: nil,
            longitude: nil,
            accuracyMeters: nil,
            imageWidth: nil,
            imageHeight: nil
        )

        let merged = remote.merged(withLocal: local)

        XCTAssertEqual(remote.issueID, issueID)
        XCTAssertEqual(remote.updatedBy, updatedBy)
        XCTAssertEqual(remote.revision, 7)
        XCTAssertEqual(merged.propertyID, propertyID)
        XCTAssertEqual(merged.building, "Main")
        XCTAssertEqual(merged.elevation, "North")
        XCTAssertEqual(merged.detailType, "Window")
        XCTAssertEqual(merged.angleIndex, 2)
        XCTAssertEqual(merged.issueID, issueID)
        XCTAssertEqual(merged.noteText, "Cracked pane")
        XCTAssertEqual(merged.storagePath, "sessions/s/shot.jpg")
        XCTAssertEqual(merged.uploadAttempts, 3)
        XCTAssertEqual(merged.originalFilename, "/private/local/original.jpg")
        XCTAssertEqual(merged.originalRelativePath, "Originals/original.jpg")
        XCTAssertEqual(merged.stampedRelativePath, "Stamped/stamped.jpg")
        XCTAssertEqual(merged.lastUploadError, "keep if remote nil")
    }

    func testShotRichMetadataPayloadIncludesCanonicalFieldsAndUpdatedBy() throws {
        let appState = AppState(disableCloudBackupForTests: true)
        let orgID = UUID()
        let propertyID = UUID()
        let sessionID = UUID()
        let shotID = UUID()
        let issueID = UUID()
        let updatedBy = UUID()
        let shot = ShotMetadata(
            shotID: shotID,
            propertyID: propertyID,
            sessionID: sessionID,
            createdAt: Date(timeIntervalSinceReferenceDate: 100),
            updatedAt: Date(timeIntervalSinceReferenceDate: 110),
            building: "Main",
            elevation: "north elevation",
            detailType: "Window",
            angleIndex: 2,
            trade: "Glazing",
            priority: "High",
            shotKey: "main|north|window|2",
            isGuided: true,
            isFlagged: true,
            issueID: issueID,
            issueStatus: "active",
            captureKind: "issue",
            firstCaptureKind: "guided",
            noteText: "Cracked pane",
            noteCategory: nil,
            originalFilename: "original.heic",
            originalRelativePath: "Originals/original.heic",
            originalByteSize: 123,
            uploadState: "pending",
            uploadAttempts: 0,
            stampedFilename: nil,
            stampedRelativePath: nil,
            captureMode: "hd",
            lens: "wide",
            exifOrientation: 1,
            latitude: 33.75,
            longitude: -84.39,
            accuracyMeters: 4.5,
            imageWidth: 4032,
            imageHeight: 3024
        )

        let payload = try appState._debugEncodeShotRichMetadataPayloadForTests(
            orgID: orgID,
            propertyID: propertyID,
            sessionID: sessionID,
            shot: shot,
            includeInsertDefaults: true,
            updatedBy: updatedBy
        )

        XCTAssertEqual(payload["id"] as? String, shotID.uuidString)
        XCTAssertEqual(payload["org_id"] as? String, orgID.uuidString)
        XCTAssertEqual(payload["property_id"] as? String, propertyID.uuidString)
        XCTAssertEqual(payload["session_id"] as? String, sessionID.uuidString)
        XCTAssertEqual(payload["shot_type"] as? String, "issue")
        XCTAssertEqual(payload["position"] as? Int, 2)
        XCTAssertNotNil(payload["captured_at"] as? String)
        XCTAssertEqual(payload["building"] as? String, "Main")
        XCTAssertEqual(payload["elevation"] as? String, "North")
        XCTAssertEqual(payload["detail_type"] as? String, "Window")
        XCTAssertEqual(payload["angle_index"] as? Int, 2)
        XCTAssertEqual(payload["shot_key"] as? String, "main|north|window|2")
        XCTAssertEqual(payload["logical_shot_identity"] as? String, shot.logicalShotIdentity)
        XCTAssertEqual(payload["capture_kind"] as? String, "issue")
        XCTAssertEqual(payload["first_capture_kind"] as? String, "guided")
        XCTAssertEqual(payload["is_guided"] as? Bool, true)
        XCTAssertEqual(payload["is_flagged"] as? Bool, true)
        XCTAssertEqual(payload["issue_id"] as? String, issueID.uuidString)
        XCTAssertEqual(payload["issue_status"] as? String, "active")
        XCTAssertEqual(payload["trade"] as? String, "Glazing")
        XCTAssertEqual(payload["reason"] as? String, "Cracked pane")
        XCTAssertEqual(payload["priority"] as? String, "high")
        XCTAssertEqual(payload["capture_mode"] as? String, "hd")
        XCTAssertEqual(payload["lens"] as? String, "wide")
        XCTAssertEqual(payload["latitude"] as? Double, 33.75)
        XCTAssertEqual(payload["longitude"] as? Double, -84.39)
        XCTAssertEqual(payload["accuracy_meters"] as? Double, 4.5)
        XCTAssertEqual(payload["image_width"] as? Int, 4032)
        XCTAssertEqual(payload["image_height"] as? Int, 3024)
        XCTAssertEqual(payload["updated_by"] as? String, updatedBy.uuidString)
        XCTAssertEqual(payload["upload_state"] as? String, "pending")
    }

    func testRichAndStoragePayloadsDoNotClobberEachOther() throws {
        let appState = AppState(disableCloudBackupForTests: true)
        let orgID = UUID()
        let propertyID = UUID()
        let sessionID = UUID()
        let shotID = UUID()
        let shot = ShotMetadata(
            shotID: shotID,
            propertyID: propertyID,
            sessionID: sessionID,
            createdAt: Date(timeIntervalSinceReferenceDate: 100),
            updatedAt: Date(timeIntervalSinceReferenceDate: 110),
            building: "Main",
            elevation: "North",
            detailType: "Window",
            angleIndex: 2,
            shotKey: "main|north|window|2",
            isGuided: false,
            isFlagged: false,
            issueID: nil,
            issueStatus: nil,
            noteText: nil,
            noteCategory: nil,
            originalFilename: "original.heic",
            originalRelativePath: "Originals/original.heic",
            originalByteSize: 123,
            uploadState: "pending",
            uploadAttempts: 0,
            stampedFilename: nil,
            stampedRelativePath: nil,
            captureMode: nil,
            lens: nil,
            exifOrientation: 1,
            latitude: nil,
            longitude: nil,
            accuracyMeters: nil,
            imageWidth: nil,
            imageHeight: nil
        )

        let richUpdate = try appState._debugEncodeShotRichMetadataPayloadForTests(
            orgID: orgID,
            propertyID: propertyID,
            sessionID: sessionID,
            shot: shot,
            includeInsertDefaults: false,
            updatedBy: UUID()
        )
        let storageUpdate = try appState._debugEncodeShotStoragePayloadForTests(
            orgID: orgID,
            propertyID: propertyID,
            sessionID: sessionID,
            shotID: shotID,
            storageBucket: "bucket",
            storagePath: "path/original.heic",
            checksumSHA256: "abc",
            byteSize: 123,
            uploadState: "uploaded",
            uploadAttempts: 1,
            lastUploadError: nil,
            updatedBy: UUID()
        )

        XCTAssertNil(richUpdate["storage_bucket"])
        XCTAssertNil(richUpdate["storage_path"])
        XCTAssertNil(richUpdate["checksum_sha256"])
        XCTAssertNil(richUpdate["byte_size"])
        XCTAssertNil(richUpdate["last_upload_error"])
        XCTAssertNil(richUpdate["upload_state"])
        XCTAssertNil(richUpdate["shot_type"])
        XCTAssertNil(richUpdate["position"])
        XCTAssertNil(richUpdate["captured_at"])
        XCTAssertEqual(richUpdate["building"] as? String, "Main")
        XCTAssertEqual(richUpdate["is_guided"] as? Bool, false)
        XCTAssertNil(richUpdate["issue_id"])

        XCTAssertEqual(storageUpdate["storage_bucket"] as? String, "bucket")
        XCTAssertEqual(storageUpdate["storage_path"] as? String, "path/original.heic")
        XCTAssertEqual(storageUpdate["checksum_sha256"] as? String, "abc")
        XCTAssertEqual(storageUpdate["upload_state"] as? String, "uploaded")
        XCTAssertNil(storageUpdate["building"])
        XCTAssertNil(storageUpdate["detail_type"])
        XCTAssertNil(storageUpdate["issue_id"])
        XCTAssertNil(storageUpdate["reason"])
    }

    func testSessionEnsureInsertPayloadIncludesUpdatedByAndParentFields() throws {
        let appState = AppState(disableCloudBackupForTests: true)
        let orgID = UUID()
        let propertyID = UUID()
        let sessionID = UUID()
        let actorID = UUID()
        let startedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        let endedAt = Date(timeIntervalSinceReferenceDate: 1_500)
        let property = Property(id: propertyID, orgId: orgID, name: "Remote Backed Property")
        let metadata = SessionMetadata(
            schemaVersion: 1,
            propertyID: propertyID,
            sessionID: sessionID,
            orgID: orgID,
            propertyNameAtCapture: "Captured Property",
            propertyNameAtExport: nil,
            captureProfile: "commercial",
            startedAt: startedAt,
            endedAt: endedAt,
            status: .completed,
            isBaselineSession: false,
            exportedAt: nil,
            appVersion: "test",
            deviceModel: "sim",
            osVersion: "test",
            shots: [],
            issues: []
        )

        let payload = try appState._debugEncodeSessionEnsureInsertPayloadForTests(
            orgID: orgID,
            propertyID: propertyID,
            sessionID: sessionID,
            property: property,
            metadata: metadata,
            updatedBy: actorID
        )

        XCTAssertEqual(payload["id"] as? String, sessionID.uuidString)
        XCTAssertEqual(payload["org_id"] as? String, orgID.uuidString)
        XCTAssertEqual(payload["property_id"] as? String, propertyID.uuidString)
        XCTAssertEqual(payload["title"] as? String, "Captured Property")
        XCTAssertEqual(payload["status"] as? String, "completed")
        XCTAssertEqual(payload["updated_by"] as? String, actorID.uuidString)
        XCTAssertNotNil(payload["started_at"] as? String)
        XCTAssertNotNil(payload["completed_at"] as? String)
    }

    func testSessionEnsureInsertPayloadDoesNotWipeCoordinationLifecycleOrProfileFields() throws {
        let appState = AppState(disableCloudBackupForTests: true)
        let orgID = UUID()
        let propertyID = UUID()
        let sessionID = UUID()
        let metadata = SessionMetadata(
            schemaVersion: 1,
            propertyID: propertyID,
            sessionID: sessionID,
            propertyNameAtCapture: "Property",
            propertyNameAtExport: nil,
            captureProfile: "residential",
            startedAt: Date(timeIntervalSinceReferenceDate: 100),
            endedAt: nil,
            status: .draft,
            isBaselineSession: false,
            exportedAt: Date(timeIntervalSinceReferenceDate: 200),
            isSealed: true,
            firstDeliveredAt: Date(timeIntervalSinceReferenceDate: 300),
            reExportExpiresAt: Date(timeIntervalSinceReferenceDate: 400),
            appVersion: "test",
            deviceModel: "sim",
            osVersion: "test",
            shots: [],
            issues: []
        )

        let payload = try appState._debugEncodeSessionEnsureInsertPayloadForTests(
            orgID: orgID,
            propertyID: propertyID,
            sessionID: sessionID,
            property: nil,
            metadata: metadata,
            updatedBy: UUID()
        )

        XCTAssertNil(payload["capture_profile"])
        XCTAssertNil(payload["locked_by_user_id"])
        XCTAssertNil(payload["locked_by_device_id"])
        XCTAssertNil(payload["locked_at"])
        XCTAssertNil(payload["coordination_tier1_snapshot"])
        XCTAssertNil(payload["deleted_at"])
        XCTAssertNil(payload["revision"])
        XCTAssertNil(payload["exported_at"])
        XCTAssertNil(payload["is_sealed"])
        XCTAssertNil(payload["first_delivered_at"])
        XCTAssertNil(payload["re_export_expires_at"])
    }

    func testCaptureProfileRemoteUpdatePayloadIncludesProfileAndUpdatedBy() throws {
        let appState = AppState(disableCloudBackupForTests: true)
        let updatedBy = UUID()

        let payload = try appState._debugEncodeCaptureProfileUpdatePayloadForTests(
            profile: .commercial,
            updatedBy: updatedBy
        )

        XCTAssertEqual(payload["capture_profile"] as? String, "commercial")
        XCTAssertEqual(payload["updated_by"] as? String, updatedBy.uuidString)
        XCTAssertNil(payload["name"])
        XCTAssertNil(payload["status"])
        XCTAssertNil(payload["deleted_at"])
        XCTAssertNil(payload["revision"])
    }

    func testEmptySessionCaptureProfileUpdateResultIsTreatedAsFailure() throws {
        let appState = AppState(disableCloudBackupForTests: true)

        XCTAssertThrowsError(
            try appState._debugValidateEmptyCaptureProfileUpdateResultForTests(
                table: "sessions",
                id: UUID(),
                orgID: UUID(),
                propertyID: UUID(),
                profile: .commercial
            )
        )
    }

    func testEmptyPropertyCaptureProfileUpdateResultIsTreatedAsFailure() throws {
        let appState = AppState(disableCloudBackupForTests: true)

        XCTAssertThrowsError(
            try appState._debugValidateEmptyCaptureProfileUpdateResultForTests(
                table: "properties",
                id: UUID(),
                orgID: UUID(),
                propertyID: nil,
                profile: .commercial
            )
        )
    }

    func testVerifiedSessionCaptureProfileUpdateResultReturnsSnapshot() throws {
        let appState = AppState(disableCloudBackupForTests: true)

        let profile = try appState._debugValidateCaptureProfileUpdateResultForTests(
            table: "sessions",
            id: UUID(),
            orgID: UUID(),
            propertyID: UUID(),
            profile: .commercial
        )

        XCTAssertEqual(profile, CaptureProfile.commercial.rawValue)
    }

    func testSessionUpsertPayloadPrefersSelectedSessionSnapshotOverStaleMetadataProfile() throws {
        let appState = AppState(disableCloudBackupForTests: true)
        let orgID = UUID()
        let propertyID = UUID()
        let sessionID = UUID()
        let property = Property(id: propertyID, orgId: orgID, captureProfile: .residential, name: "Profile Property")
        let session = Session(id: sessionID, propertyID: propertyID, captureProfile: .commercial)
        let metadata = SessionMetadata(
            schemaVersion: 1,
            propertyID: propertyID,
            sessionID: sessionID,
            orgID: orgID,
            propertyNameAtCapture: "Profile Property",
            propertyNameAtExport: nil,
            captureProfile: "residential",
            startedAt: session.startedAt,
            endedAt: nil,
            status: .draft,
            isBaselineSession: false,
            exportedAt: nil,
            appVersion: "test",
            deviceModel: "sim",
            osVersion: "test",
            shots: [],
            issues: []
        )

        let payload = try appState._debugEncodeSessionUpsertPayloadForTests(
            orgID: orgID,
            propertyID: propertyID,
            session: session,
            property: property,
            metadata: metadata
        )

        XCTAssertEqual(payload["id"] as? String, sessionID.uuidString)
        XCTAssertEqual(payload["capture_profile"] as? String, "commercial")
    }

    func testCaptureProfileSessionEnsurePayloadUsesActualLocalSessionStatus() throws {
        let appState = AppState(disableCloudBackupForTests: true)
        let orgID = UUID()
        let propertyID = UUID()
        let sessionID = UUID()
        let actorID = UUID()
        let property = Property(id: propertyID, orgId: orgID, name: "Lifecycle Property")
        let session = Session(
            id: sessionID,
            propertyID: propertyID,
            startedAt: Date(timeIntervalSinceReferenceDate: 2_000),
            status: .completed,
            endedAt: Date(timeIntervalSinceReferenceDate: 2_500),
            captureProfile: .commercial
        )
        let metadata = SessionMetadata(
            schemaVersion: 1,
            propertyID: propertyID,
            sessionID: sessionID,
            orgID: orgID,
            propertyNameAtCapture: "Lifecycle Property",
            propertyNameAtExport: nil,
            captureProfile: "residential",
            startedAt: Date(timeIntervalSinceReferenceDate: 1_000),
            endedAt: nil,
            status: .draft,
            isBaselineSession: false,
            exportedAt: nil,
            appVersion: "test",
            deviceModel: "sim",
            osVersion: "test",
            shots: [],
            issues: []
        )

        let payload = try appState._debugEncodeCaptureProfileSessionEnsurePayloadForTests(
            orgID: orgID,
            propertyID: propertyID,
            session: session,
            property: property,
            metadata: metadata,
            profile: .commercial,
            updatedBy: actorID
        )

        XCTAssertEqual(payload["id"] as? String, sessionID.uuidString)
        XCTAssertEqual(payload["status"] as? String, Session.Status.completed.rawValue)
        XCTAssertNotNil(payload["completed_at"] as? String)
        XCTAssertNil(payload["capture_profile"])
    }

    func testShotMetadataWriteFailureDoesNotMutateLocalMetadata() async throws {
        let suiteName = "Phase2C15-4-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(true, forKey: "supabase_enabled")
        defaults.set(true, forKey: "shadow_write_enabled")
        defaults.set(false, forKey: "supabase_read_enabled")
        defaults.set(false, forKey: "supabase_property_read_enabled")

        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScoutCapture-2C15-4-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: storageRoot)
        }

        let localStore = LocalStore(testStorageRootURL: storageRoot)
        var attempted = false
        let appState = AppState(
            localStore: localStore,
            userDefaults: defaults,
            shotMetadataWriteOverride: { _, _, _, _ in
                attempted = true
                throw NSError(domain: "ScoutCaptureTests", code: 42, userInfo: [
                    NSLocalizedDescriptionKey: "intentional failure"
                ])
            },
            disableCloudBackupForTests: true
        )

        let orgID = UUID()
        let propertyID = UUID()
        let sessionID = UUID()
        let shotID = UUID()
        _ = try localStore.createOrganization(Organization(id: orgID, name: "Org"))
        _ = try localStore.createProperty(Property(id: propertyID, orgId: orgID, name: "Property"))
        _ = try localStore.upsertSession(Session(id: sessionID, propertyID: propertyID))
        let shot = ShotMetadata(
            shotID: shotID,
            propertyID: propertyID,
            sessionID: sessionID,
            createdAt: Date(timeIntervalSinceReferenceDate: 100),
            updatedAt: Date(timeIntervalSinceReferenceDate: 110),
            building: "Main",
            elevation: "North",
            detailType: "Window",
            angleIndex: 1,
            shotKey: "main|north|window|1",
            isGuided: false,
            isFlagged: false,
            issueID: nil,
            issueStatus: nil,
            noteText: "local note",
            noteCategory: nil,
            originalFilename: "original.heic",
            originalRelativePath: "Originals/original.heic",
            originalByteSize: 123,
            uploadState: "pending",
            uploadAttempts: 0,
            stampedFilename: nil,
            stampedRelativePath: nil,
            captureMode: nil,
            lens: nil,
            exifOrientation: 1,
            latitude: nil,
            longitude: nil,
            accuracyMeters: nil,
            imageWidth: nil,
            imageHeight: nil
        )
        try localStore.upsertShot(propertyID: propertyID, sessionID: sessionID, shot: shot, matchMode: .append)

        await MainActor.run {
            appState.refreshProperties()
            appState._debugSetOrganizationContextForTests(
                memberships: [ActiveOrganizationMembership(id: orgID, name: "Org", role: "owner")],
                activeOrganizationID: orgID,
                ready: true
            )
            appState.scheduleShotMetadataSupabaseWriteIfNeeded(
                propertyID: propertyID,
                sessionID: sessionID,
                shotID: shotID,
                reason: "test_failure",
                allowInsert: true
            )
        }
        try await Task.sleep(nanoseconds: 200_000_000)

        let persisted = try localStore.loadSessionMetadata(propertyID: propertyID, sessionID: sessionID)
            .shots
            .first(where: { $0.shotID == shotID })
        XCTAssertTrue(attempted)
        XCTAssertEqual(persisted?.shotID, shotID)
        XCTAssertEqual(persisted?.building, "Main")
        XCTAssertEqual(persisted?.elevation, "North")
        XCTAssertEqual(persisted?.detailType, "Window")
        XCTAssertEqual(persisted?.shotKey, "main|north|window|1")
        XCTAssertEqual(persisted?.noteText, "local note")
        XCTAssertEqual(persisted?.uploadState, "pending")
        XCTAssertEqual(persisted?.uploadAttempts, 0)
    }

    func testShotMetadataWriteUsesActiveOrgWhenLocalPropertyOrgIsStaleForSelectedProperty() async throws {
        let suiteName = "Phase2C15-4-StaleOrg-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(true, forKey: "supabase_enabled")
        defaults.set(true, forKey: "shadow_write_enabled")

        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScoutCapture-2C15-4-StaleOrg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: storageRoot)
        }

        let localStore = LocalStore(testStorageRootURL: storageRoot)
        let activeOrgID = UUID()
        let staleOrgID = UUID()
        let propertyID = UUID()
        let sessionID = UUID()
        let shotID = UUID()
        _ = try localStore.createOrganization(Organization(id: activeOrgID, name: "Active Org"))
        _ = try localStore.createOrganization(Organization(id: staleOrgID, name: "Stale Org"))
        _ = try localStore.createProperty(Property(id: propertyID, orgId: staleOrgID, name: "Remote Backed Property"))
        _ = try localStore.upsertSession(Session(id: sessionID, propertyID: propertyID))
        try localStore.upsertShot(
            propertyID: propertyID,
            sessionID: sessionID,
            shot: ShotMetadata(
                shotID: shotID,
                propertyID: propertyID,
                sessionID: sessionID,
                createdAt: Date(timeIntervalSinceReferenceDate: 100),
                updatedAt: Date(timeIntervalSinceReferenceDate: 110),
                building: "Main",
                elevation: "North",
                detailType: "Window",
                angleIndex: 1,
                shotKey: "main|north|window|1",
                isGuided: false,
                isFlagged: false,
                issueID: nil,
                issueStatus: nil,
                noteText: nil,
                noteCategory: nil,
                originalFilename: "original.heic",
                originalRelativePath: "Originals/original.heic",
                originalByteSize: 123,
                uploadState: "pending",
                uploadAttempts: 0,
                stampedFilename: nil,
                stampedRelativePath: nil,
                captureMode: nil,
                lens: nil,
                exifOrientation: 1,
                latitude: nil,
                longitude: nil,
                accuracyMeters: nil,
                imageWidth: nil,
                imageHeight: nil
            ),
            matchMode: .append
        )

        var attemptedOrgID: UUID?
        let appState = AppState(
            localStore: localStore,
            userDefaults: defaults,
            shotMetadataWriteOverride: { orgID, _, _, _ in
                attemptedOrgID = orgID
            },
            disableCloudBackupForTests: true
        )

        await MainActor.run {
            appState.refreshProperties()
            appState._debugSetOrganizationContextForTests(
                memberships: [ActiveOrganizationMembership(id: activeOrgID, name: "Active Org", role: "owner")],
                activeOrganizationID: activeOrgID,
                ready: true
            )
            appState.selectProperty(id: propertyID)
            appState.scheduleShotMetadataSupabaseWriteIfNeeded(
                propertyID: propertyID,
                sessionID: sessionID,
                shotID: shotID,
                reason: "test_stale_org",
                allowInsert: true
            )
        }
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(attemptedOrgID, activeOrgID)
    }

    func testShotMetadataWriteSkipsWrongOrgWhenPropertyIsNotActiveContext() async throws {
        let suiteName = "Phase2C15-4-WrongOrg-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(true, forKey: "supabase_enabled")
        defaults.set(true, forKey: "shadow_write_enabled")

        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScoutCapture-2C15-4-WrongOrg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: storageRoot)
        }

        let localStore = LocalStore(testStorageRootURL: storageRoot)
        let activeOrgID = UUID()
        let staleOrgID = UUID()
        let propertyID = UUID()
        let sessionID = UUID()
        let shotID = UUID()
        _ = try localStore.createOrganization(Organization(id: activeOrgID, name: "Active Org"))
        _ = try localStore.createOrganization(Organization(id: staleOrgID, name: "Stale Org"))
        _ = try localStore.createProperty(Property(id: propertyID, orgId: staleOrgID, name: "Wrong Org Property"))
        _ = try localStore.upsertSession(Session(id: sessionID, propertyID: propertyID))
        try localStore.upsertShot(
            propertyID: propertyID,
            sessionID: sessionID,
            shot: ShotMetadata(
                shotID: shotID,
                propertyID: propertyID,
                sessionID: sessionID,
                createdAt: Date(timeIntervalSinceReferenceDate: 100),
                updatedAt: Date(timeIntervalSinceReferenceDate: 110),
                building: "Main",
                elevation: "North",
                detailType: "Window",
                angleIndex: 1,
                shotKey: "main|north|window|1",
                isGuided: false,
                isFlagged: false,
                issueID: nil,
                issueStatus: nil,
                noteText: nil,
                noteCategory: nil,
                originalFilename: "original.heic",
                originalRelativePath: "Originals/original.heic",
                originalByteSize: 123,
                uploadState: "pending",
                uploadAttempts: 0,
                stampedFilename: nil,
                stampedRelativePath: nil,
                captureMode: nil,
                lens: nil,
                exifOrientation: 1,
                latitude: nil,
                longitude: nil,
                accuracyMeters: nil,
                imageWidth: nil,
                imageHeight: nil
            ),
            matchMode: .append
        )

        var attempted = false
        let appState = AppState(
            localStore: localStore,
            userDefaults: defaults,
            shotMetadataWriteOverride: { _, _, _, _ in
                attempted = true
            },
            disableCloudBackupForTests: true
        )

        await MainActor.run {
            appState.refreshProperties()
            appState._debugSetOrganizationContextForTests(
                memberships: [ActiveOrganizationMembership(id: activeOrgID, name: "Active Org", role: "owner")],
                activeOrganizationID: activeOrgID,
                ready: true
            )
            appState.scheduleShotMetadataSupabaseWriteIfNeeded(
                propertyID: propertyID,
                sessionID: sessionID,
                shotID: shotID,
                reason: "test_wrong_org",
                allowInsert: true
            )
        }
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertFalse(attempted)
    }

    func testNewSessionInheritsPropertyCaptureProfileDefault() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }
        let orgID = UUID()
        let propertyID = UUID()
        try seedProperty(fixture, orgID: orgID, propertyID: propertyID)
        var property = try XCTUnwrap(fixture.localStore.fetchProperties().first(where: { $0.id == propertyID }))
        property.captureProfile = .commercial
        _ = try fixture.localStore.updateProperty(property)

        await prepareAppState(fixture.appState, orgID: orgID)
        await MainActor.run {
            fixture.appState.selectProperty(id: propertyID)
        }

        let session = await MainActor.run {
            fixture.appState.startSession()
        }

        XCTAssertEqual(session?.captureProfile, .commercial)
    }

    func testSessionCaptureProfileSnapshotSurvivesPropertyDefaultChange() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }
        let orgID = UUID()
        let propertyID = UUID()
        try seedProperty(fixture, orgID: orgID, propertyID: propertyID)
        var property = try XCTUnwrap(fixture.localStore.fetchProperties().first(where: { $0.id == propertyID }))
        property.captureProfile = .residential
        _ = try fixture.localStore.updateProperty(property)
        let session = try fixture.localStore.upsertSession(
            Session(id: UUID(), propertyID: propertyID, captureProfile: .residential)
        )
        await prepareAppState(fixture.appState, orgID: orgID)

        _ = await MainActor.run {
            fixture.appState.setSessionCaptureProfileSnapshot(
                propertyID: propertyID,
                sessionID: session.id,
                profile: .residential
            )
        }
        _ = await MainActor.run {
            fixture.appState.setPropertyCaptureProfileDefault(
                propertyID: propertyID,
                profile: .commercial
            )
        }

        let metadata = try fixture.localStore.loadSessionMetadata(propertyID: propertyID, sessionID: session.id)
        let updatedProperty = try XCTUnwrap(fixture.localStore.fetchProperties().first(where: { $0.id == propertyID }))
        XCTAssertEqual(metadata.captureProfile, CaptureProfile.residential.rawValue)
        XCTAssertEqual(updatedProperty.captureProfile, .commercial)
    }

    func testSessionCaptureProfileSnapshotUsesDirectToggleTargetOverPropertyDefault() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }
        let orgID = UUID()
        let propertyID = UUID()
        try seedProperty(fixture, orgID: orgID, propertyID: propertyID)
        var property = try XCTUnwrap(fixture.localStore.fetchProperties().first(where: { $0.id == propertyID }))
        property.captureProfile = .residential
        _ = try fixture.localStore.updateProperty(property)
        let session = try fixture.localStore.upsertSession(
            Session(id: UUID(), propertyID: propertyID, captureProfile: .residential)
        )
        await prepareAppState(fixture.appState, orgID: orgID)

        let updated = await MainActor.run {
            fixture.appState.setSessionCaptureProfileSnapshot(
                propertyID: propertyID,
                sessionID: session.id,
                profile: .commercial
            )
        }

        let metadata = try fixture.localStore.loadSessionMetadata(propertyID: propertyID, sessionID: session.id)
        let storedSession = try XCTUnwrap(
            fixture.localStore.fetchSessionsForCacheBuild(propertyID: propertyID)
                .first(where: { $0.id == session.id })
        )
        XCTAssertTrue(updated)
        XCTAssertEqual(metadata.captureProfile, CaptureProfile.commercial.rawValue)
        XCTAssertEqual(storedSession.captureProfile, .commercial)
    }

    func testBackfillWritesNullRemotePropertyProfileFromKnownLocalDefault() async throws {
        var writtenPropertyProfile: CaptureProfile?
        var writtenSessionProfile: CaptureProfile?
        let fixture = try makeFixture(
            captureProfileBackfillFetchOverride: { _, _, _ in
                AppState.CaptureProfileBackfillRemoteState(
                    propertyRowExists: true,
                    propertyCaptureProfile: nil
                )
            },
            captureProfileBackfillWriteOverride: { _, _, _, propertyProfile, sessionProfile in
                writtenPropertyProfile = propertyProfile
                writtenSessionProfile = sessionProfile
            }
        )
        defer { tearDownFixture(fixture) }
        let orgID = UUID()
        let propertyID = UUID()
        try seedProperty(fixture, orgID: orgID, propertyID: propertyID)

        await prepareAppState(fixture.appState, orgID: orgID)
        await MainActor.run {
            fixture.appState.selectProperty(id: propertyID)
        }
        let didBackfill = await fixture.appState.backfillCaptureProfilesIfMissing(
            propertyID: propertyID,
            sessionID: nil,
            propertyProfile: .commercial,
            sessionProfile: nil
        )

        XCTAssertTrue(didBackfill)
        XCTAssertEqual(writtenPropertyProfile, .commercial)
        XCTAssertNil(writtenSessionProfile)
    }

    func testBackfillWritesNullRemoteSessionProfileFromLocalSessionJSON() async throws {
        var writtenPropertyProfile: CaptureProfile?
        var writtenSessionProfile: CaptureProfile?
        let fixture = try makeFixture(
            captureProfileBackfillFetchOverride: { _, _, _ in
                AppState.CaptureProfileBackfillRemoteState(
                    propertyRowExists: true,
                    propertyCaptureProfile: .residential,
                    sessionRowExists: true,
                    sessionCaptureProfile: nil
                )
            },
            captureProfileBackfillWriteOverride: { _, _, _, propertyProfile, sessionProfile in
                writtenPropertyProfile = propertyProfile
                writtenSessionProfile = sessionProfile
            }
        )
        defer { tearDownFixture(fixture) }
        let orgID = UUID()
        let propertyID = UUID()
        let sessionID = UUID()
        try seedProperty(fixture, orgID: orgID, propertyID: propertyID)
        let session = try fixture.localStore.upsertSession(
            Session(id: sessionID, propertyID: propertyID, captureProfile: .residential)
        )

        await prepareAppState(fixture.appState, orgID: orgID, role: "manager")
        await MainActor.run {
            fixture.appState.selectProperty(id: propertyID)
            fixture.appState.currentSession = session
        }
        let didBackfill = await fixture.appState.backfillCaptureProfilesIfMissing(
            propertyID: propertyID,
            sessionID: sessionID,
            propertyProfile: .commercial,
            sessionProfile: .commercial
        )

        XCTAssertTrue(didBackfill)
        XCTAssertNil(writtenPropertyProfile)
        XCTAssertEqual(writtenSessionProfile, .commercial)
    }

    func testBackfillEnsuresMissingRemoteSessionBeforeWritingLocalProfile() async throws {
        var didEnsure = false
        var writtenSessionProfile: CaptureProfile?
        let fixture = try makeFixture(
            captureProfileBackfillFetchOverride: { _, _, _ in
                AppState.CaptureProfileBackfillRemoteState(
                    propertyRowExists: true,
                    propertyCaptureProfile: .residential,
                    sessionRowExists: false,
                    sessionCaptureProfile: nil
                )
            },
            captureProfileBackfillEnsureOverride: { _, _, _, profile in
                didEnsure = true
                XCTAssertEqual(profile, .residential)
            },
            captureProfileBackfillWriteOverride: { _, _, _, propertyProfile, sessionProfile in
                XCTAssertNil(propertyProfile)
                writtenSessionProfile = sessionProfile
            }
        )
        defer { tearDownFixture(fixture) }
        let orgID = UUID()
        let propertyID = UUID()
        let sessionID = UUID()
        try seedProperty(fixture, orgID: orgID, propertyID: propertyID)
        let session = try fixture.localStore.upsertSession(
            Session(id: sessionID, propertyID: propertyID, captureProfile: .residential)
        )

        await prepareAppState(fixture.appState, orgID: orgID)
        await MainActor.run {
            fixture.appState.selectProperty(id: propertyID)
            fixture.appState.currentSession = session
        }
        let didBackfill = await fixture.appState.backfillCaptureProfilesIfMissing(
            propertyID: propertyID,
            sessionID: sessionID,
            propertyProfile: nil,
            sessionProfile: .residential
        )

        XCTAssertTrue(didBackfill)
        XCTAssertTrue(didEnsure)
        XCTAssertEqual(writtenSessionProfile, .residential)
    }

    func testBackfillMissingRemoteSessionEnsureFailureDoesNotWriteProfile() async throws {
        var didWriteRemote = false
        let fixture = try makeFixture(
            captureProfileBackfillFetchOverride: { _, _, _ in
                AppState.CaptureProfileBackfillRemoteState(
                    propertyRowExists: true,
                    propertyCaptureProfile: .residential,
                    sessionRowExists: false,
                    sessionCaptureProfile: nil
                )
            },
            captureProfileBackfillEnsureOverride: { _, _, _, _ in
                throw NSError(domain: "ScoutCaptureTests", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "ensure failed"
                ])
            },
            captureProfileBackfillWriteOverride: { _, _, _, _, _ in
                didWriteRemote = true
            }
        )
        defer { tearDownFixture(fixture) }
        let orgID = UUID()
        let propertyID = UUID()
        let sessionID = UUID()
        try seedProperty(fixture, orgID: orgID, propertyID: propertyID)
        let session = try fixture.localStore.upsertSession(
            Session(id: sessionID, propertyID: propertyID, captureProfile: .residential)
        )

        await prepareAppState(fixture.appState, orgID: orgID)
        await MainActor.run {
            fixture.appState.selectProperty(id: propertyID)
            fixture.appState.currentSession = session
        }
        let didBackfill = await fixture.appState.backfillCaptureProfilesIfMissing(
            propertyID: propertyID,
            sessionID: sessionID,
            propertyProfile: nil,
            sessionProfile: .residential
        )

        XCTAssertFalse(didBackfill)
        XCTAssertFalse(didWriteRemote)
    }

    func testMaintenanceBackfillFillsNullPropertyAndSessionProfiles() async throws {
        var fetchCalls: [UUID?] = []
        var writtenPropertyProfile: CaptureProfile?
        var writtenSessionProfile: CaptureProfile?
        let orgID = UUID()
        let propertyID = UUID()
        let sessionID = UUID()
        let fixture = try makeFixture(
            captureProfileBackfillFetchOverride: { _, _, sessionID in
                fetchCalls.append(sessionID)
                if sessionID == nil {
                    return AppState.CaptureProfileBackfillRemoteState(
                        propertyRowExists: true,
                        propertyCaptureProfile: nil
                    )
                }
                return AppState.CaptureProfileBackfillRemoteState(
                    propertyRowExists: true,
                    propertyCaptureProfile: .commercial,
                    sessionRowExists: true,
                    sessionCaptureProfile: nil
                )
            },
            captureProfileRemotePropertyIDsFetchOverride: { _ in
                [propertyID]
            },
            captureProfileBackfillWriteOverride: { _, _, _, propertyProfile, sessionProfile in
                if let propertyProfile {
                    writtenPropertyProfile = propertyProfile
                }
                if let sessionProfile {
                    writtenSessionProfile = sessionProfile
                }
            }
        )
        defer { tearDownFixture(fixture) }
        try seedProperty(fixture, orgID: orgID, propertyID: propertyID)
        var property = try XCTUnwrap(fixture.localStore.fetchProperties().first(where: { $0.id == propertyID }))
        property.captureProfile = .commercial
        _ = try fixture.localStore.updateProperty(property)
        _ = try fixture.localStore.upsertSession(
            Session(id: sessionID, propertyID: propertyID, captureProfile: .residential)
        )

        await prepareAppState(fixture.appState, orgID: orgID)
        let result = await fixture.appState.runCaptureProfileMaintenanceBackfill()

        XCTAssertEqual(result.propertyProfilesFilled, 1)
        XCTAssertEqual(result.sessionProfilesFilled, 1)
        XCTAssertEqual(result.sessionsEnsured, 0)
        XCTAssertEqual(result.localPropertiesFound, 1)
        XCTAssertEqual(result.propertiesScanned, 1)
        XCTAssertEqual(result.sessionsScanned, 1)
        XCTAssertEqual(result.remotePropertiesChecked, 1)
        XCTAssertEqual(result.remoteSessionsChecked, 1)
        XCTAssertEqual(result.failed, 0)
        XCTAssertEqual(writtenPropertyProfile, .commercial)
        XCTAssertEqual(writtenSessionProfile, .residential)
        XCTAssertTrue(fetchCalls.contains(nil))
        XCTAssertTrue(fetchCalls.contains(sessionID))
    }

    func testMaintenanceBackfillEnsuresMissingRemoteSessionThenFillsProfile() async throws {
        var didEnsure = false
        var writtenSessionProfile: CaptureProfile?
        let orgID = UUID()
        let propertyID = UUID()
        let sessionID = UUID()
        let fixture = try makeFixture(
            captureProfileBackfillFetchOverride: { _, _, sessionID in
                if sessionID == nil {
                    return AppState.CaptureProfileBackfillRemoteState(
                        propertyRowExists: true,
                        propertyCaptureProfile: .residential
                    )
                }
                return AppState.CaptureProfileBackfillRemoteState(
                    propertyRowExists: true,
                    propertyCaptureProfile: .residential,
                    sessionRowExists: false,
                    sessionCaptureProfile: nil
                )
            },
            captureProfileRemotePropertyIDsFetchOverride: { _ in
                [propertyID]
            },
            captureProfileBackfillEnsureOverride: { _, _, _, profile in
                didEnsure = true
                XCTAssertEqual(profile, .commercial)
            },
            captureProfileBackfillWriteOverride: { _, _, _, propertyProfile, sessionProfile in
                XCTAssertNil(propertyProfile)
                writtenSessionProfile = sessionProfile
            }
        )
        defer { tearDownFixture(fixture) }
        try seedProperty(fixture, orgID: orgID, propertyID: propertyID)
        _ = try fixture.localStore.upsertSession(
            Session(id: sessionID, propertyID: propertyID, captureProfile: .commercial)
        )

        await prepareAppState(fixture.appState, orgID: orgID)
        let result = await fixture.appState.runCaptureProfileMaintenanceBackfill()

        XCTAssertTrue(didEnsure)
        XCTAssertEqual(result.sessionProfilesFilled, 1)
        XCTAssertEqual(result.sessionsEnsured, 1)
        XCTAssertEqual(result.propertiesScanned, 1)
        XCTAssertEqual(result.sessionsScanned, 1)
        XCTAssertEqual(result.remoteSessionsChecked, 1)
        XCTAssertEqual(result.failed, 0)
        XCTAssertEqual(writtenSessionProfile, .commercial)
    }

    func testMaintenanceBackfillDoesNotOverwriteNonNullRemoteValues() async throws {
        var didWriteRemote = false
        var didEnsure = false
        let orgID = UUID()
        let propertyID = UUID()
        let sessionID = UUID()
        let fixture = try makeFixture(
            captureProfileBackfillFetchOverride: { _, _, sessionID in
                AppState.CaptureProfileBackfillRemoteState(
                    propertyRowExists: true,
                    propertyCaptureProfile: .residential,
                    sessionRowExists: sessionID != nil,
                    sessionCaptureProfile: sessionID == nil ? nil : .residential
                )
            },
            captureProfileRemotePropertyIDsFetchOverride: { _ in
                [propertyID]
            },
            captureProfileBackfillEnsureOverride: { _, _, _, _ in
                didEnsure = true
            },
            captureProfileBackfillWriteOverride: { _, _, _, _, _ in
                didWriteRemote = true
            }
        )
        defer { tearDownFixture(fixture) }
        try seedProperty(fixture, orgID: orgID, propertyID: propertyID)
        var property = try XCTUnwrap(fixture.localStore.fetchProperties().first(where: { $0.id == propertyID }))
        property.captureProfile = .commercial
        _ = try fixture.localStore.updateProperty(property)
        _ = try fixture.localStore.upsertSession(
            Session(id: sessionID, propertyID: propertyID, captureProfile: .commercial)
        )

        await prepareAppState(fixture.appState, orgID: orgID)
        let result = await fixture.appState.runCaptureProfileMaintenanceBackfill()

        XCTAssertFalse(didWriteRemote)
        XCTAssertFalse(didEnsure)
        XCTAssertEqual(result.propertyProfilesFilled, 0)
        XCTAssertEqual(result.sessionProfilesFilled, 0)
        XCTAssertEqual(result.sessionsEnsured, 0)
        XCTAssertEqual(result.propertiesScanned, 1)
        XCTAssertEqual(result.sessionsScanned, 1)
        XCTAssertEqual(result.remotePropertiesChecked, 1)
        XCTAssertEqual(result.remoteSessionsChecked, 1)
        XCTAssertEqual(result.failed, 0)
    }

    func testMaintenanceBackfillScansSelectedPropertyWithStaleLocalOrg() async throws {
        var writtenPropertyProfile: CaptureProfile?
        var writtenSessionProfile: CaptureProfile?
        let activeOrgID = UUID()
        let staleOrgID = UUID()
        let propertyID = UUID()
        let sessionID = UUID()
        let fixture = try makeFixture(
            captureProfileBackfillFetchOverride: { _, _, sessionID in
                if sessionID == nil {
                    return AppState.CaptureProfileBackfillRemoteState(
                        propertyRowExists: true,
                        propertyCaptureProfile: nil
                    )
                }
                return AppState.CaptureProfileBackfillRemoteState(
                    propertyRowExists: true,
                    propertyCaptureProfile: .commercial,
                    sessionRowExists: true,
                    sessionCaptureProfile: nil
                )
            },
            captureProfileRemotePropertyIDsFetchOverride: { _ in
                [propertyID]
            },
            captureProfileBackfillWriteOverride: { _, _, _, propertyProfile, sessionProfile in
                if let propertyProfile {
                    writtenPropertyProfile = propertyProfile
                }
                if let sessionProfile {
                    writtenSessionProfile = sessionProfile
                }
            }
        )
        defer { tearDownFixture(fixture) }
        _ = try fixture.localStore.createOrganization(Organization(id: activeOrgID, name: "Active Org"))
        _ = try fixture.localStore.createOrganization(Organization(id: staleOrgID, name: "Stale Org"))
        _ = try fixture.localStore.createProperty(
            Property(
                id: propertyID,
                orgId: staleOrgID,
                folderId: "00005",
                captureProfile: .commercial,
                name: "Selected Stale Org",
                address: "135 Main Street",
                street: "135 Main Street",
                city: "Atlanta",
                state: "GA",
                zip: "30301"
            )
        )
        let session = try fixture.localStore.upsertSession(
            Session(id: sessionID, propertyID: propertyID, captureProfile: .residential)
        )

        await prepareAppState(fixture.appState, orgID: activeOrgID)
        await MainActor.run {
            fixture.appState.selectProperty(id: propertyID)
            fixture.appState.currentSession = session
        }
        let result = await fixture.appState.runCaptureProfileMaintenanceBackfill()

        XCTAssertEqual(result.localPropertiesFound, 1)
        XCTAssertEqual(result.propertiesScanned, 1)
        XCTAssertEqual(result.propertiesFilteredOrgMismatch, 0)
        XCTAssertEqual(result.remoteActivePropertyCount, 1)
        XCTAssertEqual(result.staleOrgReconciledCount, 1)
        XCTAssertEqual(result.trueOrgMismatchCount, 0)
        XCTAssertEqual(result.propertyProfilesFilled, 1)
        XCTAssertEqual(result.sessionProfilesFilled, 1)
        XCTAssertEqual(writtenPropertyProfile, .commercial)
        XCTAssertEqual(writtenSessionProfile, .residential)
    }

    func testMaintenanceBackfillReportsAllPropertiesFilteredByOrgMismatch() async throws {
        var didFetchRemote = false
        let fixture = try makeFixture(
            captureProfileBackfillFetchOverride: { _, _, _ in
                didFetchRemote = true
                return AppState.CaptureProfileBackfillRemoteState(
                    propertyRowExists: true,
                    propertyCaptureProfile: nil
                )
            },
            captureProfileRemotePropertyIDsFetchOverride: { _ in
                []
            }
        )
        defer { tearDownFixture(fixture) }
        let activeOrgID = UUID()
        let foreignOrgID = UUID()
        let propertyID = UUID()
        _ = try fixture.localStore.createOrganization(Organization(id: activeOrgID, name: "Active Org"))
        _ = try fixture.localStore.createOrganization(Organization(id: foreignOrgID, name: "Foreign Org"))
        _ = try fixture.localStore.createProperty(
            Property(
                id: propertyID,
                orgId: foreignOrgID,
                folderId: "00006",
                captureProfile: .commercial,
                name: "Foreign Property",
                address: "864 Main Street",
                street: "864 Main Street",
                city: "Atlanta",
                state: "GA",
                zip: "30301"
            )
        )

        await prepareAppState(fixture.appState, orgID: activeOrgID)
        let result = await fixture.appState.runCaptureProfileMaintenanceBackfill()

        XCTAssertFalse(didFetchRemote)
        XCTAssertEqual(result.localPropertiesFound, 1)
        XCTAssertEqual(result.propertiesScanned, 0)
        XCTAssertEqual(result.propertiesFilteredOrgMismatch, 1)
        XCTAssertEqual(result.remoteActivePropertyCount, 0)
        XCTAssertEqual(result.staleOrgReconciledCount, 0)
        XCTAssertEqual(result.trueOrgMismatchCount, 1)
        XCTAssertEqual(result.remotePropertiesChecked, 0)
        XCTAssertEqual(result.remoteSessionsChecked, 0)
    }

    func testMaintenanceBackfillDoesNotInferPropertyDefaultFromConflictingSessions() async throws {
        var writtenPropertyProfile: CaptureProfile?
        var writtenSessionProfiles: [CaptureProfile] = []
        let orgID = UUID()
        let propertyID = UUID()
        let fixture = try makeFixture(
            captureProfileBackfillFetchOverride: { _, _, sessionID in
                if sessionID == nil {
                    return AppState.CaptureProfileBackfillRemoteState(
                        propertyRowExists: true,
                        propertyCaptureProfile: nil
                    )
                }
                return AppState.CaptureProfileBackfillRemoteState(
                    propertyRowExists: true,
                    propertyCaptureProfile: nil,
                    sessionRowExists: true,
                    sessionCaptureProfile: nil
                )
            },
            captureProfileRemotePropertyIDsFetchOverride: { _ in
                [propertyID]
            },
            captureProfileBackfillWriteOverride: { _, _, _, propertyProfile, sessionProfile in
                if let propertyProfile {
                    writtenPropertyProfile = propertyProfile
                }
                if let sessionProfile {
                    writtenSessionProfiles.append(sessionProfile)
                }
            }
        )
        defer { tearDownFixture(fixture) }
        try seedProperty(fixture, orgID: orgID, propertyID: propertyID)
        _ = try fixture.localStore.upsertSession(
            Session(id: UUID(), propertyID: propertyID, captureProfile: .residential)
        )
        _ = try fixture.localStore.upsertSession(
            Session(id: UUID(), propertyID: propertyID, captureProfile: .commercial)
        )

        await prepareAppState(fixture.appState, orgID: orgID)
        let result = await fixture.appState.runCaptureProfileMaintenanceBackfill()

        XCTAssertNil(writtenPropertyProfile)
        XCTAssertEqual(writtenSessionProfiles.sorted { $0.rawValue < $1.rawValue }, [.commercial, .residential])
        XCTAssertEqual(result.propertyProfilesFilled, 0)
        XCTAssertEqual(result.sessionProfilesFilled, 2)
        XCTAssertEqual(result.propertiesScanned, 1)
        XCTAssertEqual(result.sessionsScanned, 2)
        XCTAssertEqual(result.failed, 0)
    }

    func testBackfillDoesNotOverwriteNonNullRemoteProfiles() async throws {
        var didWriteRemote = false
        let fixture = try makeFixture(
            captureProfileBackfillFetchOverride: { _, _, _ in
                AppState.CaptureProfileBackfillRemoteState(
                    propertyRowExists: true,
                    propertyCaptureProfile: .residential,
                    sessionRowExists: true,
                    sessionCaptureProfile: .residential
                )
            },
            captureProfileBackfillWriteOverride: { _, _, _, _, _ in
                didWriteRemote = true
            }
        )
        defer { tearDownFixture(fixture) }
        let orgID = UUID()
        let propertyID = UUID()
        let sessionID = UUID()
        try seedProperty(fixture, orgID: orgID, propertyID: propertyID)
        let session = try fixture.localStore.upsertSession(
            Session(id: sessionID, propertyID: propertyID, captureProfile: .residential)
        )

        await prepareAppState(fixture.appState, orgID: orgID, role: "viewer")
        await MainActor.run {
            fixture.appState.selectProperty(id: propertyID)
            fixture.appState.currentSession = session
        }
        let didBackfill = await fixture.appState.backfillCaptureProfilesIfMissing(
            propertyID: propertyID,
            sessionID: sessionID,
            propertyProfile: .commercial,
            sessionProfile: .commercial
        )

        XCTAssertFalse(didBackfill)
        XCTAssertFalse(didWriteRemote)
    }

    func testConflictingSessionProfilesDoNotForcePropertyDefault() async throws {
        var writtenPropertyProfile: CaptureProfile?
        var writtenSessionProfile: CaptureProfile?
        let fixture = try makeFixture(
            captureProfileBackfillFetchOverride: { _, _, _ in
                AppState.CaptureProfileBackfillRemoteState(
                    propertyRowExists: true,
                    propertyCaptureProfile: nil,
                    sessionRowExists: true,
                    sessionCaptureProfile: nil
                )
            },
            captureProfileBackfillWriteOverride: { _, _, _, propertyProfile, sessionProfile in
                writtenPropertyProfile = propertyProfile
                writtenSessionProfile = sessionProfile
            }
        )
        defer { tearDownFixture(fixture) }
        let orgID = UUID()
        let propertyID = UUID()
        let sessionID = UUID()
        try seedProperty(fixture, orgID: orgID, propertyID: propertyID)
        let session = try fixture.localStore.upsertSession(
            Session(id: sessionID, propertyID: propertyID, captureProfile: .residential)
        )
        var metadata = try fixture.localStore.loadSessionMetadata(propertyID: propertyID, sessionID: sessionID)
        metadata.captureProfile = CaptureProfile.residential.rawValue
        try fixture.localStore.saveSessionMetadataAtomically(propertyID: propertyID, sessionID: sessionID, metadata: metadata)

        await prepareAppState(fixture.appState, orgID: orgID)
        await MainActor.run {
            fixture.appState.selectProperty(id: propertyID)
            fixture.appState.currentSession = session
        }
        let didBackfill = await fixture.appState.backfillCaptureProfilesIfMissing(
            propertyID: propertyID,
            sessionID: sessionID,
            propertyProfile: nil,
            sessionProfile: .commercial
        )

        XCTAssertTrue(didBackfill)
        XCTAssertNil(writtenPropertyProfile)
        XCTAssertEqual(writtenSessionProfile, .commercial)
    }

    func testBackfillSkipsWhenLocalCaptureProfileValueIsUnknown() async throws {
        var didFetchRemote = false
        var didWriteRemote = false
        let fixture = try makeFixture(
            captureProfileBackfillFetchOverride: { _, _, _ in
                didFetchRemote = true
                return AppState.CaptureProfileBackfillRemoteState(
                    propertyRowExists: true,
                    propertyCaptureProfile: nil,
                    sessionRowExists: true,
                    sessionCaptureProfile: nil
                )
            },
            captureProfileBackfillWriteOverride: { _, _, _, _, _ in
                didWriteRemote = true
            }
        )
        defer { tearDownFixture(fixture) }
        let orgID = UUID()
        let propertyID = UUID()
        try seedProperty(fixture, orgID: orgID, propertyID: propertyID)

        await prepareAppState(fixture.appState, orgID: orgID)
        await MainActor.run {
            fixture.appState.selectProperty(id: propertyID)
        }
        let didBackfill = await fixture.appState.backfillCaptureProfilesIfMissing(
            propertyID: propertyID,
            sessionID: nil,
            propertyProfile: nil,
            sessionProfile: nil
        )

        XCTAssertFalse(didBackfill)
        XCTAssertFalse(didFetchRemote)
        XCTAssertFalse(didWriteRemote)
    }

    func testPropertyCaptureProfileUpdateKeepsSelectedPropertyVisibleWhenLocalOrgIsStale() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }
        let activeOrgID = UUID()
        let staleOrgID = UUID()
        let propertyID = UUID()
        _ = try fixture.localStore.createOrganization(Organization(id: activeOrgID, name: "Active Org"))
        _ = try fixture.localStore.createOrganization(Organization(id: staleOrgID, name: "Stale Org"))
        _ = try fixture.localStore.createProperty(
            Property(
                id: propertyID,
                orgId: staleOrgID,
                folderId: "00002",
                name: "Stale Org Property",
                address: "456 Main Street",
                street: "456 Main Street",
                city: "Atlanta",
                state: "GA",
                zip: "30301"
            )
        )

        await prepareAppState(fixture.appState, orgID: activeOrgID)
        let updated = await MainActor.run {
            fixture.appState.selectProperty(id: propertyID)
            return fixture.appState.setPropertyCaptureProfileDefault(
                propertyID: propertyID,
                profile: .commercial
            )
        }

        let stored = try XCTUnwrap(fixture.localStore.fetchProperties().first(where: { $0.id == propertyID }))
        let visible = await MainActor.run {
            fixture.appState.properties.contains(where: { $0.id == propertyID })
        }
        XCTAssertTrue(updated)
        XCTAssertTrue(visible)
        XCTAssertEqual(stored.orgId, activeOrgID)
        XCTAssertEqual(stored.captureProfile, .commercial)
    }

    func testPropertyCaptureProfileUpdateNormalizesSelectedStaleOrgEvenWhenProfileAlreadyMatches() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }
        let activeOrgID = UUID()
        let staleOrgID = UUID()
        let propertyID = UUID()
        _ = try fixture.localStore.createOrganization(Organization(id: staleOrgID, name: "Stale Org"))
        _ = try fixture.localStore.createProperty(
            Property(
                id: propertyID,
                orgId: staleOrgID,
                folderId: "00004",
                captureProfile: .commercial,
                name: "Matching Profile Property",
                address: "246 Main Street",
                street: "246 Main Street",
                city: "Atlanta",
                state: "GA",
                zip: "30301"
            )
        )

        await prepareAppState(fixture.appState, orgID: activeOrgID)
        let updated = await MainActor.run {
            fixture.appState.selectProperty(id: propertyID)
            return fixture.appState.setPropertyCaptureProfileDefault(
                propertyID: propertyID,
                profile: .commercial
            )
        }

        let stored = try XCTUnwrap(fixture.localStore.fetchProperties().first(where: { $0.id == propertyID }))
        let visible = await MainActor.run {
            fixture.appState.properties.contains(where: { $0.id == propertyID })
        }
        XCTAssertTrue(updated)
        XCTAssertTrue(visible)
        XCTAssertEqual(stored.orgId, activeOrgID)
        XCTAssertEqual(stored.captureProfile, .commercial)
    }

    func testPropertyCaptureProfileUpdateStillBlocksWrongOrgPropertyOutsideActiveContext() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }
        let activeOrgID = UUID()
        let foreignOrgID = UUID()
        let propertyID = UUID()
        _ = try fixture.localStore.createOrganization(Organization(id: activeOrgID, name: "Active Org"))
        _ = try fixture.localStore.createOrganization(Organization(id: foreignOrgID, name: "Foreign Org"))
        _ = try fixture.localStore.createProperty(
            Property(
                id: propertyID,
                orgId: foreignOrgID,
                folderId: "00003",
                name: "Foreign Property",
                address: "789 Main Street",
                street: "789 Main Street",
                city: "Atlanta",
                state: "GA",
                zip: "30301"
            )
        )

        await prepareAppState(fixture.appState, orgID: activeOrgID)
        let updated = await MainActor.run {
            fixture.appState.setPropertyCaptureProfileDefault(
                propertyID: propertyID,
                profile: .commercial
            )
        }

        let stored = try XCTUnwrap(fixture.localStore.fetchProperties().first(where: { $0.id == propertyID }))
        XCTAssertFalse(updated)
        XCTAssertEqual(stored.orgId, foreignOrgID)
        XCTAssertNil(stored.captureProfile)
    }

    func testRemoteNilSessionCaptureProfileDoesNotWipeLocalSnapshot() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }
        let orgID = UUID()
        let propertyID = UUID()
        let sessionID = UUID()
        try seedProperty(fixture, orgID: orgID, propertyID: propertyID)
        _ = try fixture.localStore.upsertSession(
            Session(
                id: sessionID,
                propertyID: propertyID,
                startedAt: Date(timeIntervalSinceReferenceDate: 900),
                status: .draft,
                captureProfile: .commercial
            )
        )
        await prepareAppState(fixture.appState, orgID: orgID)

        _ = await MainActor.run {
            fixture.appState._debugApplySyncDeltaSessionsForTests(
                records: [
                    makeSessionDelta(
                        id: sessionID,
                        orgID: orgID,
                        propertyID: propertyID,
                        status: "draft",
                        startedAt: Date(timeIntervalSinceReferenceDate: 900),
                        updatedAt: Date(timeIntervalSinceReferenceDate: 1_000),
                        deletedAt: nil
                    )
                ],
                orgID: orgID
            )
        }

        let session = try XCTUnwrap(
            fixture.localStore.fetchSessionsForCacheBuild(propertyID: propertyID)
                .first(where: { $0.id == sessionID })
        )
        XCTAssertEqual(session.captureProfile, .commercial)
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

    func testDeletedSessionDeltaPreservesExistingCaptureProfile() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }
        let orgID = UUID()
        let propertyID = UUID()
        let sessionID = UUID()
        let deletedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        try seedProperty(fixture, orgID: orgID, propertyID: propertyID)
        _ = try fixture.localStore.upsertSession(
            Session(
                id: sessionID,
                propertyID: propertyID,
                startedAt: Date(timeIntervalSinceReferenceDate: 900),
                status: .completed,
                captureProfile: .commercial
            )
        )
        await prepareAppState(fixture.appState, orgID: orgID)

        _ = await MainActor.run {
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

        let rawSession = try fixture.localStore.fetchSessionsForCacheBuild(propertyID: propertyID)
            .first(where: { $0.id == sessionID })
        let recentlyDeleted = await MainActor.run {
            fixture.appState.recentlyDeletedSessions().first(where: { $0.id == sessionID })
        }

        XCTAssertEqual(rawSession?.deletedAt, deletedAt)
        XCTAssertEqual(rawSession?.captureProfile, .commercial)
        XCTAssertEqual(recentlyDeleted?.captureProfile, .commercial)
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
