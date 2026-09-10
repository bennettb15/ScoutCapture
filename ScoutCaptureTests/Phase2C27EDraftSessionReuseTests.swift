import XCTest
@testable import ScoutCapture

@MainActor
final class Phase2C27EDraftSessionReuseTests: XCTestCase {
    private struct Fixture {
        let suiteName: String
        let defaults: UserDefaults
        let storageRoot: URL
        let localStore: LocalStore
        let appState: AppState
        let property: Property
    }

    private func makeFixture() throws -> Fixture {
        let suiteName = "Phase2C27EDraftSessionReuseTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(false, forKey: "supabase_enabled")
        defaults.set(false, forKey: "shadow_write_enabled")
        defaults.set(false, forKey: "supabase_read_enabled")
        defaults.set(false, forKey: "supabase_property_read_enabled")
        defaults.set(false, forKey: "media_supabase_upload_enabled")

        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScoutCapture-2C27E-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)

        let localStore = LocalStore(testStorageRootURL: storageRoot)
        let orgID = UUID()
        _ = try localStore.createOrganization(Organization(id: orgID, name: "Draft Reuse Org"))
        let property = try localStore.createProperty(
            Property(
                orgId: orgID,
                folderId: "draft-reuse",
                name: "Draft Reuse",
                address: "100 Draft Way"
            )
        )
        let appState = AppState(localStore: localStore, userDefaults: defaults)
        appState._debugRefreshPropertiesLocallyForTests()

