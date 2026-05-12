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

    private func makeFixture() throws -> Fixture {
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
        let appState = AppState(localStore: localStore, userDefaults: defaults)
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
    private func prepareAppState(_ appState: AppState, orgID: UUID) {
        appState.refreshProperties()
        appState._debugSetOrganizationContextForTests(
            memberships: [
                ActiveOrganizationMembership(
                    id: orgID,
                    name: "Org",
                    role: "owner"
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
