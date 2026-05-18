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
        isSealed: Bool = true
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
                isSealed: isSealed
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
            exportedAt: nil,
            isSealed: session.isSealed,
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
                reason: "/private/tmp/secret token abc https://example.test/file?signature=secret"
            )
        ])

        let text = AppState.completenessGatesReportText(report)

        XCTAssertFalse(text.contains("/private/tmp/secret"))
        XCTAssertFalse(text.contains("signature=secret"))
        XCTAssertTrue(text.contains("[path]"))
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
}

private extension JSONEncoder {
    static var iso8601Sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