        return Fixture(
            suiteName: suiteName,
            defaults: defaults,
            storageRoot: storageRoot,
            localStore: localStore,
            appState: appState,
            property: property
        )
    }

    private func tearDownFixture(_ fixture: Fixture) {
        fixture.defaults.removePersistentDomain(forName: fixture.suiteName)
        try? FileManager.default.removeItem(at: fixture.storageRoot)
    }

    @discardableResult
    private func addMaterialShot(
        to session: Session,
        in fixture: Fixture,
        isFlagged: Bool = false,
        issueID: UUID? = nil,
        issueStatus: String? = nil,
        createdAt: Date? = nil,
        captureKind: String? = nil,
        storagePath: String? = nil,
        uploadState: String = "pending"
    ) throws -> ShotMetadata {
        try fixture.localStore.ensureSessionFileStorage(propertyID: session.propertyID, sessionID: session.id)
        let shotID = UUID()
        let originalFilename = "\(shotID.uuidString).jpg"
        let originalRelativePath = "Originals/\(originalFilename)"
        let originalURL = fixture.localStore
            .originalsDirectoryURL(propertyID: session.propertyID, sessionID: session.id)
            .appendingPathComponent(originalFilename, isDirectory: false)
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: originalURL)

        let shot = ShotMetadata(
            shotID: shotID,
            propertyID: session.propertyID,
            sessionID: session.id,
            createdAt: createdAt ?? session.startedAt.addingTimeInterval(1),
            updatedAt: (createdAt ?? session.startedAt.addingTimeInterval(1)).addingTimeInterval(1),
            building: "B1",
            elevation: "North",
            detailType: "Overview",
            angleIndex: 1,
            shotKey: "b1|north|overview|1",
            isGuided: !isFlagged,
            isFlagged: isFlagged,
            issueID: isFlagged ? (issueID ?? UUID()) : nil,
            issueStatus: isFlagged ? (issueStatus ?? "active") : nil,
            captureKind: captureKind,
            noteText: isFlagged ? "Loose trim" : nil,
            noteCategory: isFlagged ? "Issue" : nil,
            originalFilename: originalFilename,
            originalRelativePath: originalRelativePath,
            originalByteSize: 4,
            storagePath: storagePath,
            byteSize: 4,
            uploadState: uploadState,
            stampedFilename: nil,
            stampedRelativePath: nil,
            captureMode: nil,
            lens: nil,
            exifOrientation: nil,
            latitude: nil,
            longitude: nil,
            accuracyMeters: nil,
            imageWidth: 1,
            imageHeight: 1
        )
        try fixture.localStore.upsertShot(
            propertyID: session.propertyID,
            sessionID: session.id,
            shot: shot,
            matchMode: .append
        )
        return shot
    }

    private func makeCompletedUploadStatusRecord(
        for session: Session,
        in fixture: Fixture,
        generatedAt: Date = Date(timeIntervalSinceReferenceDate: 500)
    ) throws -> LocalStore.SessionSnapshotUploadStatusRecord {
        let orgID = try XCTUnwrap(fixture.property.orgId)
        let snapshotID = UUID()
        return LocalStore.SessionSnapshotUploadStatusRecord(
            snapshotID: snapshotID,
            organizationID: orgID,
            propertyID: fixture.property.id,
            sessionID: session.id,
            snapshotKind: AppState.SessionSnapshotKind.completed.rawValue,
            trigger: "auto_completed_sealed_archive:completeCurrentSessionWithoutZIP",
            triggerSource: "completeCurrentSessionWithoutZIP",
            idempotencyKey: "\(fixture.property.id.uuidString)|\(session.id.uuidString)|completeCurrentSessionWithoutZIP|\(snapshotID.uuidString)",
            storagePath: "org/\(orgID.uuidString)/property/\(fixture.property.id.uuidString)/session/\(session.id.uuidString)/\(snapshotID.uuidString).json",
            generatedAt: generatedAt,
            status: .uploaded,
            updatedAt: generatedAt.addingTimeInterval(5)
        )
    }

    func testPropertyReopenReusesPersistedDraft() throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        fixture.appState.selectProperty(id: fixture.property.id)
        _ = try XCTUnwrap(fixture.appState.startSession(skipPropertyStatusPreflight: true))
        let first = try XCTUnwrap(fixture.appState.persistCurrentSessionType(.fullDocumentation))
        try addMaterialShot(to: first, in: fixture)
        fixture.appState.clearCurrentSession()

        fixture.appState.selectProperty(id: fixture.property.id)
        let reopened = try XCTUnwrap(fixture.appState.startSession(skipPropertyStatusPreflight: true))

        XCTAssertEqual(reopened.id, first.id)
        XCTAssertEqual(try fixture.localStore.fetchSessions(propertyID: fixture.property.id).count, 1)
        let diagnostics = fixture.appState._debugLocalDiagnosticsForTests().sessionSnapshotUpload
        XCTAssertEqual(diagnostics.lastDraftReuseDecision, "reuse_persisted_draft")
        XCTAssertFalse(diagnostics.lastDraftDuplicateDetected)
    }

    func testForegroundRefreshReusesDraftAfterCacheRebuild() throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        fixture.appState.selectProperty(id: fixture.property.id)
        _ = try XCTUnwrap(fixture.appState.startSession(skipPropertyStatusPreflight: true))
        let first = try XCTUnwrap(fixture.appState.persistCurrentSessionType(.fullDocumentation))
        try addMaterialShot(to: first, in: fixture)
        fixture.appState.clearCurrentSession()
        fixture.appState._debugRefreshPropertiesLocallyForTests()

        fixture.appState.selectProperty(id: fixture.property.id)
        let reopened = try XCTUnwrap(fixture.appState.startSession(skipPropertyStatusPreflight: true))

        XCTAssertEqual(reopened.id, first.id)
        XCTAssertEqual(
            fixture.appState._debugLocalDiagnosticsForTests()
                .sessionSnapshotUpload
                .lastDraftForegroundRefreshReconciliation,
            "persisted_draft_reattached"
        )
    }

    func testDuplicateDraftCreationLoopIsPrevented() throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        fixture.appState.selectProperty(id: fixture.property.id)
        _ = try XCTUnwrap(fixture.appState.startSession(skipPropertyStatusPreflight: true))
        let first = try XCTUnwrap(fixture.appState.persistCurrentSessionType(.fullDocumentation))
        try addMaterialShot(to: first, in: fixture)
        let second = try XCTUnwrap(fixture.appState.startSession(skipPropertyStatusPreflight: true))
        fixture.appState.clearCurrentSession()
        let third = try XCTUnwrap(fixture.appState.startSession(skipPropertyStatusPreflight: true))

        XCTAssertEqual(second.id, first.id)
        XCTAssertEqual(third.id, first.id)
        XCTAssertEqual(try fixture.localStore.fetchSessions(propertyID: fixture.property.id).count, 1)
        XCTAssertEqual(
            fixture.appState._debugLocalDiagnosticsForTests()
                .sessionSnapshotUpload
                .lastDraftReuseDecision,
            "reuse_persisted_draft"
        )
    }

    func testCompletedAndSealedSessionsDoNotReuseIncorrectly() throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        let completed = Session(
            propertyID: fixture.property.id,
            startedAt: Date().addingTimeInterval(-300),
            status: .completed,
            endedAt: Date().addingTimeInterval(-120),
            isSealed: true
        )
        let sealedDraft = Session(
            propertyID: fixture.property.id,
            startedAt: Date().addingTimeInterval(-60),
            status: .draft,
            isSealed: true
        )
        _ = try fixture.localStore.upsertSession(completed)
        _ = try fixture.localStore.upsertSession(sealedDraft)
        fixture.appState._debugRefreshPropertiesLocallyForTests()

        fixture.appState.selectProperty(id: fixture.property.id)
        _ = try XCTUnwrap(fixture.appState.startSession(skipPropertyStatusPreflight: true))
        let newDraft = try XCTUnwrap(fixture.appState.persistCurrentSessionType(.fullDocumentation))

        XCTAssertNotEqual(newDraft.id, completed.id)
        XCTAssertNotEqual(newDraft.id, sealedDraft.id)
        XCTAssertEqual(newDraft.status, .draft)
        XCTAssertFalse(newDraft.isSealed)
        XCTAssertEqual(
            fixture.appState._debugLocalDiagnosticsForTests()
                .sessionSnapshotUpload
                .lastDraftReuseBlockedReason,
            "no_reusable_active_draft_completed_or_sealed_sessions_only"
        )
    }

    func testMissingOrStaleDraftCreatesNewSessionAppropriately() throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        let stale = Session(
            propertyID: fixture.property.id,
            startedAt: Date().addingTimeInterval(-60),
            status: .draft,
            deletedAt: Date()
        )
        _ = try fixture.localStore.upsertSession(stale)
        fixture.appState._debugRefreshPropertiesLocallyForTests()

        fixture.appState.selectProperty(id: fixture.property.id)
        _ = try XCTUnwrap(fixture.appState.startSession(skipPropertyStatusPreflight: true))
        let newDraft = try XCTUnwrap(fixture.appState.persistCurrentSessionType(.fullDocumentation))

        XCTAssertNotEqual(newDraft.id, stale.id)
        XCTAssertEqual(newDraft.status, .draft)
        XCTAssertEqual(
            try fixture.localStore.fetchSessions(propertyID: fixture.property.id)
                .filter { $0.deletedAt == nil && $0.status == .draft }
                .map(\.id),
            [newDraft.id]
        )
    }

    func testExistingDuplicateDraftsAreDetectedButPreserved() throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        let older = Session(
            propertyID: fixture.property.id,
            startedAt: Date().addingTimeInterval(-120),
            status: .draft
        )
        let newer = Session(
            propertyID: fixture.property.id,
            startedAt: Date().addingTimeInterval(-60),
            status: .draft
        )
        _ = try fixture.localStore.upsertSession(older)
        _ = try fixture.localStore.upsertSession(newer)
        try fixture.localStore.ensureSessionMetadata(for: older)
        try fixture.localStore.ensureSessionMetadata(for: newer)
        try addMaterialShot(to: older, in: fixture)
        try addMaterialShot(to: newer, in: fixture)
        fixture.appState._debugRefreshPropertiesLocallyForTests()

        fixture.appState.selectProperty(id: fixture.property.id)
        let reused = try XCTUnwrap(fixture.appState.startSession(skipPropertyStatusPreflight: true))

        XCTAssertEqual(reused.id, newer.id)
        XCTAssertEqual(try fixture.localStore.fetchSessions(propertyID: fixture.property.id).count, 2)
        let diagnostics = fixture.appState._debugLocalDiagnosticsForTests().sessionSnapshotUpload
        XCTAssertEqual(diagnostics.lastDraftReuseCandidateCount, 2)
        XCTAssertTrue(diagnostics.lastDraftDuplicateDetected)
        XCTAssertEqual(diagnostics.lastDraftReuseDecision, "reuse_persisted_draft")
    }

    func testInitialSessionTypeSelectionPersistsPunchlistVisit() throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        fixture.appState.selectProperty(id: fixture.property.id)
        let shell = try XCTUnwrap(fixture.appState.startSession(skipPropertyStatusPreflight: true))

        XCTAssertTrue(fixture.appState.currentSessionRequiresInitialSessionTypeSelection(propertyID: fixture.property.id))
        XCTAssertEqual(shell.sessionType, .fullDocumentation)

        let persisted = try XCTUnwrap(fixture.appState.persistCurrentSessionType(.punchlistVisit))
        let metadata = try fixture.localStore.loadSessionMetadata(propertyID: fixture.property.id, sessionID: persisted.id)

        XCTAssertEqual(persisted.sessionType, .punchlistVisit)
        XCTAssertEqual(metadata.sessionType, .punchlistVisit)
        XCTAssertFalse(fixture.appState.currentSessionRequiresInitialSessionTypeSelection(propertyID: fixture.property.id))
        XCTAssertEqual(try fixture.localStore.fetchSessions(propertyID: fixture.property.id).map(\.id), [persisted.id])
    }

    func testInitialSessionTypeSelectionPersistsFullDocumentation() throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        fixture.appState.selectProperty(id: fixture.property.id)
        _ = try XCTUnwrap(fixture.appState.startSession(skipPropertyStatusPreflight: true))
        let persisted = try XCTUnwrap(fixture.appState.persistCurrentSessionType(.fullDocumentation))
        let metadata = try fixture.localStore.loadSessionMetadata(propertyID: fixture.property.id, sessionID: persisted.id)

        XCTAssertEqual(persisted.sessionType, .fullDocumentation)
        XCTAssertEqual(metadata.sessionType, .fullDocumentation)
    }

    func testNoPhotoFullDocumentationExitPromptsAgainOnReentry() throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        fixture.appState.selectProperty(id: fixture.property.id)
        _ = try XCTUnwrap(fixture.appState.startSession(skipPropertyStatusPreflight: true))
        let emptyDraft = try XCTUnwrap(fixture.appState.persistCurrentSessionType(.fullDocumentation))
        fixture.appState.markCurrentSessionCameraEntryBegan()
        XCTAssertEqual(fixture.appState.materialDraftCaptureCount(for: emptyDraft), 0)
        XCTAssertTrue(fixture.appState.currentSessionRequiresInitialSessionTypeSelection(propertyID: fixture.property.id))
        fixture.appState.clearCurrentSession()

        fixture.appState.selectProperty(id: fixture.property.id)
        let reopened = try XCTUnwrap(fixture.appState.startSession(skipPropertyStatusPreflight: true))

        XCTAssertNotEqual(reopened.id, emptyDraft.id)
        XCTAssertEqual(reopened.sessionType, .fullDocumentation)
        XCTAssertTrue(fixture.appState.currentSessionRequiresInitialSessionTypeSelection(propertyID: fixture.property.id))
        XCTAssertEqual(try fixture.localStore.fetchSessions(propertyID: fixture.property.id).map(\.id), [emptyDraft.id])
    }

    func testNoPhotoPunchlistVisitExitPromptsAgainOnReentry() throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        fixture.appState.selectProperty(id: fixture.property.id)
        _ = try XCTUnwrap(fixture.appState.startSession(skipPropertyStatusPreflight: true))
        let emptyDraft = try XCTUnwrap(fixture.appState.persistCurrentSessionType(.punchlistVisit))
        fixture.appState.markCurrentSessionCameraEntryBegan()
        XCTAssertEqual(fixture.appState.materialDraftCaptureCount(for: emptyDraft), 0)
        XCTAssertTrue(fixture.appState.currentSessionRequiresInitialSessionTypeSelection(propertyID: fixture.property.id))
        fixture.appState.clearCurrentSession()

        fixture.appState.selectProperty(id: fixture.property.id)
        let reopened = try XCTUnwrap(fixture.appState.startSession(skipPropertyStatusPreflight: true))

        XCTAssertNotEqual(reopened.id, emptyDraft.id)
        XCTAssertEqual(reopened.sessionType, .fullDocumentation)
        XCTAssertTrue(fixture.appState.currentSessionRequiresInitialSessionTypeSelection(propertyID: fixture.property.id))
        XCTAssertEqual(try fixture.localStore.fetchSessions(propertyID: fixture.property.id).map(\.id), [emptyDraft.id])
    }

    func testNoPhotoFullDocumentationCurrentSessionDoesNotRemainResumableAfterCameraEntry() throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        fixture.appState.selectProperty(id: fixture.property.id)
        _ = try XCTUnwrap(fixture.appState.startSession(skipPropertyStatusPreflight: true))
        let emptyDraft = try XCTUnwrap(fixture.appState.persistCurrentSessionType(.fullDocumentation))

        XCTAssertFalse(fixture.appState.currentSessionRequiresInitialSessionTypeSelection(propertyID: fixture.property.id))

        fixture.appState.markCurrentSessionCameraEntryBegan()

        XCTAssertEqual(fixture.appState.materialDraftCaptureCount(for: emptyDraft), 0)
        XCTAssertTrue(fixture.appState.currentSessionRequiresInitialSessionTypeSelection(propertyID: fixture.property.id))

        fixture.appState.selectProperty(id: fixture.property.id)
        let reopened = try XCTUnwrap(fixture.appState.startSession(skipPropertyStatusPreflight: true))

        XCTAssertNotEqual(reopened.id, emptyDraft.id)
        XCTAssertTrue(fixture.appState.currentSessionRequiresInitialSessionTypeSelection(propertyID: fixture.property.id))
    }

    func testNoPhotoPunchlistVisitCurrentSessionDoesNotRemainResumableAfterCameraEntry() throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        fixture.appState.selectProperty(id: fixture.property.id)
        _ = try XCTUnwrap(fixture.appState.startSession(skipPropertyStatusPreflight: true))
        let emptyDraft = try XCTUnwrap(fixture.appState.persistCurrentSessionType(.punchlistVisit))

        XCTAssertFalse(fixture.appState.currentSessionRequiresInitialSessionTypeSelection(propertyID: fixture.property.id))

        fixture.appState.markCurrentSessionCameraEntryBegan()

        XCTAssertEqual(fixture.appState.materialDraftCaptureCount(for: emptyDraft), 0)
        XCTAssertTrue(fixture.appState.currentSessionRequiresInitialSessionTypeSelection(propertyID: fixture.property.id))

        fixture.appState.selectProperty(id: fixture.property.id)
        let reopened = try XCTUnwrap(fixture.appState.startSession(skipPropertyStatusPreflight: true))

        XCTAssertNotEqual(reopened.id, emptyDraft.id)
        XCTAssertTrue(fixture.appState.currentSessionRequiresInitialSessionTypeSelection(propertyID: fixture.property.id))
    }

    func testPersistedEmptyTypedCurrentDraftPromptsAgainWithoutFreshChoice() throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        let staleTypedDraft = Session(
            propertyID: fixture.property.id,
            sessionType: .punchlistVisit,
            startedAt: Date(timeIntervalSinceReferenceDate: 100),
            status: .draft
        )
        let persisted = try fixture.localStore.upsertSession(staleTypedDraft)
        try fixture.localStore.ensureSessionMetadata(for: persisted)
        fixture.appState._debugRefreshPropertiesLocallyForTests()
        fixture.appState.selectProperty(id: fixture.property.id)
        fixture.appState.currentSession = persisted

        XCTAssertTrue(fixture.appState.currentSessionRequiresInitialSessionTypeSelection(propertyID: fixture.property.id))
    }

    func testPersistedTypedDraftWithPhotosResumesWithoutInitialTypePrompt() throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        fixture.appState.selectProperty(id: fixture.property.id)
        _ = try XCTUnwrap(fixture.appState.startSession(skipPropertyStatusPreflight: true))
        let first = try XCTUnwrap(fixture.appState.persistCurrentSessionType(.punchlistVisit))
        try addMaterialShot(to: first, in: fixture, isFlagged: true)
        fixture.appState.clearCurrentSession()

        fixture.appState.selectProperty(id: fixture.property.id)
        let reopened = try XCTUnwrap(fixture.appState.startSession(skipPropertyStatusPreflight: true))

        XCTAssertEqual(reopened.id, first.id)
        XCTAssertEqual(reopened.sessionType, .punchlistVisit)
        XCTAssertFalse(fixture.appState.currentSessionRequiresInitialSessionTypeSelection(propertyID: fixture.property.id))
    }

    func testFullDocumentationUploadedRealCaptureRemainsMaterialDraftAndResumes() throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        fixture.appState.selectProperty(id: fixture.property.id)
        _ = try XCTUnwrap(fixture.appState.startSession(skipPropertyStatusPreflight: true))
        let draft = try XCTUnwrap(fixture.appState.persistCurrentSessionType(.fullDocumentation))
        fixture.appState.markCurrentSessionCameraEntryBegan()
        try addMaterialShot(
            to: draft,
            in: fixture,
            captureKind: "captured",
            storagePath: "org/example/property/example/session/\(draft.id.uuidString)/originals/captured.jpg",
            uploadState: "uploaded"
        )

        XCTAssertEqual(fixture.appState.materialDraftCaptureCount(for: draft), 1)
        XCTAssertFalse(fixture.appState.currentSessionRequiresInitialSessionTypeSelection(propertyID: fixture.property.id))

        fixture.appState.clearCurrentSession()
        fixture.appState.selectProperty(id: fixture.property.id)
        let reopened = try XCTUnwrap(fixture.appState.startSession(skipPropertyStatusPreflight: true))

        XCTAssertEqual(reopened.id, draft.id)
        XCTAssertEqual(reopened.sessionType, .fullDocumentation)
        XCTAssertFalse(fixture.appState.currentSessionRequiresInitialSessionTypeSelection(propertyID: fixture.property.id))
    }

    func testPunchlistUploadedRealCaptureRemainsMaterialDraftAndResumes() throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        fixture.appState.selectProperty(id: fixture.property.id)
        _ = try XCTUnwrap(fixture.appState.startSession(skipPropertyStatusPreflight: true))
        let draft = try XCTUnwrap(fixture.appState.persistCurrentSessionType(.punchlistVisit))
        fixture.appState.markCurrentSessionCameraEntryBegan()
        try addMaterialShot(
            to: draft,
            in: fixture,
            isFlagged: true,
            captureKind: "captured",
            storagePath: "org/example/property/example/session/\(draft.id.uuidString)/originals/captured.jpg",
            uploadState: "uploaded"
        )

        XCTAssertEqual(fixture.appState.materialDraftCaptureCount(for: draft), 1)
        XCTAssertFalse(fixture.appState.currentSessionRequiresInitialSessionTypeSelection(propertyID: fixture.property.id))

        fixture.appState.clearCurrentSession()
        fixture.appState.selectProperty(id: fixture.property.id)
        let reopened = try XCTUnwrap(fixture.appState.startSession(skipPropertyStatusPreflight: true))

        XCTAssertEqual(reopened.id, draft.id)
        XCTAssertEqual(reopened.sessionType, .punchlistVisit)
        XCTAssertFalse(fixture.appState.currentSessionRequiresInitialSessionTypeSelection(propertyID: fixture.property.id))
    }

    func testPunchlistPendingActiveIssueCaptureCountsAsMaterialDraftAndResumes() throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        fixture.appState.selectProperty(id: fixture.property.id)
        _ = try XCTUnwrap(fixture.appState.startSession(skipPropertyStatusPreflight: true))
        let draft = try XCTUnwrap(fixture.appState.persistCurrentSessionType(.punchlistVisit))
        fixture.appState.markCurrentSessionCameraEntryBegan()
        let issueID = UUID()
        try addMaterialShot(
            to: draft,
            in: fixture,
            isFlagged: true,
            issueID: issueID,
            issueStatus: Observation.Status.active.issueStatusValue,
            captureKind: "follow_up_capture"
        )

        XCTAssertEqual(fixture.appState.materialDraftCaptureCount(for: draft), 1)
        XCTAssertFalse(fixture.appState.currentSessionRequiresInitialSessionTypeSelection(propertyID: fixture.property.id))

        fixture.appState.clearCurrentSession()
        fixture.appState.selectProperty(id: fixture.property.id)
        let reopened = try XCTUnwrap(fixture.appState.startSession(skipPropertyStatusPreflight: true))

        XCTAssertEqual(reopened.id, draft.id)
        XCTAssertEqual(reopened.sessionType, .punchlistVisit)
        XCTAssertEqual(fixture.appState.materialDraftCaptureCount(for: reopened), 1)
        XCTAssertFalse(fixture.appState.currentSessionRequiresInitialSessionTypeSelection(propertyID: fixture.property.id))
    }

    func testPunchlistFinalizedActiveIssueUpdateRepairsReferenceCaptureKind() throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        fixture.appState.selectProperty(id: fixture.property.id)
        _ = try XCTUnwrap(fixture.appState.startSession(skipPropertyStatusPreflight: true))
        let draft = try XCTUnwrap(fixture.appState.persistCurrentSessionType(.punchlistVisit))
        fixture.appState.markCurrentSessionCameraEntryBegan()
        let issueID = UUID()
        let shot = try addMaterialShot(
            to: draft,
            in: fixture,
            isFlagged: true,
            issueID: issueID,
            issueStatus: Observation.Status.active.issueStatusValue,
            captureKind: "reference"
        )
        XCTAssertEqual(fixture.appState.materialDraftCaptureCount(for: draft), 0)

        let observation = try fixture.localStore.createObservation(
            Observation(
                id: issueID,
                propertyID: fixture.property.id,
                createdAt: draft.startedAt.addingTimeInterval(-60),
                updatedAt: draft.startedAt.addingTimeInterval(2),
                statement: "Loose trim",
                status: .active,
                linkedShotID: shot.shotID,
                updatedInSessionID: draft.id,
                building: shot.building,
                targetElevation: shot.elevation,
                detailType: shot.detailType,
                priority: "P2",
                currentReason: "Loose trim",
                note: "Loose trim",
                shots: [
                    Shot(
                        id: shot.shotID,
                        capturedAt: shot.createdAt,
                        imageLocalIdentifier: fixture.localStore
                            .originalsDirectoryURL(propertyID: draft.propertyID, sessionID: draft.id)
                            .appendingPathComponent(shot.originalFilename, isDirectory: false)
                            .path,
                        note: "Loose trim"
                    )
                ]
            )
        )
        let synced = try XCTUnwrap(
            fixture.localStore.syncFlaggedObservationUpdateToSessionMetadata(
                propertyID: fixture.property.id,
                sessionID: draft.id,
                observation: observation,
                shotID: shot.shotID,
                trade: nil,
                activeCaptureKind: "follow_up_capture"
            )
        )

        XCTAssertEqual(synced.captureKind, "follow_up_capture")
        XCTAssertEqual(fixture.appState.materialDraftCaptureCount(for: draft), 1)

        fixture.appState.clearCurrentSession()
        fixture.appState.selectProperty(id: fixture.property.id)
        let reopened = try XCTUnwrap(fixture.appState.startSession(skipPropertyStatusPreflight: true))

        XCTAssertEqual(reopened.id, draft.id)
        XCTAssertEqual(reopened.sessionType, .punchlistVisit)
    }

    func testDraftWithOnlyPreSessionReferencePhotoDoesNotResumeWithoutPrompting() throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        let stale = Session(
            propertyID: fixture.property.id,
            sessionType: .punchlistVisit,
            startedAt: Date(timeIntervalSinceReferenceDate: 1_000),
            status: .draft
        )
        let persisted = try fixture.localStore.upsertSession(stale)
        try fixture.localStore.ensureSessionMetadata(for: persisted)
        try addMaterialShot(
            to: persisted,
            in: fixture,
            createdAt: Date(timeIntervalSinceReferenceDate: 900),
            captureKind: "reference"
        )
        fixture.appState.clearCurrentSession()
        fixture.appState._debugRefreshPropertiesLocallyForTests()

        fixture.appState.selectProperty(id: fixture.property.id)
        let reopened = try XCTUnwrap(fixture.appState.startSession(skipPropertyStatusPreflight: true))

        XCTAssertNotEqual(reopened.id, persisted.id)
        XCTAssertEqual(reopened.sessionType, .fullDocumentation)
        XCTAssertTrue(fixture.appState.currentSessionRequiresInitialSessionTypeSelection(propertyID: fixture.property.id))
    }

    func testUploadedRestoredCurrentSessionPhotoDoesNotCountAsMaterialDraftCapture() throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        let shell = Session(
            propertyID: fixture.property.id,
            sessionType: .fullDocumentation,
            startedAt: Date(timeIntervalSinceReferenceDate: 1_000),
            status: .draft
        )
        let persisted = try fixture.localStore.upsertSession(shell)
        try fixture.localStore.ensureSessionMetadata(for: persisted)
        try addMaterialShot(
            to: persisted,
            in: fixture,
            createdAt: Date(timeIntervalSinceReferenceDate: 1_001),
            captureKind: "restored",
            storagePath: "org/example/property/example/session/example/originals/restored.jpg",
            uploadState: "uploaded"
        )
        fixture.appState._debugRefreshPropertiesLocallyForTests()
        fixture.appState.selectProperty(id: fixture.property.id)
        fixture.appState.currentSession = persisted

        XCTAssertEqual(fixture.appState.materialDraftCaptureCount(for: persisted), 0)
        XCTAssertTrue(fixture.appState.currentSessionRequiresInitialSessionTypeSelection(propertyID: fixture.property.id))
    }

    func testCompletedPunchlistSessionPromptsAgainOnReentry() throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        fixture.appState.selectProperty(id: fixture.property.id)
        _ = try XCTUnwrap(fixture.appState.startSession(skipPropertyStatusPreflight: true))
        let punchlist = try XCTUnwrap(fixture.appState.persistCurrentSessionType(.punchlistVisit))
        try addMaterialShot(to: punchlist, in: fixture, isFlagged: true)
        fixture.appState.completeCurrentSessionWithoutZIP()

        fixture.appState.selectProperty(id: fixture.property.id)
        let reopened = try XCTUnwrap(fixture.appState.startSession(skipPropertyStatusPreflight: true))

        XCTAssertNotEqual(reopened.id, punchlist.id)
        XCTAssertEqual(reopened.status, .draft)
        XCTAssertEqual(reopened.sessionType, .fullDocumentation)
        XCTAssertTrue(fixture.appState.currentSessionRequiresInitialSessionTypeSelection(propertyID: fixture.property.id))
    }

    func testStaleCompletedPunchlistCurrentSessionDoesNotSuppressInitialTypePrompt() throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        fixture.appState.selectProperty(id: fixture.property.id)
        _ = try XCTUnwrap(fixture.appState.startSession(skipPropertyStatusPreflight: true))
        let punchlist = try XCTUnwrap(fixture.appState.persistCurrentSessionType(.punchlistVisit))
        try addMaterialShot(to: punchlist, in: fixture, isFlagged: true)

        var stalePersisted = punchlist
        stalePersisted.status = .completed
        stalePersisted.endedAt = Date(timeIntervalSinceReferenceDate: 200)
        stalePersisted.isSealed = true
        _ = try fixture.localStore.upsertSession(stalePersisted)
        fixture.appState._debugRefreshPropertiesLocallyForTests()

        fixture.appState.selectProperty(id: fixture.property.id)
        let reopened = try XCTUnwrap(fixture.appState.startSession(skipPropertyStatusPreflight: true))

        XCTAssertNotEqual(reopened.id, punchlist.id)
        XCTAssertEqual(reopened.status, .draft)
        XCTAssertTrue(fixture.appState.currentSessionRequiresInitialSessionTypeSelection(propertyID: fixture.property.id))
        XCTAssertEqual(
            fixture.appState._debugLocalDiagnosticsForTests()
                .sessionSnapshotUpload
                .lastDraftReuseBlockedReason,
            "no_reusable_active_draft_completed_or_sealed_sessions_only"
        )
    }

    func testStaleUploadedPunchlistCurrentSessionDoesNotSuppressInitialTypePrompt() throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        fixture.appState.selectProperty(id: fixture.property.id)
        _ = try XCTUnwrap(fixture.appState.startSession(skipPropertyStatusPreflight: true))
        let punchlist = try XCTUnwrap(fixture.appState.persistCurrentSessionType(.punchlistVisit))
        try addMaterialShot(to: punchlist, in: fixture, isFlagged: true)

        var uploaded = punchlist
        uploaded.status = .completed
        uploaded.endedAt = Date(timeIntervalSinceReferenceDate: 200)
        uploaded.isSealed = true
        uploaded.firstDeliveredAt = Date(timeIntervalSinceReferenceDate: 220)
        _ = try fixture.localStore.upsertSession(uploaded)
        fixture.appState._debugRefreshPropertiesLocallyForTests()

        fixture.appState.selectProperty(id: fixture.property.id)
        let reopened = try XCTUnwrap(fixture.appState.startSession(skipPropertyStatusPreflight: true))

        XCTAssertNotEqual(reopened.id, punchlist.id)
        XCTAssertEqual(reopened.status, .draft)
        XCTAssertTrue(fixture.appState.currentSessionRequiresInitialSessionTypeSelection(propertyID: fixture.property.id))
    }

    func testUploadedCompletedSnapshotStatusPreventsStaleDraftResume() throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        fixture.appState.selectProperty(id: fixture.property.id)
        _ = try XCTUnwrap(fixture.appState.startSession(skipPropertyStatusPreflight: true))
        let staleDraft = try XCTUnwrap(fixture.appState.persistCurrentSessionType(.fullDocumentation))
        try addMaterialShot(to: staleDraft, in: fixture)
        _ = try fixture.localStore.upsertSessionSnapshotUploadStatusRecord(
            makeCompletedUploadStatusRecord(for: staleDraft, in: fixture)
        )
        fixture.appState._debugRunForegroundCacheRefreshForTests()

        XCTAssertTrue(
            fixture.appState.currentSessionRequiresInitialSessionTypeSelection(propertyID: fixture.property.id)
        )

        let reopened = try XCTUnwrap(fixture.appState.startSession(skipPropertyStatusPreflight: true))

        XCTAssertNotEqual(reopened.id, staleDraft.id)
        XCTAssertEqual(reopened.status, .draft)
        XCTAssertEqual(reopened.sessionType, .fullDocumentation)
        XCTAssertTrue(fixture.appState.currentSessionRequiresInitialSessionTypeSelection(propertyID: fixture.property.id))
        XCTAssertTrue(
            try fixture.localStore.fetchSessions(propertyID: fixture.property.id)
                .contains(where: { $0.id == staleDraft.id })
        )
    }

    func testPunchlistCompletionIgnoresGuidedRemainingWhileFullDocumentationDoesNot() {
        XCTAssertTrue(
            AppState.sessionCanComplete(
                sessionType: .punchlistVisit,
                hasBaseline: true,
                guidedRemainingCount: 8,
                flaggedRemainingCount: 0,
                currentSessionCaptureCount: 0
            )
        )
        XCTAssertFalse(
            AppState.sessionCompletionHasOutstandingChecklistItems(
                sessionType: .punchlistVisit,
                guidedRemainingCount: 8,
                flaggedRemainingCount: 0
            )
        )
        XCTAssertEqual(
            AppState.sessionCompletionActionTitle(sessionType: .punchlistVisit),
            "Complete Punchlist"
        )
        XCTAssertTrue(
            AppState.sessionCanComplete(
                sessionType: .punchlistVisit,
                hasBaseline: false,
                guidedRemainingCount: 8,
                flaggedRemainingCount: 0,
                currentSessionCaptureCount: 1
            )
        )
        XCTAssertFalse(
            AppState.sessionCanComplete(
                sessionType: .punchlistVisit,
                hasBaseline: false,
                guidedRemainingCount: 0,
                flaggedRemainingCount: 1,
                currentSessionCaptureCount: 1
            )
        )

        XCTAssertFalse(
            AppState.sessionCanComplete(
                sessionType: .fullDocumentation,
                hasBaseline: true,
                guidedRemainingCount: 8,
                flaggedRemainingCount: 0,
                currentSessionCaptureCount: 0
            )
        )
        XCTAssertTrue(
            AppState.sessionCompletionHasOutstandingChecklistItems(
                sessionType: .fullDocumentation,
                guidedRemainingCount: 8,
                flaggedRemainingCount: 0
            )
        )
        XCTAssertEqual(
            AppState.sessionCompletionActionTitle(sessionType: .fullDocumentation),
            "Complete Session"
        )
    }

    func testGuidedChecklistCanOpenForCompletedRowsWhenRemainingIsZero() {
        XCTAssertTrue(ContentView.guidedChecklistShouldOpen(totalCount: 1))
    }

    func testGuidedChecklistEmptyStateOnlyWhenNoRowsExist() {
        XCTAssertFalse(ContentView.guidedChecklistShouldOpen(totalCount: 0))
    }

    func testPunchlistVisitCompletionPreservesGuidedRequirementsForNextFullSession() throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }
        let guidedID = UUID()
        let guided = GuidedShot(
            id: guidedID,
            title: "North Overview",
            building: "B1",
            targetElevation: "North",
            detailType: "Overview",
            angleIndex: 1,
            isCompleted: false
        )
        try fixture.localStore.saveGuidedShots([guided], propertyID: fixture.property.id)

        fixture.appState.selectProperty(id: fixture.property.id)
        _ = try XCTUnwrap(fixture.appState.startSession(skipPropertyStatusPreflight: true))
        let punchlist = try XCTUnwrap(fixture.appState.persistCurrentSessionType(.punchlistVisit))
        fixture.appState.completeCurrentSessionWithoutZIP()

        let afterPunchlist = try fixture.localStore.fetchGuidedShots(propertyID: fixture.property.id)
        XCTAssertEqual(afterPunchlist.count, 1)
        XCTAssertEqual(afterPunchlist.first?.id, guidedID)
        XCTAssertEqual(afterPunchlist.first?.isCompleted, false)
        XCTAssertNil(afterPunchlist.first?.skipReason)
        XCTAssertNil(afterPunchlist.first?.skipSessionID)

        fixture.appState.selectProperty(id: fixture.property.id)
        let nextFull = try XCTUnwrap(fixture.appState.startSession(skipPropertyStatusPreflight: true))

        XCTAssertNotEqual(nextFull.id, punchlist.id)
        XCTAssertEqual(nextFull.sessionType, .fullDocumentation)
        XCTAssertEqual(try fixture.localStore.fetchGuidedShots(propertyID: fixture.property.id).first?.id, guidedID)
    }

    func testCompletedSnapshotPayloadIncludesSessionType() throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        let session = try fixture.localStore.upsertSession(
            Session(
                propertyID: fixture.property.id,
                sessionType: .punchlistVisit,
                startedAt: Date(timeIntervalSinceReferenceDate: 100),
                status: .completed,
                endedAt: Date(timeIntervalSinceReferenceDate: 200),
                isSealed: true
            )
        )
        try fixture.localStore.ensureSessionMetadata(for: session)

        let artifacts = try fixture.appState._debugMakeSessionSnapshotUploadArtifactsForTests(
            propertyID: fixture.property.id,
            sessionID: session.id,
            kind: .completed,
            trigger: "completed_sealed_checkpoint"
        )
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: artifacts.object.payloadData) as? [String: Any])
        let rawSessionJSON = try XCTUnwrap(payload["rawSessionJSON"] as? String)
        let rawSessionData = try XCTUnwrap(rawSessionJSON.data(using: .utf8))
        let rawSession = try XCTUnwrap(JSONSerialization.jsonObject(with: rawSessionData) as? [String: Any])

        XCTAssertEqual(payload["sessionType"] as? String, SessionType.punchlistVisit.rawValue)
        XCTAssertEqual(rawSession["sessionType"] as? String, SessionType.punchlistVisit.rawValue)
    }
}
