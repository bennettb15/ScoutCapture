import XCTest
@testable import ScoutCapture

final class Phase2C20ACompletenessGatesTests: XCTestCase {
    private func makeTempStorageRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScoutCapture-2C20A-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeFixture(
        sessionStatus: Session.Status = .completed,
        isSealed: Bool = true,
        firstDeliveredAt: Date? = nil,
        reExportExpiresAt: Date? = nil,
        exportedAt: Date? = nil
    ) throws -> (store: LocalStore, appState: AppState, root: URL, property: Property, session: Session) {
        let root = try makeTempStorageRoot()
        let store = LocalStore(testStorageRootURL: root)
        let orgID = UUID()
        let property = try store.createProperty(Property(id: UUID(), orgId: orgID, name: "Property"))
        let session = try store.upsertSession(
            Session(
                id: UUID(),
                propertyID: property.id,
                startedAt: Date(timeIntervalSinceReferenceDate: 100),
                status: sessionStatus,
                endedAt: sessionStatus == .completed ? Date(timeIntervalSinceReferenceDate: 200) : nil,
                exportedAt: exportedAt,
                isSealed: isSealed,
                firstDeliveredAt: firstDeliveredAt,
                reExportExpiresAt: reExportExpiresAt
            )
        )
        let defaults = UserDefaults(suiteName: "ScoutCapture-2C20A-\(UUID().uuidString)") ?? .standard
        let appState = AppState(localStore: store, userDefaults: defaults, disableCloudBackupForTests: true)
        return (store, appState, root, property, session)
    }

    private func makeShot(
        propertyID: UUID,
        sessionID: UUID,
        shotID: UUID = UUID(),
        filename: String = "shot.heic",
        lifecycleState: ShotLifecycleState = .active
    ) -> ShotMetadata {
        ShotMetadata(
            shotID: shotID,
            propertyID: propertyID,
            sessionID: sessionID,
            createdAt: Date(timeIntervalSinceReferenceDate: 150),
            updatedAt: Date(timeIntervalSinceReferenceDate: 150),
            building: "Building",
            elevation: "North",
            detailType: "Overview",
            angleIndex: 1,
            shotKey: ShotMetadata.makeShotKey(
                building: "Building",
                elevation: "North",
                detailType: "Overview",
                angleIndex: 1
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
            stampedFilename: nil,
            stampedRelativePath: nil,
            captureMode: nil,
            lens: nil,
            exifOrientation: nil,
            latitude: nil,
            longitude: nil,
            accuracyMeters: nil,
            imageWidth: nil,
            imageHeight: nil,
            lifecycleState: lifecycleState,
            retiredAt: lifecycleState == .retired ? Date(timeIntervalSinceReferenceDate: 180) : nil,
            retiredReason: lifecycleState == .retired ? "Duplicate" : nil
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
            appVersion: "test",
            deviceModel: "test",
            osVersion: "test",
            shots: shots,
            issues: issues,
            guidedShots: guidedShots
        )
        try store.saveSessionMetadataAtomically(propertyID: property.id, sessionID: session.id, metadata: metadata)
    }

    private func writeOriginal(store: LocalStore, propertyID: UUID, sessionID: UUID, filename: String) throws {
        let originals = store.originalsFolderURL(propertyID: propertyID, sessionID: sessionID)
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        try Data("data".utf8).write(to: originals.appendingPathComponent(filename))
    }

    private func count(
        _ report: AppState.CompletenessGatesReport,
        keyPath: KeyPath<AppState.CompletenessGatesReport, [AppState.CompletenessGateCount]>,
        state: AppState.CompletenessGateState
    ) -> Int {
        report[keyPath: keyPath].first { $0.state == state }?.count ?? 0
    }

    func testCompleteLocalSessionClassifiesMetadataCompleteOrBetter() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let shot = makeShot(propertyID: fixture.property.id, sessionID: fixture.session.id)
        try writeOriginal(store: fixture.store, propertyID: fixture.property.id, sessionID: fixture.session.id, filename: "shot.heic")
        try saveMetadata(store: fixture.store, property: fixture.property, session: fixture.session, shots: [shot])

        let report = fixture.appState.inspectCompletenessGates()

        XCTAssertEqual(count(report, keyPath: \.sessionCounts, state: .exportComplete), 1)
        XCTAssertEqual(count(report, keyPath: \.shotCounts, state: .mediaComplete), 1)
    }

    func testMissingSessionJSONIsNotMetadataComplete() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try? FileManager.default.removeItem(
            at: fixture.store.sessionJSONURL(propertyID: fixture.property.id, sessionID: fixture.session.id)
        )

        let report = fixture.appState.inspectCompletenessGates()

