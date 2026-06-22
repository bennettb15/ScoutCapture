import XCTest
@testable import ScoutCapture

final class Phase2C26PFlaggedObservationReplayTests: XCTestCase {
    private let orgID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let propertyID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let sessionID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private let issueID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
    private let shotID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!

    private struct AppFixture {
        let appState: AppState
        let defaults: UserDefaults
        let suiteName: String
        let storageRoot: URL
    }

    @MainActor
    private func makeAppFixture() throws -> AppFixture {
        let suiteName = "Phase2C26PFlaggedObservationReplayTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(false, forKey: "supabase_enabled")
        defaults.set(false, forKey: "shadow_write_enabled")
        defaults.set(false, forKey: "supabase_read_enabled")
        defaults.set(false, forKey: "supabase_property_read_enabled")
        defaults.set(false, forKey: "media_supabase_upload_enabled")
        defaults.set(false, forKey: "sync_delta_enabled")

        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScoutCapture-2C26P-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        let appState = AppState(
            localStore: LocalStore(testStorageRootURL: storageRoot),
            userDefaults: defaults,
            disableCloudBackupForTests: true
        )
        return AppFixture(
            appState: appState,
            defaults: defaults,
            suiteName: suiteName,
            storageRoot: storageRoot
        )
    }

    @MainActor
    private func tearDownAppFixture(_ fixture: AppFixture) {
        fixture.appState.shutdown()
        fixture.defaults.removePersistentDomain(forName: fixture.suiteName)
        try? FileManager.default.removeItem(at: fixture.storageRoot)
    }

