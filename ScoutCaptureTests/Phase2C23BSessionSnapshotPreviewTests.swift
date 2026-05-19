import XCTest
@testable import ScoutCapture

final class Phase2C23BSessionSnapshotPreviewTests: XCTestCase {
    private func makeTempStorageRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScoutCapture-2C23B-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeFixture() throws -> (store: LocalStore, appState: AppState, root: URL, property: Property, session: Session) {
        let root = try makeTempStorageRoot()
        let store = LocalStore(testStorageRootURL: root)
        let property = try store.createProperty(Property(id: UUID(), orgId: UUID(), name: "Snapshot Property"))
        let session = try store.upsertSession(
            Session(
                id: UUID(),
                propertyID: property.id,
                startedAt: Date(timeIntervalSinceReferenceDate: 100),
                status: .completed,
                endedAt: Date(timeIntervalSinceReferenceDate: 200),
                exportedAt: Date(timeIntervalSinceReferenceDate: 250),
                isSealed: true,
                firstDeliveredAt: Date(timeIntervalSinceReferenceDate: 300),
                reExportExpiresAt: Date(timeIntervalSinceReferenceDate: 400)
            )
        )
        let defaults = UserDefaults(suiteName: "ScoutCapture-2C23B-\(UUID().uuidString)") ?? .standard
        let appState = AppState(localStore: store, userDefaults: defaults, disableCloudBackupForTests: true)
        return (store, appState, root, property, session)
    }

    private func makeShot(
        propertyID: UUID,
        sessionID: UUID,
        filename: String,
        angleIndex: Int = 1,
        storageBucket: String? = nil,
        storagePath: String? = nil,
        checksumSHA256: String? = nil,
        byteSize: Int? = nil
    ) -> ShotMetadata {
        ShotMetadata(
            shotID: UUID(),
            propertyID: propertyID,
            sessionID: sessionID,
            createdAt: Date(timeIntervalSinceReferenceDate: 150),
            updatedAt: Date(timeIntervalSinceReferenceDate: 160),
            building: "Building",
            elevation: "North",
            detailType: "Overview",
            angleIndex: angleIndex,
            trade: "Paint",
            priority: "high",
            shotKey: ShotMetadata.makeShotKey(
                building: "Building",
                elevation: "North",
                detailType: "Overview",
                angleIndex: angleIndex
            ),
            isGuided: false,
            isFlagged: false,
            issueID: nil,
            issueStatus: nil,
            noteText: nil,
            noteCategory: nil,
            originalFilename: filename,
            originalRelativePath: "Originals/\(filename)",
            originalByteSize: 4,
            storageBucket: storageBucket,
            storagePath: storagePath,
            checksumSHA256: checksumSHA256,
            byteSize: byteSize,
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
    }

    private func saveMetadata(
        store: LocalStore,
        property: Property,
        session: Session,
        shots: [ShotMetadata],
        issues: [IssueMetadata] = [],
        guidedShots: [GuidedShot] = []
    ) throws {
        let metadata = SessionMetadata(
            schemaVersion: 12,
            propertyID: property.id,
            sessionID: session.id,
            orgID: property.orgId,
            propertyNameAtCapture: property.name,
            propertyNameAtExport: nil,
            startedAt: session.startedAt,
            endedAt: session.endedAt,
            status: session.status,
            isBaselineSession: false,
            exportedAt: session.exportedAt,
            isSealed: session.isSealed,
            firstDeliveredAt: session.firstDeliveredAt,
            reExportExpiresAt: session.reExportExpiresAt,
            appVersion: "test-app",
            deviceModel: "test-device",
            osVersion: "test-os",
            shots: shots,
            issues: issues,
            guidedShots: guidedShots
        )
        try store.saveSessionMetadataAtomically(propertyID: property.id, sessionID: session.id, metadata: metadata)
    }

    private func writeOriginal(
        store: LocalStore,
        propertyID: UUID,
        sessionID: UUID,
        filename: String,
        bytes: String = "data"
    ) throws {
        let originals = store.originalsFolderURL(propertyID: propertyID, sessionID: sessionID)
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        try Data(bytes.utf8).write(to: originals.appendingPathComponent(filename))
    }

    func testEnvelopeGenerationFromValidSessionMetadata() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let shot = makeShot(
            propertyID: fixture.property.id,
            sessionID: fixture.session.id,
            filename: "shot.heic",
            storageBucket: "scoutcapture-originals",
            storagePath: "sessions/session-id/shots/shot-id/shot.heic",
            checksumSHA256: String(repeating: "a", count: 64),
            byteSize: 4
        )
        let issue = IssueMetadata(issueID: UUID(), currentReason: "Peeling paint")
        let guided = GuidedShot(title: "North overview", building: "Building", targetElevation: "North", detailType: "Overview", angleIndex: 1)
        try writeOriginal(store: fixture.store, propertyID: fixture.property.id, sessionID: fixture.session.id, filename: "shot.heic")
        try saveMetadata(store: fixture.store, property: fixture.property, session: fixture.session, shots: [shot], issues: [issue], guidedShots: [guided])

        let report = fixture.appState.inspectSessionSnapshotPreview(inspectedAt: Date(timeIntervalSinceReferenceDate: 500))

        XCTAssertEqual(report.sessionsInspected, 1)
        XCTAssertEqual(report.previewableSessions, 1)
        let envelope = try XCTUnwrap(report.rows.first?.envelope)
        XCTAssertEqual(envelope.snapshotSchemaVersion, 1)
        XCTAssertEqual(envelope.sessionMetadataSchemaVersion, 12)
        XCTAssertEqual(envelope.trigger, "preview")
        XCTAssertEqual(envelope.orgID, fixture.property.orgId)
        XCTAssertEqual(envelope.propertyID, fixture.property.id)
        XCTAssertEqual(envelope.sessionID, fixture.session.id)
        XCTAssertEqual(envelope.status, .completed)
        XCTAssertTrue(envelope.isSealed)
        XCTAssertEqual(envelope.shotCount, 1)
        XCTAssertEqual(envelope.issueCount, 1)
        XCTAssertEqual(envelope.guidedCount, 1)
        XCTAssertEqual(envelope.mediaManifestCount, 1)
        XCTAssertEqual(envelope.missingLocalOriginalsCount, 0)
        XCTAssertEqual(envelope.supabaseStorageMetadataCount, 1)
        XCTAssertEqual(envelope.rawSessionJSONSHA256.count, 64)
        XCTAssertEqual(envelope.snapshotPayloadSHA256.count, 64)
        XCTAssertFalse(envelope.rawSessionJSON.isEmpty)
    }

