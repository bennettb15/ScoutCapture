import XCTest
@testable import ScoutCapture

@MainActor
final class Phase2C23FSessionSnapshotShadowWriteTests: XCTestCase {
    private func makeTempStorageRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScoutCapture-2C23F-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeDefaults(shadowWriteEnabled: Bool = true) -> UserDefaults {
        let defaults = UserDefaults(suiteName: "ScoutCapture-2C23F-\(UUID().uuidString)") ?? .standard
        defaults.set(shadowWriteEnabled, forKey: "session_snapshot_shadow_write_enabled")
        return defaults
    }

    private func makeFixture(
        shadowWriteEnabled: Bool = true,
        storageUploadOverride: AppState.SessionSnapshotStorageUploadOverride? = nil,
        rowInsertOverride: AppState.SessionSnapshotRowInsertOverride? = nil
    ) throws -> (store: LocalStore, appState: AppState, root: URL, property: Property, session: Session) {
        let root = try makeTempStorageRoot()
        let store = LocalStore(testStorageRootURL: root)
        let property = try store.createProperty(Property(id: UUID(), orgId: UUID(), name: "Snapshot Upload Property"))
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
        try saveMetadata(store: store, property: property, session: session)
        let appState = AppState(
            localStore: store,
            userDefaults: makeDefaults(shadowWriteEnabled: shadowWriteEnabled),
            sessionSnapshotStorageUploadOverride: storageUploadOverride ?? { _ in },
            sessionSnapshotRowInsertOverride: rowInsertOverride ?? { _ in },
            disableCloudBackupForTests: true
        )
        return (store, appState, root, property, session)
    }

    private func saveMetadata(store: LocalStore, property: Property, session: Session) throws {
        let shot = ShotMetadata(
            shotID: UUID(),
            propertyID: property.id,
            sessionID: session.id,
            createdAt: Date(timeIntervalSinceReferenceDate: 150),
            updatedAt: Date(timeIntervalSinceReferenceDate: 160),
            building: "Building",
            elevation: "North",
            detailType: "Overview",
            angleIndex: 1,
            trade: "Paint",
            priority: "high",
            shotKey: ShotMetadata.makeShotKey(building: "Building", elevation: "North", detailType: "Overview", angleIndex: 1),
            isGuided: false,
            isFlagged: false,
            issueID: nil,
            issueStatus: nil,
            noteText: nil,
            noteCategory: nil,
            originalFilename: "missing.heic",
            originalRelativePath: "Originals/missing.heic",
            originalByteSize: 4,
            storageBucket: "scoutcapture-originals",
            storagePath: "sessions/session-id/shots/shot-id/missing.heic",
            checksumSHA256: String(repeating: "a", count: 64),
            byteSize: 4,
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
            shots: [shot],
            issues: [IssueMetadata(issueID: UUID(), currentReason: "Peeling paint")],
            guidedShots: [GuidedShot(title: "North overview", building: "Building", targetElevation: "North", detailType: "Overview", angleIndex: 1)]
        )
        try store.saveSessionMetadataAtomically(propertyID: property.id, sessionID: session.id, metadata: metadata)
    }

    func testFeatureFlagDefaultsOff() {
        let defaults = UserDefaults(suiteName: "ScoutCapture-2C23F-default-\(UUID().uuidString)") ?? .standard
        let flags = BackendFeatureFlags.load(userDefaults: defaults)

        XCTAssertFalse(flags.sessionSnapshotShadowWriteEnabled)
    }