        XCTAssertEqual(count(report, keyPath: \.sessionCounts, state: .localOnly), 1)
        XCTAssertTrue(report.diagnosticOnlyRows.contains { $0.reason == "session_json_missing_or_unreadable" })
    }

    func testSessionIDMismatchIsDiagnosticOnlyNeedsReview() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let mismatched = SessionMetadata(
            schemaVersion: 12,
            propertyID: fixture.property.id,
            sessionID: UUID(),
            propertyNameAtCapture: fixture.property.name,
            propertyNameAtExport: nil,
            startedAt: fixture.session.startedAt,
            endedAt: fixture.session.endedAt,
            status: fixture.session.status,
            isBaselineSession: false,
            exportedAt: nil,
            isSealed: true,
            appVersion: "test",
            deviceModel: "test",
            osVersion: "test",
            shots: [],
            issues: []
        )
        let data = try JSONEncoder.iso8601Sorted.encode(mismatched)
        try FileManager.default.createDirectory(
            at: fixture.store.sessionJSONURL(propertyID: fixture.property.id, sessionID: fixture.session.id).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fixture.store.sessionJSONURL(propertyID: fixture.property.id, sessionID: fixture.session.id))

        let report = fixture.appState.inspectCompletenessGates()

        let row = try XCTUnwrap(report.diagnosticOnlyRows.first { $0.reason == "session_json_id_mismatch" })
        XCTAssertEqual(row.freshness, .needsReview)
    }

    func testActiveShotMissingOriginalIsNotMediaComplete() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let shot = makeShot(propertyID: fixture.property.id, sessionID: fixture.session.id)
        try saveMetadata(store: fixture.store, property: fixture.property, session: fixture.session, shots: [shot])

        let report = fixture.appState.inspectCompletenessGates()

        XCTAssertEqual(count(report, keyPath: \.mediaCounts, state: .metadataComplete), 1)
        XCTAssertTrue(report.diagnosticOnlyRows.contains { $0.reason == "active_export_shot_original_missing" })
        XCTAssertEqual(report.exportCompleteSessionCount, 0)
    }

    func testMissingOriginalInDraftUnsealedSessionIsPreExportWarning() throws {
        let fixture = try makeFixture(sessionStatus: .draft, isSealed: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let shot = makeShot(propertyID: fixture.property.id, sessionID: fixture.session.id)
        try saveMetadata(store: fixture.store, property: fixture.property, session: fixture.session, shots: [shot])

        let report = fixture.appState.inspectCompletenessGates()
        let row = try XCTUnwrap(AppState.dedupedCompletenessDiagnosticRows(report.diagnosticOnlyRows).first {
            $0.reason == "active_export_shot_original_missing"
        })

        XCTAssertEqual(row.classification, .preExportWarning)
        XCTAssertEqual(row.context["is_export_eligible"], "false")
    }

    func testMissingOriginalInCompletedSealedSessionRemainsActionable() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let shot = makeShot(propertyID: fixture.property.id, sessionID: fixture.session.id)
        try saveMetadata(store: fixture.store, property: fixture.property, session: fixture.session, shots: [shot])

        let report = fixture.appState.inspectCompletenessGates()
        let row = try XCTUnwrap(AppState.dedupedCompletenessDiagnosticRows(report.diagnosticOnlyRows).first {
            $0.reason == "active_export_shot_original_missing"
        })

        XCTAssertEqual(row.classification, .actionable)
        XCTAssertEqual(row.context["is_export_eligible"], "true")
    }

    func testPendingDeliveryMissingOriginalClassifiedAsActiveDeliveryRisk() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let shot = makeShot(propertyID: fixture.property.id, sessionID: fixture.session.id)
        try saveMetadata(store: fixture.store, property: fixture.property, session: fixture.session, shots: [shot])

        let report = fixture.appState.inspectCompletenessGates(inspectedAt: Date(timeIntervalSinceReferenceDate: 300))
        let row = try XCTUnwrap(AppState.dedupedCompletenessDiagnosticRows(report.diagnosticOnlyRows).first {
            $0.reason == "active_export_shot_original_missing"
        })
        let text = AppState.completenessGatesReportText(report)

        XCTAssertEqual(row.context["missing_original_risk"], "active_delivery_risk")
        XCTAssertEqual(row.context["is_pending_delivery"], "true")
        XCTAssertEqual(row.classification, .actionable)
        XCTAssertTrue(text.contains("active_delivery_risk: 1"))
    }

    func testReExportEligibleMissingOriginalClassifiedAsReexportRisk() throws {
        let deliveredAt = Date(timeIntervalSinceReferenceDate: 200)
        let fixture = try makeFixture(
            firstDeliveredAt: deliveredAt,
            reExportExpiresAt: Date(timeIntervalSinceReferenceDate: 500),
            exportedAt: deliveredAt
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let shot = makeShot(propertyID: fixture.property.id, sessionID: fixture.session.id)
        try saveMetadata(store: fixture.store, property: fixture.property, session: fixture.session, shots: [shot])

        let report = fixture.appState.inspectCompletenessGates(inspectedAt: Date(timeIntervalSinceReferenceDate: 300))
        let row = try XCTUnwrap(AppState.dedupedCompletenessDiagnosticRows(report.diagnosticOnlyRows).first {
            $0.reason == "active_export_shot_original_missing"
        })

        XCTAssertEqual(row.context["missing_original_risk"], "reexport_risk")
        XCTAssertEqual(row.context["is_reexport_eligible"], "true")
        XCTAssertEqual(row.classification, .actionable)
    }

    func testDeliveredExpiredMissingOriginalClassifiedAsHistoricalArchiveDebt() throws {
        let deliveredAt = Date(timeIntervalSinceReferenceDate: 100)
        let fixture = try makeFixture(
            firstDeliveredAt: deliveredAt,
            reExportExpiresAt: Date(timeIntervalSinceReferenceDate: 200),
            exportedAt: deliveredAt
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let shot = makeShot(propertyID: fixture.property.id, sessionID: fixture.session.id)
        try saveMetadata(store: fixture.store, property: fixture.property, session: fixture.session, shots: [shot])

        let report = fixture.appState.inspectCompletenessGates(inspectedAt: Date(timeIntervalSinceReferenceDate: 300))
        let row = try XCTUnwrap(AppState.dedupedCompletenessDiagnosticRows(report.diagnosticOnlyRows).first {
            $0.reason == "active_export_shot_original_missing"
        })

        XCTAssertEqual(row.context["missing_original_risk"], "historical_archive_debt")
        XCTAssertEqual(row.context["reexport_window_expired"], "true")
        XCTAssertEqual(row.classification, .informational)
    }

    func testArchiveSnapshotCandidateAppearsWithoutRestoringFiles() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let shot = makeShot(propertyID: fixture.property.id, sessionID: fixture.session.id, filename: "archive-hit.heic")
        try saveMetadata(store: fixture.store, property: fixture.property, session: fixture.session, shots: [shot])
        let snapshotOriginals = fixture.root
            .appendingPathComponent("Archives/Sessions", isDirectory: true)
            .appendingPathComponent(fixture.property.id.uuidString, isDirectory: true)
            .appendingPathComponent(fixture.session.id.uuidString, isDirectory: true)
            .appendingPathComponent("20260101T000000Z-sealed-test/Payload/Originals", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshotOriginals, withIntermediateDirectories: true)
        try Data("archived".utf8).write(to: snapshotOriginals.appendingPathComponent("archive-hit.heic"))

        let report = fixture.appState.inspectCompletenessGates()
        let row = try XCTUnwrap(AppState.dedupedCompletenessDiagnosticRows(report.diagnosticOnlyRows).first {
            $0.reason == "active_export_shot_original_missing"
        })

        XCTAssertEqual(row.context["archive_snapshot_exists"], "true")
        XCTAssertEqual(row.context["archive_snapshot_count"], "1")
        XCTAssertEqual(row.context["archive_payload_originals_candidate_hit"], "true")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.store.originalsFolderURL(propertyID: fixture.property.id, sessionID: fixture.session.id).appendingPathComponent("archive-hit.heic").path))
    }

    func testSupabaseStorageCandidateAppearsWithoutSignedURL() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var shot = makeShot(propertyID: fixture.property.id, sessionID: fixture.session.id)
        shot.storageBucket = "operational-media"
        shot.storagePath = "sessions/\(fixture.session.id.uuidString.lowercased())/shots/\(shot.shotID.uuidString.lowercased())/shot.heic"
        shot.checksumSHA256 = "abcdef"
        shot.byteSize = 4
        try saveMetadata(store: fixture.store, property: fixture.property, session: fixture.session, shots: [shot])

        let report = fixture.appState.inspectCompletenessGates()
        let row = try XCTUnwrap(AppState.dedupedCompletenessDiagnosticRows(report.diagnosticOnlyRows).first {
            $0.reason == "active_export_shot_original_missing"
        })
        let text = AppState.completenessGatesReportText(report)

        XCTAssertEqual(row.context["supabase_storage_candidate"], "true")
        XCTAssertEqual(row.context["local_shot_storage_bucket_present"], "true")
        XCTAssertEqual(row.context["local_shot_storage_path_present"], "true")
        XCTAssertFalse(text.localizedCaseInsensitiveContains("signature="))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("signed"))
    }

    func testDuplicateShotIDGroupContextAppears() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let sharedShotID = UUID()
        let shot = makeShot(propertyID: fixture.property.id, sessionID: fixture.session.id, shotID: sharedShotID)
        let secondSession = try fixture.store.upsertSession(
            Session(
                id: UUID(),
                propertyID: fixture.property.id,
                startedAt: Date(timeIntervalSinceReferenceDate: 120),
                status: .draft
            )
        )
        let duplicateShot = makeShot(propertyID: fixture.property.id, sessionID: secondSession.id, shotID: sharedShotID)
        try saveMetadata(store: fixture.store, property: fixture.property, session: fixture.session, shots: [shot])
        try saveMetadata(store: fixture.store, property: fixture.property, session: secondSession, shots: [duplicateShot])

        let report = fixture.appState.inspectCompletenessGates()
        let row = try XCTUnwrap(AppState.dedupedCompletenessDiagnosticRows(report.diagnosticOnlyRows).first {
            $0.reason == "active_export_shot_original_missing" && $0.sessionID == fixture.session.id
        })
        let text = AppState.completenessGatesReportText(report)

        XCTAssertEqual(row.context["duplicate_shot_id_group_size"], "2")
        XCTAssertEqual(row.context["duplicate_shot_id_across_sessions"], "true")
        XCTAssertTrue(text.contains("duplicate_shot_id_group"))
    }

    func testRetiredShotIsPreservedButDoesNotBlockDefaultExportCompleteness() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let active = makeShot(propertyID: fixture.property.id, sessionID: fixture.session.id, filename: "active.heic")
        let retired = makeShot(
            propertyID: fixture.property.id,
            sessionID: fixture.session.id,
            filename: "retired.heic",
            lifecycleState: .retired
        )
        try writeOriginal(store: fixture.store, propertyID: fixture.property.id, sessionID: fixture.session.id, filename: "active.heic")
        try saveMetadata(store: fixture.store, property: fixture.property, session: fixture.session, shots: [active, retired])

        let report = fixture.appState.inspectCompletenessGates()

        XCTAssertEqual(report.exportCompleteSessionCount, 1)
        XCTAssertTrue(report.diagnosticOnlyRows.contains { $0.reason == "shot_historical_lifecycle" })
    }

    func testIssueHistoryOrphanReferenceBlocksExportComplete() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let shot = makeShot(propertyID: fixture.property.id, sessionID: fixture.session.id)
        try writeOriginal(store: fixture.store, propertyID: fixture.property.id, sessionID: fixture.session.id, filename: "shot.heic")
        let issue = IssueMetadata(
            issueID: UUID(),
            issueStatus: "active",
            currentReason: "Crack",
            historyEvents: [
                IssueHistoryEvent(
                    timestamp: Date(timeIntervalSinceReferenceDate: 160),
                    sessionId: fixture.session.id,
                    type: "captured",
                    details: ["shotId": UUID().uuidString]
                )
            ]
        )
        try saveMetadata(store: fixture.store, property: fixture.property, session: fixture.session, shots: [shot], issues: [issue])

        let report = fixture.appState.inspectCompletenessGates()

        XCTAssertEqual(report.exportCompleteSessionCount, 0)
        XCTAssertTrue(report.diagnosticOnlyRows.contains { $0.reason == "issue_history_orphan_shot_reference" })
    }

    func testCrossSessionIssueHistoryWithExistingReferencedSessionIsInformational() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let referencedSession = try fixture.store.upsertSession(
            Session(
                id: UUID(),
                propertyID: fixture.property.id,
                startedAt: Date(timeIntervalSinceReferenceDate: 50),
                status: .completed,
                endedAt: Date(timeIntervalSinceReferenceDate: 90),
                isSealed: true
            )
        )
        let shot = makeShot(propertyID: fixture.property.id, sessionID: fixture.session.id)
        try writeOriginal(store: fixture.store, propertyID: fixture.property.id, sessionID: fixture.session.id, filename: "shot.heic")
        let issue = IssueMetadata(
            issueID: UUID(),
            issueStatus: "active",
            currentReason: "Crack",
            historyEvents: [
                IssueHistoryEvent(
                    timestamp: Date(timeIntervalSinceReferenceDate: 160),
                    sessionId: referencedSession.id,
                    type: "reason_updated"
                )
            ]
        )
        try saveMetadata(store: fixture.store, property: fixture.property, session: fixture.session, shots: [shot], issues: [issue])

        let report = fixture.appState.inspectCompletenessGates()
        let row = try XCTUnwrap(AppState.dedupedCompletenessDiagnosticRows(report.diagnosticOnlyRows).first {
            $0.reason == "issue_history_cross_session_reference"
        })

        XCTAssertEqual(row.classification, .informational)
        XCTAssertEqual(row.context["referenced_issue_history_session_exists_locally"], "true")
        XCTAssertFalse(report.diagnosticOnlyRows.contains { $0.reason == "issue_history_orphan_session_reference" })
    }

    func testMissingReferencedIssueHistorySessionRemainsActionable() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let shot = makeShot(propertyID: fixture.property.id, sessionID: fixture.session.id)
        try writeOriginal(store: fixture.store, propertyID: fixture.property.id, sessionID: fixture.session.id, filename: "shot.heic")
        let issue = IssueMetadata(
            issueID: UUID(),
            issueStatus: "active",
            currentReason: "Crack",
            historyEvents: [
                IssueHistoryEvent(
                    timestamp: Date(timeIntervalSinceReferenceDate: 160),
                    sessionId: UUID(),
                    type: "reason_updated"
                )
            ]
        )
        try saveMetadata(store: fixture.store, property: fixture.property, session: fixture.session, shots: [shot], issues: [issue])

        let report = fixture.appState.inspectCompletenessGates()
        let row = try XCTUnwrap(AppState.dedupedCompletenessDiagnosticRows(report.diagnosticOnlyRows).first {
            $0.reason == "issue_history_missing_session_reference"
        })

        XCTAssertEqual(row.classification, .actionable)
        XCTAssertEqual(row.context["referenced_issue_history_session_exists_locally"], "false")
    }

    func testGuidedRowMissingCaptureFieldsBlocksGuidedMetadataCompleteness() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let shot = makeShot(propertyID: fixture.property.id, sessionID: fixture.session.id)
        try writeOriginal(store: fixture.store, propertyID: fixture.property.id, sessionID: fixture.session.id, filename: "shot.heic")
        let guided = GuidedShot(title: "Missing target")
        try saveMetadata(
            store: fixture.store,
            property: fixture.property,
            session: fixture.session,
            shots: [shot],
            guidedShots: [guided]
        )

        let report = fixture.appState.inspectCompletenessGates()

        XCTAssertEqual(report.exportCompleteSessionCount, 0)
        XCTAssertTrue(report.diagnosticOnlyRows.contains { $0.reason == "guided_building_missing" })
    }

    func testCompletenessReportRedactsSensitiveText() {
        let report = makeSyntheticReport(rows: [
            diagnosticRow(
                entityType: "session",
                freshness: .needsReview,
                context: [
                    "signed_url": "https://example.test/file?signature=secret",
                    "payload": "data:image/jpeg;base64,abcdef"
                ],
                reason: "/private/tmp/secret token abc https://example.test/file?signature=secret"
            )
        ])

        let text = AppState.completenessGatesReportText(report)

        XCTAssertFalse(text.contains("/private/tmp/secret"))
        XCTAssertFalse(text.contains("signature=secret"))
        XCTAssertFalse(text.contains("data:image"))
        XCTAssertFalse(text.contains("abcdef"))
        XCTAssertTrue(text.contains("[path]"))
        XCTAssertTrue(text.contains("[media]"))
    }

    func testDuplicateDiagnosticRowsCollapseWithCount() {
        let entityID = UUID()
        let propertyID = UUID()
        let sessionID = UUID()
        let duplicate = diagnosticRow(
            entityType: "guided",
            entityID: entityID,
            propertyID: propertyID,
            sessionID: sessionID,
            state: .metadataComplete,
            freshness: .unknown,
            reason: "guided_retired"
        )
        let report = makeSyntheticReport(rows: [duplicate, duplicate])

        let deduped = AppState.dedupedCompletenessDiagnosticRows(report.diagnosticOnlyRows)
        let text = AppState.completenessGatesReportText(report)

        XCTAssertEqual(deduped.count, 1)
        XCTAssertEqual(deduped.first?.duplicateCount, 2)
        XCTAssertTrue(text.contains("raw_diagnostic_rows: 2"))
        XCTAssertTrue(text.contains("deduped_diagnostic_rows: 1"))
        XCTAssertTrue(text.contains("duplicates=2"))
    }

    func testGroupedReasonCountsArePresent() {
        let report = makeSyntheticReport(rows: [
            diagnosticRow(entityType: "guided", reason: "guided_retired"),
            diagnosticRow(entityType: "guided", reason: "guided_retired"),
            diagnosticRow(
                entityType: "shot",
                freshness: .needsReview,
                context: ["is_export_eligible": "true"],
                reason: "active_export_shot_original_missing"
            )
        ])

        let text = AppState.completenessGatesReportText(report)

        XCTAssertTrue(text.contains("Diagnostic Reason Counts"))
        XCTAssertTrue(text.contains("historical_informational | guided_retired: 2"))
        XCTAssertTrue(text.contains("actionable_needs_review | active_export_shot_original_missing: 1"))
    }

    func testGuidedRetiredAndHistoricalShotAreInformational() {
        let rows = AppState.dedupedCompletenessDiagnosticRows([
            diagnosticRow(entityType: "guided", reason: "guided_retired"),
            diagnosticRow(entityType: "shot", reason: "shot_historical_lifecycle")
        ])

        XCTAssertEqual(Set(rows.map { $0.classification }), [.informational])
    }

    func testSessionRollupIsLabeledAsRollup() {
        let report = makeSyntheticReport(rows: [
            diagnosticRow(
                entityType: "session",
                rowScope: .sessionRollup,
                reason: "active_export_shot_media_incomplete"
            )
        ])

        let row = AppState.dedupedCompletenessDiagnosticRows(report.diagnosticOnlyRows).first

        XCTAssertEqual(row?.classification, .sessionRollup)
        XCTAssertEqual(row?.rowScope, .sessionRollup)
    }

    func testActiveMissingOriginalIsActionableNeedsReview() {
        let row = AppState.dedupedCompletenessDiagnosticRows([
            diagnosticRow(
                entityType: "shot",
                freshness: .unknown,
                context: ["is_export_eligible": "true"],
                reason: "active_export_shot_original_missing"
            )
        ]).first

        XCTAssertEqual(row?.classification, .actionable)
    }

    func testIssueOrphanReferencesAreActionableNeedsReview() {
        let rows = AppState.dedupedCompletenessDiagnosticRows([
            diagnosticRow(
                entityType: "issue",
                freshness: .unknown,
                reason: "issue_history_missing_session_reference"
            ),
            diagnosticRow(
                entityType: "issue",
                freshness: .unknown,
                reason: "issue_history_orphan_shot_reference"
            )
        ])

        XCTAssertEqual(Set(rows.map { $0.classification }), [.actionable])
    }

    func testLocalOriginalExistenceIsReportedWithoutFullPaths() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let shot = makeShot(propertyID: fixture.property.id, sessionID: fixture.session.id)
        try saveMetadata(store: fixture.store, property: fixture.property, session: fixture.session, shots: [shot])

        let report = fixture.appState.inspectCompletenessGates()
        let text = AppState.completenessGatesReportText(report)

        XCTAssertTrue(text.contains("local_original_exists=false"))
        XCTAssertTrue(text.contains("shot_original_filename_present=true"))
        XCTAssertFalse(text.contains(fixture.root.path))
    }

    func testFreshnessExplanationAppearsWhenUnknownFreshnessCountIsHigh() {
        let report = makeSyntheticReport(
            freshnessCounts: [
                .init(state: .current, count: 1),
                .init(state: .remoteUpdatesAvailable, count: 0),
                .init(state: .needsReview, count: 0),
                .init(state: .usingLocalCache, count: 0),
                .init(state: .offline, count: 0),
                .init(state: .unknown, count: 292)
            ],
            rows: []
        )

        let text = AppState.completenessGatesReportText(report)

        XCTAssertTrue(text.contains("Freshness Explanation"))
        XCTAssertTrue(text.contains("property-open freshness is checked only for opened properties"))
        XCTAssertTrue(text.contains("Unknown freshness alone is not treated as an active regression"))
    }

    func testPreflightMissingSessionJSONIsHardBlockCandidateInReportOnly() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try? FileManager.default.removeItem(
            at: fixture.store.sessionJSONURL(propertyID: fixture.property.id, sessionID: fixture.session.id)
        )

        let completenessReport = fixture.appState.inspectCompletenessGates()
        let preflightReport = AppState.makeExportSealPreflightReport(from: completenessReport)
        let text = AppState.exportSealPreflightReportText(preflightReport)

        XCTAssertEqual(preflightCategoryCount(.hardBlockCandidate, in: preflightReport, scope: .export), 1)
        XCTAssertTrue(text.contains("session_json_missing_or_unreadable"))
        XCTAssertTrue(text.contains("Export is not blocked"))
        XCTAssertTrue(text.contains("Sealing is not blocked"))
    }

    func testPreflightHistoricalArchiveDebtIsInformationalOnly() throws {
        let deliveredAt = Date(timeIntervalSinceReferenceDate: 100)
        let fixture = try makeFixture(
            firstDeliveredAt: deliveredAt,
            reExportExpiresAt: Date(timeIntervalSinceReferenceDate: 200),
            exportedAt: deliveredAt
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let shot = makeShot(propertyID: fixture.property.id, sessionID: fixture.session.id)
        try saveMetadata(store: fixture.store, property: fixture.property, session: fixture.session, shots: [shot])

        let completenessReport = fixture.appState.inspectCompletenessGates(inspectedAt: Date(timeIntervalSinceReferenceDate: 300))
        let preflightReport = AppState.makeExportSealPreflightReport(from: completenessReport)

        XCTAssertEqual(preflightCategoryCount(.informationalOnly, in: preflightReport, scope: .export), 2)
        XCTAssertTrue(AppState.exportSealPreflightReportText(preflightReport).contains("historical_archive_debt"))
    }

    func testPreflightPendingDeliveryMissingOriginalIsHardBlockCandidateInReportOnly() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let shot = makeShot(propertyID: fixture.property.id, sessionID: fixture.session.id)
        try saveMetadata(store: fixture.store, property: fixture.property, session: fixture.session, shots: [shot])

        let preflightReport = AppState.makeExportSealPreflightReport(
            from: fixture.appState.inspectCompletenessGates(inspectedAt: Date(timeIntervalSinceReferenceDate: 300))
        )
        let exportFindings = preflightFindings(preflightReport, scope: .export)

        XCTAssertTrue(exportFindings.contains {
            $0.reason == "active_export_shot_original_missing" &&
                $0.category == .hardBlockCandidate &&
                $0.context["missing_original_risk"] == "active_delivery_risk"
        })
        XCTAssertTrue(AppState.exportSealPreflightReportText(preflightReport).contains("No behavior changed"))
    }

    func testPreflightReExportEligibleMissingOriginalIsHardBlockCandidateInReportOnly() throws {
        let deliveredAt = Date(timeIntervalSinceReferenceDate: 200)
        let fixture = try makeFixture(
            firstDeliveredAt: deliveredAt,
            reExportExpiresAt: Date(timeIntervalSinceReferenceDate: 500),
            exportedAt: deliveredAt
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let shot = makeShot(propertyID: fixture.property.id, sessionID: fixture.session.id)
        try saveMetadata(store: fixture.store, property: fixture.property, session: fixture.session, shots: [shot])

        let preflightReport = AppState.makeExportSealPreflightReport(
            from: fixture.appState.inspectCompletenessGates(inspectedAt: Date(timeIntervalSinceReferenceDate: 300))
        )
        let reExportFindings = preflightFindings(preflightReport, scope: .reExport)

        XCTAssertTrue(reExportFindings.contains {
            $0.reason == "active_export_shot_original_missing" &&
                $0.category == .hardBlockCandidate &&
                $0.context["missing_original_risk"] == "reexport_risk"
        })
        XCTAssertTrue(AppState.exportSealPreflightReportText(preflightReport).contains("Export is not blocked"))
    }

    func testPreflightRetiredGuidedRowIsInformationalOnly() {
        let report = makeSyntheticReport(rows: [
            diagnosticRow(entityType: "guided", reason: "guided_retired")
        ])
        let preflightReport = AppState.makeExportSealPreflightReport(from: report)

        XCTAssertEqual(preflightCategoryCount(.informationalOnly, in: preflightReport, scope: .sealComplete), 1)
        XCTAssertEqual(preflightCategoryCount(.hardBlockCandidate, in: preflightReport, scope: .sealComplete), 0)
    }

    func testPreflightUnknownFreshnessIsSoftWarningCandidateNotHardBlock() {
        let report = makeSyntheticReport(rows: [
            diagnosticRow(entityType: "property", freshness: .unknown, reason: "property_minimum_metadata_missing")
        ])
        let preflightReport = AppState.makeExportSealPreflightReport(from: report)

        XCTAssertEqual(preflightCategoryCount(.softWarningCandidate, in: preflightReport, scope: .export), 1)
        XCTAssertEqual(preflightCategoryCount(.hardBlockCandidate, in: preflightReport, scope: .export), 0)
    }

    func testPreflightReportSaysAdvisoryAndNoBehaviorChanged() {
        let preflightReport = AppState.makeExportSealPreflightReport(from: makeSyntheticReport(rows: []))
        let text = AppState.exportSealPreflightReportText(preflightReport)

        XCTAssertTrue(text.contains("Read-only advisory diagnostics"))
        XCTAssertTrue(text.contains("No behavior changed"))
        XCTAssertTrue(text.contains("Export is not blocked"))
        XCTAssertTrue(text.contains("Sealing is not blocked"))
        XCTAssertTrue(text.contains("Seal / Complete Preflight"))
        XCTAssertTrue(text.contains("Export Preflight"))
        XCTAssertTrue(text.contains("Re-Export Preflight"))
    }

    func testPreflightReportRedactsPathsSignedURLsTokensAndMediaPayloads() {
        let report = makeSyntheticReport(rows: [
            diagnosticRow(
                entityType: "session",
                freshness: .needsReview,
                context: [
                    "path": "/private/tmp/secret/file.heic",
                    "signed_url": "https://example.test/file?signature=secret",
                    "token": "token abc",
                    "payload": "data:image/jpeg;base64,abcdef"
                ],
                reason: "/private/tmp/secret token abc https://example.test/file?signature=secret data:image/jpeg;base64,abcdef"
            )
        ])

        let text = AppState.exportSealPreflightReportText(AppState.makeExportSealPreflightReport(from: report))

        XCTAssertFalse(text.contains("/private/tmp/secret"))
        XCTAssertFalse(text.contains("signature=secret"))
        XCTAssertFalse(text.contains("token abc"))
        XCTAssertFalse(text.contains("data:image"))
        XCTAssertFalse(text.contains("abcdef"))
        XCTAssertTrue(text.contains("[path]"))
        XCTAssertTrue(text.contains("[redacted]"))
        XCTAssertTrue(text.contains("[media]"))
    }

    func testPreflightVisibleLabelsMapFromRawEnumCategories() {
        XCTAssertEqual(AppState.ExportSealPreflightCategory.hardBlockCandidate.visibleLabel, "Future Hard Blocks")
        XCTAssertEqual(AppState.ExportSealPreflightCategory.softWarningCandidate.visibleLabel, "Advisory Warnings")
        XCTAssertEqual(AppState.ExportSealPreflightCategory.informationalOnly.visibleLabel, "Historical / Informational")
        XCTAssertEqual(AppState.ExportSealPreflightCategory.unknownNeedsReview.visibleLabel, "Needs Review / Unknown")
        XCTAssertEqual(
            AppState.ExportSealPreflightCategory.hardBlockCandidate.visibleExplanation,
            "Conditions that may later become true blockers."
        )
        XCTAssertEqual(
            AppState.ExportSealPreflightCategory.softWarningCandidate.visibleExplanation,
            "Conditions worth reviewing but not severe enough to block."
        )
        XCTAssertEqual(
            AppState.ExportSealPreflightCategory.informationalOnly.visibleExplanation,
            "Retained for audit/history; not operational blockers."
        )
        XCTAssertEqual(
            AppState.ExportSealPreflightCategory.unknownNeedsReview.visibleExplanation,
            "Incomplete context that needs operator review before enforcement."
        )
        XCTAssertEqual(AppState.ExportSealPreflightCategory.hardBlockCandidate.drilldownClassificationLabel, "hard block candidate")
        XCTAssertEqual(AppState.ExportSealPreflightCategory.softWarningCandidate.drilldownClassificationLabel, "advisory warning")
        XCTAssertEqual(AppState.ExportSealPreflightCategory.informationalOnly.drilldownClassificationLabel, "informational")
        XCTAssertEqual(AppState.ExportSealPreflightCategory.unknownNeedsReview.drilldownClassificationLabel, "unknown")
    }

    func testPreflightZeroHardBlockStatusMessageAppears() {
        XCTAssertEqual(
            AppState.exportSealPreflightStatusMessage(hardBlockCandidateCount: 0),
            "No future hard-block conditions detected."
        )
    }

    func testPreflightNonzeroHardBlockStatusMessageAppears() {
        XCTAssertEqual(
            AppState.exportSealPreflightStatusMessage(hardBlockCandidateCount: 2),
            "Potential future hard-block conditions found. Export/seal behavior is still unchanged."
        )
    }

    func testPreflightVisibleAdvisoryMessageRemainsNoBehaviorChanged() {
        XCTAssertEqual(
            AppState.exportSealPreflightAdvisoryMessage(),
            "Read-only advisory diagnostics. These counts do not block export or sealing."
        )
    }

    func testPreflightCopyableReportStillIncludesRawTechnicalCategories() {
        let report = AppState.makeExportSealPreflightReport(from: makeSyntheticReport(rows: [
            diagnosticRow(entityType: "session", reason: "session_json_missing_or_unreadable"),
            diagnosticRow(
                entityType: "property",
                freshness: .unknown,
                reason: "property_minimum_metadata_missing"
            ),
            diagnosticRow(entityType: "guided", reason: "guided_retired"),
            diagnosticRow(
                entityType: "shot",
                freshness: .needsReview,
                reason: "shot_provenance_unresolved"
            )
        ]))

        let text = AppState.exportSealPreflightReportText(report)

        XCTAssertTrue(text.contains("hard_block_candidate"))
        XCTAssertTrue(text.contains("soft_warning_candidate"))
        XCTAssertTrue(text.contains("informational_only"))
        XCTAssertTrue(text.contains("unknown_needs_review"))
    }

    func testPreflightGroupedReasonSummariesAppear() {
        let report = AppState.makeExportSealPreflightReport(from: makeSyntheticReport(rows: [
            diagnosticRow(
                entityType: "property",
                freshness: .unknown,
                reason: "property_minimum_metadata_missing"
            ),
            diagnosticRow(
                entityType: "shot",
                context: [
                    "missing_original_risk": "historical_archive_debt",
                    "is_export_eligible": "true"
                ],
                reason: "active_export_shot_original_missing"
            ),
            diagnosticRow(entityType: "guided", reason: "guided_retired"),
            diagnosticRow(entityType: "issue", reason: "issue_history_cross_session_reference"),
            diagnosticRow(entityType: "session", rowScope: .sessionRollup, reason: "active_export_shot_media_incomplete")
        ]))

        let titles = Set(preflightSummaries(report, scope: .export).map(\.title))

        XCTAssertTrue(titles.contains("Unknown freshness"))
        XCTAssertTrue(titles.contains("Historical archive debt"))
        XCTAssertTrue(titles.contains("Retired guided rows"))
        XCTAssertTrue(titles.contains("Cross-session issue history"))
        XCTAssertTrue(titles.contains("Session rollup advisory"))
    }

    func testPreflightFriendlyTitlesMapFromTechnicalReasons() {
        let report = AppState.makeExportSealPreflightReport(from: makeSyntheticReport(rows: [
            diagnosticRow(entityType: "session", reason: "session_json_missing_or_unreadable"),
            diagnosticRow(entityType: "session", freshness: .needsReview, reason: "session_json_id_mismatch"),
            diagnosticRow(entityType: "issue", reason: "issue_history_orphan_shot_reference")
        ]))

        let summaries = preflightSummaries(report, scope: .export)

        XCTAssertTrue(summaries.contains { $0.title == "Missing session metadata" && $0.category == .hardBlockCandidate })
        XCTAssertTrue(summaries.contains { $0.title == "Session identity mismatch" && $0.category == .hardBlockCandidate })
        XCTAssertTrue(summaries.contains { $0.title == "Issue/export linkage missing references" && $0.category == .hardBlockCandidate })
    }

    func testPreflightAdvisoryWarningsExplainWhyTheyAreWarnings() {
        let report = AppState.makeExportSealPreflightReport(from: makeSyntheticReport(rows: [
            diagnosticRow(
                entityType: "shot",
                context: [
                    "is_export_eligible": "false",
                    "supabase_storage_candidate": "true"
                ],
                reason: "active_export_shot_original_missing"
            ),
            diagnosticRow(
                entityType: "shot",
                context: [
                    "is_export_eligible": "false",
                    "duplicate_shot_id_across_sessions": "true"
                ],
                reason: "active_export_shot_original_missing"
            )
        ]))

        let summaries = preflightSummaries(report, scope: .export)
        let supabase = try? XCTUnwrap(summaries.first { $0.title == "Supabase storage candidate" })
        let duplicate = try? XCTUnwrap(summaries.first { $0.title == "Duplicate shot ID context" })

        XCTAssertEqual(supabase?.category, .softWarningCandidate)
        XCTAssertTrue(supabase?.explanation.contains("does not download or relink media") == true)
        XCTAssertEqual(duplicate?.category, .softWarningCandidate)
        XCTAssertTrue(duplicate?.explanation.contains("advisory") == true)
    }

    func testPreflightInformationalRowsExplainWhyTheyDoNotBlock() {
        let report = AppState.makeExportSealPreflightReport(from: makeSyntheticReport(rows: [
            diagnosticRow(
                entityType: "shot",
                context: [
                    "missing_original_risk": "historical_archive_debt",
                    "is_export_eligible": "true"
                ],
                reason: "active_export_shot_original_missing"
            ),
            diagnosticRow(entityType: "guided", reason: "guided_retired")
        ]))

        let summaries = preflightSummaries(report, scope: .export)
        let archiveDebt = try? XCTUnwrap(summaries.first { $0.title == "Historical archive debt" })
        let retiredGuided = try? XCTUnwrap(summaries.first { $0.title == "Retired guided rows" })

        XCTAssertEqual(archiveDebt?.category, .informationalOnly)
        XCTAssertTrue(archiveDebt?.explanation.contains("not operational blockers") == true)
        XCTAssertEqual(retiredGuided?.category, .informationalOnly)
        XCTAssertTrue(retiredGuided?.explanation.contains("not operational blockers") == true)
    }

    func testPreflightRawReportStillContainsTechnicalReasonAndCategoryData() {
        let report = AppState.makeExportSealPreflightReport(from: makeSyntheticReport(rows: [
            diagnosticRow(
                entityType: "shot",
                context: [
                    "missing_original_risk": "historical_archive_debt",
                    "is_export_eligible": "true"
                ],
                reason: "active_export_shot_original_missing"
            )
        ]))

        let text = AppState.exportSealPreflightReportText(report)

        XCTAssertTrue(text.contains("informational_only"))
        XCTAssertTrue(text.contains("active_export_shot_original_missing"))
        XCTAssertTrue(text.contains("missing_original_risk=historical_archive_debt"))
    }

    func testEnforcementPolicyMatrixContainsAllRequiredConditionKeys() {
        let report = AppState.makeEnforcementPolicyMatrixReport(inspectedAt: Date(timeIntervalSinceReferenceDate: 300))
        let keys = Set(report.rows.map(\.conditionKey))

        XCTAssertEqual(keys, Set([
            "missing_or_unreadable_session_json",
            "session_property_identity_mismatch",
            "active_export_shot_missing_local_original_pending_delivery",
            "active_export_shot_missing_local_original_reexport_eligible",
            "required_issue_export_linkage_missing",
            "deleted_archived_or_inaccessible_property",
            "property_freshness_needs_review",
            "offline_or_unknown_freshness",
            "duplicate_shot_id_context",
            "historical_archive_debt",
            "supabase_storage_candidate_without_local_media",
            "pending_queue_not_target_session",
            "retired_guided_rows",
            "retired_or_historical_shots",
            "cross_session_issue_history_reference_resolved",
            "empty_remote_draft_shell",
            "remote_only_hydration_gap",
            "child_metadata_freshness_unknown",
            "web_portal_conflict_unresolved",
            "active_target_sync_parity_debt"
        ]))
        XCTAssertEqual(report.rows.count, 60)
    }

    func testEnforcementPolicyMissingSessionJSONEventualHardBlockerForExportAndSeal() throws {
        let report = AppState.makeEnforcementPolicyMatrixReport(inspectedAt: Date(timeIntervalSinceReferenceDate: 300))
        let seal = try XCTUnwrap(policyRow(report, "missing_or_unreadable_session_json", .sealComplete))
        let export = try XCTUnwrap(policyRow(report, "missing_or_unreadable_session_json", .firstExportDelivery))

        XCTAssertEqual(seal.eventualSeverity, .hardBlockCandidate)
        XCTAssertEqual(export.eventualSeverity, .hardBlockCandidate)
        XCTAssertEqual(seal.readiness, .readyForFutureGuardedEnforcement)
        XCTAssertEqual(export.readiness, .readyForFutureGuardedEnforcement)
    }

    func testEnforcementPolicyHistoricalArchiveDebtIsNeverBlock() {
        let report = AppState.makeEnforcementPolicyMatrixReport(inspectedAt: Date(timeIntervalSinceReferenceDate: 300))
        let rows = report.rows.filter { $0.conditionKey == "historical_archive_debt" }

        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(rows.allSatisfy { $0.eventualSeverity == .neverBlock })
        XCTAssertTrue(rows.allSatisfy { $0.readiness == .neverEnforce })
    }

    func testEnforcementPolicyDuplicateShotIDContextIsNotHardBlocker() {
        let report = AppState.makeEnforcementPolicyMatrixReport(inspectedAt: Date(timeIntervalSinceReferenceDate: 300))
        let rows = report.rows.filter { $0.conditionKey == "duplicate_shot_id_context" }

        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(rows.allSatisfy { $0.currentSeverity != .hardBlockCandidate })
        XCTAssertTrue(rows.allSatisfy { $0.eventualSeverity == .neverBlock })
        XCTAssertTrue(rows.allSatisfy { $0.readiness == .neverEnforce })
    }

    func testEnforcementPolicyNeedsReviewFreshnessDefersUntilWebPortalConflictRules() {
        let report = AppState.makeEnforcementPolicyMatrixReport(inspectedAt: Date(timeIntervalSinceReferenceDate: 300))
        let rows = report.rows.filter { $0.conditionKey == "property_freshness_needs_review" }

        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(rows.allSatisfy { $0.currentSeverity == .deferred })
        XCTAssertTrue(rows.allSatisfy { $0.readiness == .deferredUntilWebPortalConflictRules })
    }

    func testEnforcementPolicyRemoteOnlyHydrationGapDefersUntilRemoteHydration() {
        let report = AppState.makeEnforcementPolicyMatrixReport(inspectedAt: Date(timeIntervalSinceReferenceDate: 300))
        let rows = report.rows.filter { $0.conditionKey == "remote_only_hydration_gap" }

        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(rows.allSatisfy { $0.currentSeverity == .deferred })
        XCTAssertTrue(rows.allSatisfy { $0.eventualSeverity == .deferred })
        XCTAssertTrue(rows.allSatisfy { $0.readiness == .deferredUntilRemoteHydration })
    }

    func testEnforcementPolicyCopyableReportIncludesTechnicalIdentifiers() {
        let report = AppState.makeEnforcementPolicyMatrixReport(inspectedAt: Date(timeIntervalSinceReferenceDate: 300))
        let text = AppState.enforcementPolicyMatrixReportText(report)

        XCTAssertTrue(text.contains("ScoutCapture Local Health - Enforcement Policy Matrix"))
        XCTAssertTrue(text.contains("operation=seal_complete"))
        XCTAssertTrue(text.contains("condition_key=missing_or_unreadable_session_json"))
        XCTAssertTrue(text.contains("current_severity=hard_block_candidate"))
        XCTAssertTrue(text.contains("eventual_severity=hard_block_candidate"))
        XCTAssertTrue(text.contains("readiness=ready_for_future_guarded_enforcement"))
        XCTAssertTrue(text.contains("deferral_reason="))
        XCTAssertTrue(text.contains("notes="))
    }

    func testEnforcementPolicyVisibleLabelsAreOperatorReadable() throws {
        let report = AppState.makeEnforcementPolicyMatrixReport(inspectedAt: Date(timeIntervalSinceReferenceDate: 300))
        let row = try XCTUnwrap(policyRow(report, "property_freshness_needs_review", .firstExportDelivery))

        XCTAssertEqual(row.operation.title, "First Export / Delivery")
        XCTAssertEqual(row.friendlyTitle, "Property freshness needs review")
        XCTAssertEqual(row.currentSeverity.visibleLabel, "Deferred")
        XCTAssertEqual(row.eventualSeverity.visibleLabel, "Future Hard Block")
        XCTAssertEqual(row.readiness.visibleLabel, "Deferred until web portal conflict rules")
    }

    func testEnforcementPolicyReportRemainsReadOnlyAndNoBehaviorHooksAreAdded() {
        let report = AppState.makeEnforcementPolicyMatrixReport(inspectedAt: Date(timeIntervalSinceReferenceDate: 300))
        let text = AppState.enforcementPolicyMatrixReportText(report)

        XCTAssertTrue(text.contains("Read-only policy diagnostics"))
        XCTAssertTrue(text.contains("does not enforce gates"))
        XCTAssertTrue(text.contains("block export"))
        XCTAssertTrue(text.contains("block sealing"))
        XCTAssertFalse(text.contains("export button"))
        XCTAssertFalse(text.contains("seal button"))
    }

    private func diagnosticRow(
        entityType: String,
        entityID: UUID = UUID(),
        propertyID: UUID = UUID(),
        sessionID: UUID? = UUID(),
        shotID: UUID? = nil,
        state: AppState.CompletenessGateState = .localOnly,
        freshness: AppState.CompletenessFreshnessState = .unknown,
        rowScope: AppState.CompletenessDiagnosticRowScope = .childDetail,
        context: [String: String] = [:],
        reason: String
    ) -> AppState.CompletenessDiagnosticRow {
        AppState.CompletenessDiagnosticRow(
            id: UUID(),
            entityType: entityType,
            entityID: entityID,
            propertyID: propertyID,
            sessionID: sessionID,
            shotID: shotID,
            state: state,
            freshness: freshness,
            rowScope: rowScope,
            reason: reason,
            context: context
        )
    }

    private func makeSyntheticReport(
        freshnessCounts: [AppState.CompletenessFreshnessCount] = [
            .init(state: .current, count: 0),
            .init(state: .remoteUpdatesAvailable, count: 0),
            .init(state: .needsReview, count: 0),
            .init(state: .usingLocalCache, count: 0),
            .init(state: .offline, count: 0),
            .init(state: .unknown, count: 1)
        ],
        rows: [AppState.CompletenessDiagnosticRow]
    ) -> AppState.CompletenessGatesReport {
        let report = AppState.CompletenessGatesReport(
            inspectedAt: Date(timeIntervalSinceReferenceDate: 300),
            activeOrganizationID: UUID(),
            propertyCounts: [],
            sessionCounts: [],
            shotCounts: [],
            issueCounts: [],
            guidedCounts: [],
            mediaCounts: [],
            freshnessCounts: freshnessCounts,
            exportCompleteSessionCount: 0,
            notExportCompleteSessionCount: 1,
            diagnosticOnlyRows: rows
        )
        return report
    }

    private func preflightCategoryCount(
        _ category: AppState.ExportSealPreflightCategory,
        in report: AppState.ExportSealPreflightReport,
        scope: AppState.ExportSealPreflightScope
    ) -> Int {
        report.sections
            .first { $0.scope == scope }?
            .counts
            .first { $0.category == category }?
            .count ?? 0
    }

    private func preflightFindings(
        _ report: AppState.ExportSealPreflightReport,
        scope: AppState.ExportSealPreflightScope
    ) -> [AppState.ExportSealPreflightFinding] {
        report.sections.first { $0.scope == scope }?.findings ?? []
    }

    private func preflightSummaries(
        _ report: AppState.ExportSealPreflightReport,
        scope: AppState.ExportSealPreflightScope
    ) -> [AppState.ExportSealPreflightReasonSummary] {
        report.sections.first { $0.scope == scope }?.reasonSummaries ?? []
    }

    private func policyRow(
        _ report: AppState.EnforcementPolicyMatrixReport,
        _ conditionKey: String,
        _ operation: AppState.EnforcementPolicyOperation
    ) -> AppState.EnforcementPolicyMatrixRow? {
        report.rows.first {
            $0.conditionKey == conditionKey && $0.operation == operation
        }
    }
}

private extension JSONEncoder {
    static var iso8601Sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