    private func metadata(
        orgID: UUID? = nil,
        propertyID: UUID? = nil,
        sessionID: UUID? = nil,
        issueStatus: String = "active",
        includeShot: Bool = true
    ) -> SessionMetadata {
        let targetPropertyID = propertyID ?? self.propertyID
        let targetSessionID = sessionID ?? self.sessionID
        let shot = ShotMetadata(
            shotID: shotID,
            propertyID: targetPropertyID,
            sessionID: targetSessionID,
            createdAt: Date(timeIntervalSinceReferenceDate: 10_100),
            updatedAt: Date(timeIntervalSinceReferenceDate: 10_200),
            building: "A",
            elevation: "North",
            detailType: "Door",
            angleIndex: 1,
            priority: "High",
            shotKey: "a|north|door|1",
            isGuided: false,
            isFlagged: true,
            issueID: issueID,
            issueStatus: issueStatus,
            captureKind: "captured",
            firstCaptureKind: "captured",
            noteText: "Door trim gap",
            noteCategory: nil,
            originalFilename: "door.jpg",
            originalRelativePath: "Originals/door.jpg",
            originalByteSize: 12,
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
        let issue = IssueMetadata(
            issueID: issueID,
            issueStatus: issueStatus,
            currentReason: "Door trim gap",
            firstSeenAt: Date(timeIntervalSinceReferenceDate: 10_100),
            lastSeenAt: Date(timeIntervalSinceReferenceDate: 10_250),
            lastCaptureSessionId: targetSessionID,
            detailNote: "Flagged observation should replay",
            shotKey: "a|north|door|1"
        )
        return SessionMetadata(
            schemaVersion: 1,
            propertyID: targetPropertyID,
            sessionID: targetSessionID,
            orgID: orgID ?? self.orgID,
            propertyNameAtCapture: "Replay Property",
            propertyNameAtExport: "Replay Property",
            startedAt: Date(timeIntervalSinceReferenceDate: 10_000),
            endedAt: Date(timeIntervalSinceReferenceDate: 10_600),
            status: .completed,
            isBaselineSession: false,
            exportedAt: nil,
            isSealed: true,
            appVersion: "test",
            deviceModel: "test",
            osVersion: "test",
            shots: includeShot ? [shot] : [],
            issues: [issue]
        )
    }

    private func remoteProperties(orgID: UUID? = nil) -> [AppState.CanonicalReadRemotePropertyRow] {
        [
            AppState.CanonicalReadRemotePropertyRow(
                id: propertyID,
                orgID: orgID ?? self.orgID,
                updatedAt: Date(timeIntervalSinceReferenceDate: 10_500),
                revision: 1,
                deletedAt: nil
            )
        ]
    }

    private func remoteSessions(
        orgID: UUID? = nil,
        propertyID: UUID? = nil,
        sessionID: UUID? = nil,
        updatedAt: Date? = Date(timeIntervalSinceReferenceDate: 10_600)
    ) -> [AppState.CanonicalReadRemoteSessionRow] {
        [
            AppState.CanonicalReadRemoteSessionRow(
                id: sessionID ?? self.sessionID,
                orgID: orgID ?? self.orgID,
                propertyID: propertyID ?? self.propertyID,
                status: "completed",
                updatedAt: updatedAt,
                revision: 1,
                deletedAt: nil
            )
        ]
    }

    private func replayPlan(
        metadata: SessionMetadata? = nil,
        remoteObservations: [AppState.CanonicalReadRemoteObservationRow] = []
    ) -> AppState.NormalizedObservationReplayPlan {
        AppState.makeNormalizedObservationReplayPlan(
            orgID: orgID,
            propertyID: propertyID,
            sessionID: sessionID,
            metadata: metadata ?? self.metadata(),
            remoteProperties: remoteProperties(),
            remoteSessions: remoteSessions(),
            remoteObservations: remoteObservations,
            updatedBy: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
        )
    }

    private func executeInsertOnlyReplay(
        plan: AppState.NormalizedObservationReplayPlan,
        startingRows: [AppState.CanonicalReadRemoteObservationRow]
    ) async -> (
        result: AppState.NormalizedBackfillEntityResult,
        remoteRows: [AppState.CanonicalReadRemoteObservationRow]
    ) {
        var remoteRows = startingRows
        let result = await AppState.executeNormalizedObservationReplayInsertOnlyTestOnly(
            plan: plan,
            targetClassification: .approvedStaging
        ) { rows in
            var insertedCount = 0
            var duplicateSkippedCount = 0
            var failedCount = 0
            var message = "observation_rows_inserted"

            for row in rows {
                if remoteRows.contains(where: { $0.id == row.id }) {
                    switch AppState.normalizedObservationInsertDuplicateResolution(
                        row: row,
                        remoteObservations: remoteRows
                    ) {
                    case .idempotentExisting:
                        duplicateSkippedCount += 1
                        message = "observation_duplicate_exact_scope_idempotent"
                    case .newerRemotePreserved:
                        duplicateSkippedCount += 1
                        message = "newer_remote_observations_preserved"
                    case .softDeletedPreserved:
                        duplicateSkippedCount += 1
                        message = "soft_deleted_remote_observations_preserved"
                    case .conflict(let reason):
                        failedCount += 1
                        message = reason
                    case .unavailable:
                        failedCount += 1
                        message = "remote_observation_duplicate_confirmation_missing"
                    }
                    continue
                }

                remoteRows.append(
                    AppState.CanonicalReadRemoteObservationRow(
                        id: row.id,
                        orgID: row.orgID,
                        propertyID: row.propertyID,
                        sessionID: row.sessionID,
                        updatedAt: row.updatedAt,
                        deletedAt: nil
                    )
                )
                insertedCount += 1
            }

            return AppState.NormalizedObservationReplayWriteSummary(
                insertedCount: insertedCount,
                duplicateSkippedCount: duplicateSkippedCount,
                failedCount: failedCount,
                message: message
            )
        }
        return (result, remoteRows)
    }

    func testFlaggedLocalObservationReplaysExactlyOneRemoteObservation() async {
        let plan = replayPlan()
        var remoteRows: [AppState.NormalizedObservationReplayRow] = []

        let result = await AppState.executeNormalizedObservationReplayTestOnly(
            plan: plan,
            targetClassification: .approvedProductionValidation
        ) { rows in
            remoteRows.append(contentsOf: rows)
            return rows.count
        }

        XCTAssertTrue(plan.allowed)
        XCTAssertEqual(plan.rowsToUpsert.count, 1)
        XCTAssertEqual(result.upsertedCount, 1)
        XCTAssertEqual(remoteRows.count, 1)
        XCTAssertEqual(remoteRows[0].id, issueID)
        XCTAssertEqual(remoteRows[0].orgID, orgID)
        XCTAssertEqual(remoteRows[0].propertyID, propertyID)
        XCTAssertEqual(remoteRows[0].sessionID, sessionID)
        XCTAssertEqual(remoteRows[0].shotID, shotID)
        XCTAssertEqual(remoteRows[0].category, "flagged_issue")
        XCTAssertEqual(remoteRows[0].status, "active")
    }

    func testInsertOnlyReplayHappyPathInsertsExactlyOneRow() async {
        let plan = replayPlan()

        let replay = await executeInsertOnlyReplay(plan: plan, startingRows: [])

        XCTAssertEqual(replay.result.upsertedCount, 1)
        XCTAssertEqual(replay.result.skippedCount, 0)
        XCTAssertEqual(replay.result.failedCount, 0)
        XCTAssertEqual(replay.result.message, "observation_rows_inserted")
        XCTAssertEqual(replay.remoteRows.count, 1)
        XCTAssertEqual(replay.remoteRows[0].id, issueID)
        XCTAssertEqual(replay.remoteRows[0].orgID, orgID)
        XCTAssertEqual(replay.remoteRows[0].propertyID, propertyID)
        XCTAssertEqual(replay.remoteRows[0].sessionID, sessionID)
    }

    @MainActor
    func testNilSupabaseClientDoesNotReportInsertedObservation() async throws {
        let fixture = try makeAppFixture()
        defer { tearDownAppFixture(fixture) }
        let plan = replayPlan()

        let result = await AppState.executeNormalizedObservationReplayInsertOnlyTestOnly(
            plan: plan,
            targetClassification: .localDev
        ) { rows in
            try await fixture.appState._debugInsertObservationRowsFailClosedForTests(rows)
        }

        XCTAssertEqual(result.upsertedCount, 0)
        XCTAssertEqual(result.skippedCount, 0)
        XCTAssertEqual(result.failedCount, 1)
        XCTAssertTrue(result.message.contains("Missing Supabase client"))
    }

    @MainActor
    func testInviteUserToOrganizationMissingClientDoesNotThrowObservationReplayError() async throws {
        let fixture = try makeAppFixture()
        defer { tearDownAppFixture(fixture) }

        do {
            try await fixture.appState.inviteUserToOrganization(
                email: "review@example.com",
                role: "member",
                orgID: orgID
            )
        } catch {
            let nsError = error as NSError
            XCTAssertNotEqual(nsError.domain, "ScoutCapture.ObservationReplay")
            throw error
        }
    }

    func testInsertOnlyDuplicateExactSessionResolvesIdempotentAfterConfirmation() async {
        let plan = replayPlan()
        let existing = AppState.CanonicalReadRemoteObservationRow(
            id: issueID,
            orgID: orgID,
            propertyID: propertyID,
            sessionID: sessionID,
            updatedAt: Date(timeIntervalSinceReferenceDate: 10_250),
            deletedAt: nil
        )

        let replay = await executeInsertOnlyReplay(plan: plan, startingRows: [existing])

        XCTAssertEqual(replay.result.upsertedCount, 0)
        XCTAssertEqual(replay.result.skippedCount, 1)
        XCTAssertEqual(replay.result.failedCount, 0)
        XCTAssertEqual(replay.result.message, "observation_duplicate_exact_scope_idempotent")
        XCTAssertEqual(replay.remoteRows, [existing])
    }

    func testInsertOnlyDuplicateWrongSessionDoesNotMoveOrUpdateExistingRow() async {
        let plan = replayPlan()
        let existingWrongSession = AppState.CanonicalReadRemoteObservationRow(
            id: issueID,
            orgID: orgID,
            propertyID: propertyID,
            sessionID: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!,
            updatedAt: Date(timeIntervalSinceReferenceDate: 10_250),
            deletedAt: nil
        )

        let replay = await executeInsertOnlyReplay(plan: plan, startingRows: [existingWrongSession])

        XCTAssertEqual(replay.result.upsertedCount, 0)
        XCTAssertEqual(replay.result.skippedCount, 0)
        XCTAssertEqual(replay.result.failedCount, 1)
        XCTAssertEqual(replay.result.message, "remote_observation_parent_mismatch")
        XCTAssertEqual(replay.remoteRows, [existingWrongSession])
    }

    func testInsertOnlyDuplicateWrongPropertyBlocksBeforeMutation() async {
        let plan = replayPlan()
        let existingWrongProperty = AppState.CanonicalReadRemoteObservationRow(
            id: issueID,
            orgID: orgID,
            propertyID: UUID(uuidString: "88888888-8888-8888-8888-888888888888")!,
            sessionID: sessionID,
            updatedAt: Date(timeIntervalSinceReferenceDate: 10_250),
            deletedAt: nil
        )

        let replay = await executeInsertOnlyReplay(plan: plan, startingRows: [existingWrongProperty])

        XCTAssertEqual(replay.result.upsertedCount, 0)
        XCTAssertEqual(replay.result.skippedCount, 0)
        XCTAssertEqual(replay.result.failedCount, 1)
        XCTAssertEqual(replay.result.message, "remote_observation_parent_mismatch")
        XCTAssertEqual(replay.remoteRows, [existingWrongProperty])
    }

    func testReplayIsIdempotentWhenRemoteObservationExists() async {
        let existing = AppState.CanonicalReadRemoteObservationRow(
            id: issueID,
            orgID: orgID,
            propertyID: propertyID,
            sessionID: sessionID,
            updatedAt: Date(timeIntervalSinceReferenceDate: 10_250),
            deletedAt: nil
        )
        let plan = replayPlan(remoteObservations: [existing])
        var operationCalled = false

        let result = await AppState.executeNormalizedObservationReplayTestOnly(
            plan: plan,
            targetClassification: .approvedStaging
        ) { rows in
            operationCalled = true
            return rows.count
        }

        XCTAssertTrue(plan.allowed)
        XCTAssertTrue(plan.rowsToUpsert.isEmpty)
        XCTAssertEqual(plan.existingSkippedCount, 1)
        XCTAssertFalse(operationCalled)
        XCTAssertEqual(result.upsertedCount, 0)
        XCTAssertEqual(result.skippedCount, 1)
    }

    func testWrongOrgPropertyOrSessionBlocksObservationReplay() {
        let wrongOrgPlan = AppState.makeNormalizedObservationReplayPlan(
            orgID: orgID,
            propertyID: propertyID,
            sessionID: sessionID,
            metadata: metadata(orgID: UUID(uuidString: "99999999-9999-9999-9999-999999999999")!),
            remoteProperties: remoteProperties(),
            remoteSessions: remoteSessions(),
            remoteObservations: []
        )
        let wrongPropertyParentPlan = AppState.makeNormalizedObservationReplayPlan(
            orgID: orgID,
            propertyID: propertyID,
            sessionID: sessionID,
            metadata: metadata(),
            remoteProperties: remoteProperties(),
            remoteSessions: remoteSessions(propertyID: UUID(uuidString: "88888888-8888-8888-8888-888888888888")!),
            remoteObservations: []
        )
        let wrongRemoteObservationParentPlan = replayPlan(
            remoteObservations: [
                AppState.CanonicalReadRemoteObservationRow(
                    id: issueID,
                    orgID: orgID,
                    sessionID: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!,
                    updatedAt: Date(timeIntervalSinceReferenceDate: 10_250),
                    deletedAt: nil
                )
            ]
        )

        XCTAssertFalse(wrongOrgPlan.allowed)
        XCTAssertEqual(wrongOrgPlan.blockedReason, "local_snapshot_parent_scope_mismatch")
        XCTAssertFalse(wrongPropertyParentPlan.allowed)
        XCTAssertEqual(wrongPropertyParentPlan.blockedReason, "remote_session_parent_not_verified")
        XCTAssertFalse(wrongRemoteObservationParentPlan.allowed)
        XCTAssertEqual(wrongRemoteObservationParentPlan.blockedReason, "remote_observation_parent_mismatch")
    }

    func testSameObservationIDWrongSessionDiscoveredByIDPreflightBlocksBeforeUpsert() async {
        let scopedPlan = replayPlan(remoteObservations: [])
        let wrongSessionPreflightRows = AppState.mergedObservationReplayPreflightRows(
            scopedSessionRows: [],
            idPreflightRows: [
                AppState.CanonicalReadRemoteObservationRow(
                    id: issueID,
                    orgID: orgID,
                    propertyID: propertyID,
                    sessionID: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!,
                    updatedAt: Date(timeIntervalSinceReferenceDate: 10_250),
                    deletedAt: nil
                )
            ]
        )
        let preflightPlan = AppState.makeNormalizedObservationReplayPlan(
            orgID: orgID,
            propertyID: propertyID,
            sessionID: sessionID,
            metadata: metadata(),
            remoteProperties: remoteProperties(),
            remoteSessions: remoteSessions(),
            remoteObservations: wrongSessionPreflightRows
        )
        var operationCalled = false

        let result = await AppState.executeNormalizedObservationReplayTestOnly(
            plan: preflightPlan,
            targetClassification: .approvedStaging
        ) { rows in
            operationCalled = true
            return rows.count
        }

        XCTAssertTrue(scopedPlan.allowed)
        XCTAssertEqual(scopedPlan.rowsToUpsert.count, 1)
        XCTAssertFalse(preflightPlan.allowed)
        XCTAssertEqual(preflightPlan.blockedReason, "remote_observation_parent_mismatch")
        XCTAssertFalse(operationCalled)
        XCTAssertEqual(result.upsertedCount, 0)
        XCTAssertEqual(result.failedCount, 1)
    }

    func testSameObservationIDWrongPropertyBlocksBeforeUpsert() async {
        let wrongPropertyPreflightRows = AppState.mergedObservationReplayPreflightRows(
            scopedSessionRows: [],
            idPreflightRows: [
                AppState.CanonicalReadRemoteObservationRow(
                    id: issueID,
                    orgID: orgID,
                    propertyID: UUID(uuidString: "88888888-8888-8888-8888-888888888888")!,
                    sessionID: sessionID,
                    updatedAt: Date(timeIntervalSinceReferenceDate: 10_250),
                    deletedAt: nil
                )
            ]
        )
        let preflightPlan = AppState.makeNormalizedObservationReplayPlan(
            orgID: orgID,
            propertyID: propertyID,
            sessionID: sessionID,
            metadata: metadata(),
            remoteProperties: remoteProperties(),
            remoteSessions: remoteSessions(),
            remoteObservations: wrongPropertyPreflightRows
        )
        var operationCalled = false

        let result = await AppState.executeNormalizedObservationReplayTestOnly(
            plan: preflightPlan,
            targetClassification: .approvedStaging
        ) { rows in
            operationCalled = true
            return rows.count
        }

        XCTAssertFalse(preflightPlan.allowed)
        XCTAssertEqual(preflightPlan.blockedReason, "remote_observation_parent_mismatch")
        XCTAssertFalse(operationCalled)
        XCTAssertEqual(result.upsertedCount, 0)
        XCTAssertEqual(result.failedCount, 1)
    }

    func testSoftDeletedExactSessionObservationIsSkippedNotUndeleted() async {
        let softDeletedRemote = AppState.CanonicalReadRemoteObservationRow(
            id: issueID,
            orgID: orgID,
            propertyID: propertyID,
            sessionID: sessionID,
            updatedAt: Date(timeIntervalSinceReferenceDate: 10_250),
            deletedAt: Date(timeIntervalSinceReferenceDate: 10_300)
        )
        let plan = replayPlan(remoteObservations: [softDeletedRemote])
        var operationCalled = false

        let result = await AppState.executeNormalizedObservationReplayTestOnly(
            plan: plan,
            targetClassification: .approvedStaging
        ) { rows in
            operationCalled = true
            return rows.count
        }

        XCTAssertTrue(plan.allowed)
        XCTAssertTrue(plan.rowsToUpsert.isEmpty)
        XCTAssertEqual(plan.softDeletedSkippedCount, 1)
        XCTAssertFalse(operationCalled)
        XCTAssertEqual(result.upsertedCount, 0)
        XCTAssertEqual(result.skippedCount, 1)
        XCTAssertEqual(result.message, "soft_deleted_remote_observations_preserved")
    }

    func testResolvedLocalIssueIsNotReplayed() async {
        let plan = replayPlan(metadata: metadata(issueStatus: "resolved"))
        var operationCalled = false

        let result = await AppState.executeNormalizedObservationReplayTestOnly(
            plan: plan,
            targetClassification: .approvedStaging
        ) { rows in
            operationCalled = true
            return rows.count
        }

        XCTAssertTrue(plan.allowed)
        XCTAssertEqual(plan.attemptedCount, 0)
        XCTAssertTrue(plan.rowsToUpsert.isEmpty)
        XCTAssertFalse(operationCalled)
        XCTAssertEqual(result.upsertedCount, 0)
    }

    func testNewerRemoteObservationIsPreservedAndSkipped() async {
        let newerRemote = AppState.CanonicalReadRemoteObservationRow(
            id: issueID,
            orgID: orgID,
            propertyID: propertyID,
            sessionID: sessionID,
            updatedAt: Date(timeIntervalSinceReferenceDate: 11_000),
            deletedAt: nil
        )
        let plan = replayPlan(remoteObservations: [newerRemote])
        var operationCalled = false

        let result = await AppState.executeNormalizedObservationReplayTestOnly(
            plan: plan,
            targetClassification: .approvedStaging
        ) { rows in
            operationCalled = true
            return rows.count
        }

        XCTAssertTrue(plan.allowed)
        XCTAssertTrue(plan.rowsToUpsert.isEmpty)
        XCTAssertEqual(plan.newerRemoteSkippedCount, 1)
        XCTAssertFalse(operationCalled)
        XCTAssertEqual(result.message, "newer_remote_observations_preserved")
    }

    func testCanonicalDiagnosticsAfterReplayCountsLocalAndRemoteObservationsEqually() {
        let local = AppState.CanonicalReadLocalSnapshot(
            propertyID: propertyID,
            orgID: orgID,
            sessionID: sessionID,
            sessionPropertyID: propertyID,
            sessionStatus: "completed",
            shotCount: 10,
            issueObservationCount: 1,
            guidedCount: 0,
            updatedAt: Date(timeIntervalSinceReferenceDate: 10_600),
            localKnownStateSource: "verified_snapshot_payload",
            localPropertyFound: true,
            localSessionFound: true
        )
        let remote = AppState.CanonicalReadRemoteSnapshot(
            properties: remoteProperties(),
            sessions: remoteSessions(),
            shots: (0..<10).map { _ in
                AppState.CanonicalReadRemoteShotRow(id: UUID(), sessionID: sessionID, deletedAt: nil)
            },
            observations: [
                AppState.CanonicalReadRemoteObservationRow(
                    id: issueID,
                    orgID: orgID,
                    sessionID: sessionID,
                    updatedAt: Date(timeIntervalSinceReferenceDate: 10_250),
                    deletedAt: nil
                )
            ]
        )

        let result = AppState.makeCanonicalReadDiagnostics(
            checkedAt: Date(timeIntervalSinceReferenceDate: 10_700),
            activeOrganizationID: orgID,
            local: local,
            remote: remote
        )

        XCTAssertEqual(result.localIssueObservationCount, 1)
        XCTAssertEqual(result.remoteIssueObservationCount, 1)
        XCTAssertEqual(result.countParity, true)
        XCTAssertEqual(result.result, .remoteMatchesLocal)
    }

    func testCandidateCanProceedPastMissingRemoteChildrenAfterObservationReplay() async {
        let before = canonicalDiagnostics(
            remoteObservationCount: 0,
            result: .divergentConflict,
            recommendation: "local_first_block_canonical_read",
            countParity: false
        )
        let beforeReport = AppState.makeNormalizedParityGapReport(canonicalDiagnostics: before)
        let beforeCandidate = AppState.makeCanonicalReadCandidateDiagnostics(
            configuration: AppState.CanonicalReadCandidateConfiguration(
                enabled: true,
                orgAllowlist: [orgID],
                propertyAllowlist: [propertyID],
                sessionAllowlist: [sessionID],
                parityCompletenessThreshold: 0.95,
                mediaRecoveryConfidenceThreshold: 0.95
            ),
            targetClassification: .approvedStaging,
            canonicalDiagnostics: before,
            parityReport: beforeReport
        )
        let replay = await AppState.executeNormalizedObservationReplayTestOnly(
            plan: replayPlan(),
            targetClassification: .approvedStaging
        ) { rows in rows.count }
        let after = canonicalDiagnostics(
            remoteObservationCount: 1,
            result: .remoteMatchesLocal,
            recommendation: "remote_candidate_after_replay_validation",
            countParity: true
        )
        let afterReport = AppState.makeNormalizedParityGapReport(canonicalDiagnostics: after)
        let validation = AppState.validateNormalizedBackfillReplay(
            before: before,
            after: after,
            execution: AppState.NormalizedBackfillReplayExecutionResult(
                allowed: true,
                blockedReason: nil,
                productionBlocked: false,
                attemptedEntityCount: replay.attemptedCount,
                executedEntityCount: replay.upsertedCount,
                skippedEntityCount: replay.skippedCount,
                failedEntityCount: replay.failedCount,
                remoteNewerConflictCount: 0,
                results: [replay],
                noBehaviorChangedText: "No behavior changed: observation replay validation does not switch canonical reads."
            )
        )
        let candidate = AppState.makeCanonicalReadCandidateDiagnostics(
            configuration: AppState.CanonicalReadCandidateConfiguration(
                enabled: true,
                orgAllowlist: [orgID],
                propertyAllowlist: [propertyID],
                sessionAllowlist: [sessionID],
                parityCompletenessThreshold: 0.95,
                mediaRecoveryConfidenceThreshold: 0.95
            ),
            targetClassification: .approvedStaging,
            canonicalDiagnostics: after,
            parityReport: afterReport,
            replayValidation: validation
        )

        XCTAssertEqual(beforeReport.missingChildCount, 1)
        XCTAssertTrue(beforeCandidate.blockedReason?.contains("missing_remote_children") == true)
        XCTAssertEqual(afterReport.missingChildCount, 0)
        XCTAssertFalse(afterReport.taxonomy.contains(.missingRemoteChildren))
        XCTAssertTrue(validation.remainingCanonicalBlockers.isEmpty)
        XCTAssertTrue(candidate.allowed)
        XCTAssertFalse(candidate.productionWideCanonicalReadsEnabled)
    }

    func testObservationReplayHasNoActivationReadSwitchOrUnrelatedMutationSideEffects() async {
        var unrelatedRows = [
            AppState.CanonicalReadRemoteObservationRow(
                id: UUID(),
                orgID: orgID,
                sessionID: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
                updatedAt: Date(timeIntervalSinceReferenceDate: 10_000),
                deletedAt: nil
            )
        ]
        let plan = replayPlan()
        let unrelatedBefore = unrelatedRows

        let result = await AppState.executeNormalizedObservationReplayTestOnly(
            plan: plan,
            targetClassification: .approvedProductionValidation
        ) { rows in
            unrelatedRows.append(contentsOf: rows.map {
                AppState.CanonicalReadRemoteObservationRow(
                    id: $0.id,
                    orgID: $0.orgID,
                    sessionID: $0.sessionID,
                    updatedAt: $0.updatedAt,
                    deletedAt: nil
                )
            })
            return rows.count
        }

        XCTAssertEqual(result.kind, .observation)
        XCTAssertEqual(result.upsertedCount, 1)
        XCTAssertEqual(unrelatedRows.first, unrelatedBefore.first)
        XCTAssertTrue(plan.noBehaviorChangedText.contains("does not write shots or media"))
        XCTAssertTrue(plan.noBehaviorChangedText.contains("switch canonical reads"))
        XCTAssertTrue(plan.noBehaviorChangedText.contains("activate candidates"))
    }

    private func canonicalDiagnostics(
        remoteObservationCount: Int,
        result: AppState.CanonicalReadDiagnosticResult,
        recommendation: String,
        countParity: Bool
    ) -> AppState.CanonicalReadDiagnosticsResult {
        AppState.CanonicalReadDiagnosticsResult(
            checkedAt: Date(timeIntervalSinceReferenceDate: 12_000),
            propertyID: propertyID,
            sessionID: sessionID,
            activeOrganizationID: orgID,
            result: result,
            remotePropertyFound: true,
            remoteSessionFound: true,
            localPropertyFound: true,
            localSessionFound: true,
            countParity: countParity,
            statusParity: true,
            parentOrgConsistent: true,
            parentPropertyConsistent: true,
            localShotCount: 10,
            remoteShotCount: 10,
            localIssueObservationCount: 1,
            remoteIssueObservationCount: remoteObservationCount,
            localGuidedCount: 0,
            remoteGuidedCount: nil,
            localUpdatedAt: Date(timeIntervalSinceReferenceDate: 11_900),
            remoteUpdatedAt: Date(timeIntervalSinceReferenceDate: 11_900),
            remoteRevision: 1,
            remoteFreshnessAgeSeconds: 100,
            canonicalRecommendation: recommendation,
            blockedReason: result == .divergentConflict ? "remote_rows_diverge_from_local_counts_or_status" : nil,
            noBehaviorChangedText: "read only"
        )
    }
}