    func testChecksumGenerationIsStableForSameSessionAndInspectionDate() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let shot = makeShot(propertyID: fixture.property.id, sessionID: fixture.session.id, filename: "shot.heic")
        try writeOriginal(store: fixture.store, propertyID: fixture.property.id, sessionID: fixture.session.id, filename: "shot.heic")
        try saveMetadata(store: fixture.store, property: fixture.property, session: fixture.session, shots: [shot])
        let inspectedAt = Date(timeIntervalSinceReferenceDate: 600)

        let first = fixture.appState.inspectSessionSnapshotPreview(inspectedAt: inspectedAt)
        let second = fixture.appState.inspectSessionSnapshotPreview(inspectedAt: inspectedAt)

        XCTAssertEqual(first.rows.first?.envelope?.rawSessionJSONSHA256, second.rows.first?.envelope?.rawSessionJSONSHA256)
        XCTAssertEqual(first.rows.first?.envelope?.snapshotPayloadSHA256, second.rows.first?.envelope?.snapshotPayloadSHA256)
    }

    func testMissingOrUnreadableSessionJSONBecomesNonPreviewable() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try Data("{not-json".utf8).write(
            to: fixture.store.sessionJSONURL(propertyID: fixture.property.id, sessionID: fixture.session.id)
        )

        let report = fixture.appState.inspectSessionSnapshotPreview()

        XCTAssertEqual(report.sessionsInspected, 1)
        XCTAssertEqual(report.previewableSessions, 0)
        XCTAssertEqual(report.missingOrUnreadableSessionJSONCount, 1)
        XCTAssertEqual(report.rows.first?.failureReason, "session_json_missing_or_unreadable")
    }

    func testManifestCountsMissingLocalOriginalAndExcludesMediaBytes() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let present = makeShot(propertyID: fixture.property.id, sessionID: fixture.session.id, filename: "present.heic")
        let missing = makeShot(propertyID: fixture.property.id, sessionID: fixture.session.id, filename: "missing.heic", angleIndex: 2)
        try writeOriginal(
            store: fixture.store,
            propertyID: fixture.property.id,
            sessionID: fixture.session.id,
            filename: "present.heic",
            bytes: "secret-media-bytes-token"
        )
        try saveMetadata(store: fixture.store, property: fixture.property, session: fixture.session, shots: [present, missing])

        let report = fixture.appState.inspectSessionSnapshotPreview()
        let envelope = try XCTUnwrap(report.rows.first?.envelope)
        let reportText = AppState.sessionSnapshotPreviewReportText(report)

        XCTAssertEqual(envelope.mediaManifestCount, 2)
        XCTAssertEqual(envelope.missingLocalOriginalsCount, 1)
        XCTAssertEqual(report.totalMediaManifestCount, 2)
        XCTAssertEqual(report.totalMissingLocalOriginalsCount, 1)
        XCTAssertFalse(envelope.rawSessionJSON.contains("secret-media-bytes-token"))
        XCTAssertFalse(reportText.contains("secret-media-bytes-token"))
        XCTAssertTrue(reportText.contains("media_manifest=2"))
        XCTAssertTrue(reportText.contains("missing_local_originals=1"))
    }

    func testReportRedactionStripsPathsSignedURLsTokensAndPayloads() throws {
        let propertyID = UUID()
        let sessionID = UUID()
        let unsafeReason = "/Users/brian/secret/session.json https://example.supabase.co/object/sign/file?token=secret&signature=abc data:image/jpeg;base64,AAAA"
        let report = AppState.SessionSnapshotPreviewReport(
            inspectedAt: Date(timeIntervalSinceReferenceDate: 700),
            activeOrganizationID: nil,
            sessionsInspected: 1,
            previewableSessions: 0,
            missingOrUnreadableSessionJSONCount: 1,
            checksumGenerationPassCount: 0,
            checksumGenerationFailCount: 0,
            totalShotCount: 0,
            totalIssueCount: 0,
            totalGuidedCount: 0,
            totalMediaManifestCount: 0,
            totalMissingLocalOriginalsCount: 0,
            totalSupabaseStorageMetadataCount: 0,
            rows: [
                AppState.SessionSnapshotPreviewRow(
                    id: sessionID,
                    propertyID: propertyID,
                    localPropertyName: "Unsafe /Users/brian/secret token=secret",
                    sessionID: sessionID,
                    status: .draft,
                    isPreviewable: false,
                    failureReason: unsafeReason,
                    envelope: nil
                )
            ]
        )

        let text = AppState.sessionSnapshotPreviewReportText(report)

        XCTAssertTrue(text.contains("local_property_name="))
        XCTAssertFalse(text.contains("/Users/brian/secret"))
        XCTAssertFalse(text.contains("token=secret"))
        XCTAssertFalse(text.contains("signature=abc"))
        XCTAssertFalse(text.contains("data:image/jpeg;base64,AAAA"))
    }

    func testReportIncludesSanitizedLocalPropertyName() throws {
        let propertyID = UUID()
        let sessionID = UUID()
        let report = AppState.SessionSnapshotPreviewReport(
            inspectedAt: Date(timeIntervalSinceReferenceDate: 800),
            activeOrganizationID: nil,
            sessionsInspected: 1,
            previewableSessions: 0,
            missingOrUnreadableSessionJSONCount: 1,
            checksumGenerationPassCount: 0,
            checksumGenerationFailCount: 0,
            totalShotCount: 0,
            totalIssueCount: 0,
            totalGuidedCount: 0,
            totalMediaManifestCount: 0,
            totalMissingLocalOriginalsCount: 0,
            totalSupabaseStorageMetadataCount: 0,
            rows: [
                AppState.SessionSnapshotPreviewRow(
                    id: sessionID,
                    propertyID: propertyID,
                    localPropertyName: "Warehouse A /Users/brian/private token=secret",
                    sessionID: sessionID,
                    status: .draft,
                    isPreviewable: false,
                    failureReason: "session_json_missing_or_unreadable",
                    envelope: nil
                )
            ]
        )

        let text = AppState.sessionSnapshotPreviewReportText(report)

        XCTAssertTrue(text.contains("local_property_name=Warehouse A"))
        XCTAssertFalse(text.contains("/Users/brian/private"))
        XCTAssertFalse(text.contains("token=secret"))
    }

    func testReportStatesLocalOnlyNoUploadNoBehaviorChange() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let shot = makeShot(propertyID: fixture.property.id, sessionID: fixture.session.id, filename: "shot.heic")
        try writeOriginal(store: fixture.store, propertyID: fixture.property.id, sessionID: fixture.session.id, filename: "shot.heic")
        try saveMetadata(store: fixture.store, property: fixture.property, session: fixture.session, shots: [shot])

        let reportText = AppState.sessionSnapshotPreviewReportText(
            fixture.appState.inspectSessionSnapshotPreview()
        )

        XCTAssertTrue(reportText.contains("local-only"))
        XCTAssertTrue(reportText.contains("does not upload snapshots"))
        XCTAssertTrue(reportText.contains("switch canonical reads"))
        XCTAssertTrue(reportText.contains("change export behavior"))
        XCTAssertTrue(reportText.contains("change sync"))
        XCTAssertTrue(reportText.contains("media payloads"))
    }
}