    func testDisabledFlagPreventsUpload() async throws {
        var storageCalled = false
        var rowCalled = false
        let fixture = try makeFixture(
            shadowWriteEnabled: false,
            storageUploadOverride: { _ in storageCalled = true },
            rowInsertOverride: { _ in rowCalled = true }
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = await fixture.appState.uploadSessionSnapshotShadowWrite(
            propertyID: fixture.property.id,
            sessionID: fixture.session.id
        )

        XCTAssertEqual(result.outcome, .disabled)
        XCTAssertFalse(storageCalled)
        XCTAssertFalse(rowCalled)
    }

    func testUploadPathConstruction() {
        let orgID = UUID()
        let propertyID = UUID()
        let sessionID = UUID()
        let snapshotID = UUID()

        let path = AppState.sessionSnapshotStoragePath(
            orgID: orgID,
            propertyID: propertyID,
            sessionID: sessionID,
            snapshotKind: .completed,
            snapshotID: snapshotID
        )

        XCTAssertEqual(
            path,
            "orgs/\(orgID.uuidString.lowercased())/properties/\(propertyID.uuidString.lowercased())/sessions/\(sessionID.uuidString.lowercased())/snapshots/completed/\(snapshotID.uuidString.lowercased()).json"
        )
    }

    func testPayloadChecksumMetadataMatchesPreview() async throws {
        var uploadedObject: AppState.SessionSnapshotStorageObject?
        var insertedRow: AppState.SessionSnapshotUploadRow?
        let fixture = try makeFixture(
            storageUploadOverride: { uploadedObject = $0 },
            rowInsertOverride: { insertedRow = $0 }
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let generatedAt = Date(timeIntervalSinceReferenceDate: 800)

        let preview = fixture.appState.inspectSessionSnapshotPreview(
            inspectedAt: generatedAt,
            trigger: "manual_diagnostic"
        )
        let result = await fixture.appState.uploadSessionSnapshotShadowWrite(
            propertyID: fixture.property.id,
            sessionID: fixture.session.id,
            trigger: "manual_diagnostic",
            generatedAt: generatedAt
        )

        let envelope = try XCTUnwrap(preview.rows.first?.envelope)
        XCTAssertEqual(result.outcome, .succeeded)
        XCTAssertEqual(uploadedObject?.bucket, "scoutcapture-session-snapshots")
        XCTAssertEqual(uploadedObject?.payloadSHA256, envelope.snapshotPayloadSHA256)
        XCTAssertEqual(insertedRow?.snapshotPayloadSHA256, envelope.snapshotPayloadSHA256)
        XCTAssertEqual(insertedRow?.rawSessionJSONSHA256, envelope.rawSessionJSONSHA256)
        XCTAssertEqual(insertedRow?.payloadByteSize, envelope.snapshotPayloadByteCount)
    }

    func testStorageAndTableSuccessRecordsSuccess() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = await fixture.appState.uploadSessionSnapshotShadowWrite(
            propertyID: fixture.property.id,
            sessionID: fixture.session.id
        )

        XCTAssertEqual(result.outcome, .succeeded)
        XCTAssertEqual(fixture.appState.localDiagnostics.sessionSnapshotUpload.successCount, 1)
        XCTAssertEqual(fixture.appState.localDiagnostics.sessionSnapshotUpload.orphanRiskCount, 0)
    }

    func testStorageSuccessTableInsertFailureRecordsOrphanRisk() async throws {
        let fixture = try makeFixture(rowInsertOverride: { _ in
            throw NSError(domain: "ScoutCaptureTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "insert failed"
            ])
        })
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = await fixture.appState.uploadSessionSnapshotShadowWrite(
            propertyID: fixture.property.id,
            sessionID: fixture.session.id
        )

        XCTAssertEqual(result.outcome, .orphanRisk)
        XCTAssertEqual(fixture.appState.localDiagnostics.sessionSnapshotUpload.orphanRiskCount, 1)
        XCTAssertEqual(fixture.appState.localDiagnostics.sessionSnapshotUpload.failureCount, 1)
    }

    func testMissingRemoteBucketOrTableReportsUnavailableWithoutCrash() async throws {
        let fixture = try makeFixture(storageUploadOverride: { _ in
            throw AppState.SessionSnapshotUploadError.remoteUnavailable("missing bucket scoutcapture-session-snapshots")
        })
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = await fixture.appState.uploadSessionSnapshotShadowWrite(
            propertyID: fixture.property.id,
            sessionID: fixture.session.id
        )

        XCTAssertEqual(result.outcome, .unavailable)
        XCTAssertEqual(fixture.appState.localDiagnostics.sessionSnapshotUpload.remoteAvailability, "unavailable")
    }

    func testUploadReportIsSanitized() async throws {
        let fixture = try makeFixture(storageUploadOverride: { _ in
            throw NSError(domain: "ScoutCaptureTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "failed /private/tmp/session.json token=abc https://example.supabase.co/signed?token=secret data:image/png;base64,abcdef"
            ])
        })
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        _ = await fixture.appState.uploadSessionSnapshotShadowWrite(
            propertyID: fixture.property.id,
            sessionID: fixture.session.id
        )
        let report = AppState.sessionSnapshotUploadReportText(fixture.appState.localDiagnostics.sessionSnapshotUpload)

        XCTAssertFalse(report.contains("/private/tmp"))
        XCTAssertFalse(report.contains("token=abc"))
        XCTAssertFalse(report.contains("https://example.supabase.co"))
        XCTAssertFalse(report.contains("data:image/png"))
        XCTAssertFalse(report.contains("rawSessionJSON"))
        XCTAssertTrue(report.contains("does not switch canonical reads"))
    }

    func testUploadFailureReturnsResultAndDoesNotThrowOrBlockCaller() async throws {
        let fixture = try makeFixture(rowInsertOverride: { _ in
            throw NSError(domain: "ScoutCaptureTests", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "table insert failed"
            ])
        })
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = await fixture.appState.uploadSessionSnapshotShadowWrite(
            propertyID: fixture.property.id,
            sessionID: fixture.session.id,
            kind: .manual,
            trigger: "manual_diagnostic"
        )

        XCTAssertEqual(result.outcome, .orphanRisk)
        XCTAssertEqual(fixture.appState.localDiagnostics.sessionSnapshotUpload.failureCount, 1)
    }
}
