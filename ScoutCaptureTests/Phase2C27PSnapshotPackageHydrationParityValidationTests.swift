import XCTest
import CryptoKit
@testable import ScoutCapture

@MainActor
final class Phase2C27PSnapshotPackageHydrationParityValidationTests: XCTestCase {
    private struct PackageFixture {
        let suiteName: String
        let defaults: UserDefaults
        let storageRoot: URL
        let store: LocalStore
        let appState: AppState
        let orgID: UUID
        let property: Property
        let session: Session
        let snapshotID: UUID
        let row: AppState.SessionSnapshotUploadRow
        let object: AppState.SessionSnapshotStorageObject
        let sourceMetadata: SessionMetadata
        let mediaByPath: [String: Data]
    }

    private struct PackageEvidence {
        let fixture: PackageFixture
        let restore: AppState.SessionSnapshotRestoreDiagnosticsResult
        let hydration: AppState.SessionSnapshotHydrationResult
        let hydratedMetadata: SessionMetadata
        let mediaRetrieval: AppState.SessionSnapshotMediaRetrievalResult
        let mediaRestoration: AppState.ProductionSingleSessionMediaRestorationRehearsal
        let mediaRollback: AppState.ProductionSingleSessionMediaRestorationRollback
        let candidate: AppState.CanonicalReadCandidateDiagnostics
        let overlay: AppState.CanonicalCandidateOverlayBuildResult
        let comparison: AppState.CanonicalCandidateOverlayComparison
    }

    private struct FullyRestoredRollbackEvidence {
        let package: PackageEvidence
        let preHydrationFixtureFingerprint: String
        let restoredFixtureFingerprint: String
        let recoveredMediaArtifactsRemoved: Bool
        let packageCandidateArtifactsRemoved: Bool
        let originalSentinelPreservedDuringRestoration: Bool
        let validation: AppState.ProductionSingleSessionFullyRestoredPackageRollbackValidation
    }

    private func makeTempStorageRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScoutCapture-2C27P-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeDefaults() -> (suiteName: String, defaults: UserDefaults) {
        let suiteName = "ScoutCapture-2C27P-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(false, forKey: "supabase_enabled")
        defaults.set(false, forKey: "supabase_read_enabled")
        defaults.set(false, forKey: "supabase_property_read_enabled")
        defaults.set(false, forKey: "media_supabase_upload_enabled")
        defaults.set(false, forKey: "sync_delta_enabled")
        defaults.set(true, forKey: "session_snapshot_shadow_write_enabled")
        return (suiteName, defaults)
    }

    private func localEnvironment(
        orgID: UUID,
        propertyID: UUID,
        sessionID: UUID
    ) -> [String: String] {
        [
            "SCOUTCAPTURE_SUPABASE_URL": "http://127.0.0.1:54321",
            "SCOUTCAPTURE_SUPABASE_ANON_KEY": "local-anon-key",
            SupabaseRuntimeConfiguration.canonicalReadCandidateEnabledEnvKey: "true",
            SupabaseRuntimeConfiguration.canonicalReadCandidateOrgAllowlistEnvKey: orgID.uuidString,
            SupabaseRuntimeConfiguration.canonicalReadCandidatePropertyAllowlistEnvKey: propertyID.uuidString,
            SupabaseRuntimeConfiguration.canonicalReadCandidateSessionAllowlistEnvKey: sessionID.uuidString
        ]
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func makePackageFixture() throws -> PackageFixture {
        let defaultsFixture = makeDefaults()
        let root = try makeTempStorageRoot()
        let store = LocalStore(testStorageRootURL: root)
        let orgID = UUID()
        _ = try store.createOrganization(Organization(id: orgID, name: "27P Package Org"))
        let property = try store.createProperty(Property(id: UUID(), orgId: orgID, name: "27P Package Property"))
        let session = try store.upsertSession(Session(
            id: UUID(),
            propertyID: property.id,
            startedAt: Date(timeIntervalSinceReferenceDate: 30_000),
            status: .completed,
            endedAt: Date(timeIntervalSinceReferenceDate: 30_600),
            exportedAt: nil,
            isSealed: true,
            firstDeliveredAt: nil,
            reExportExpiresAt: nil
        ))
        let firstMedia = Data("phase-2c-27p-first-media".utf8)
        let secondMedia = Data("phase-2c-27p-second-media".utf8)
        let firstShotID = UUID()
        let secondShotID = UUID()
        let issueID = UUID()
        let shots = [
            makeShot(
                id: firstShotID,
                propertyID: property.id,
                sessionID: session.id,
                filename: "phase-2c-27p-first.jpg",
                checksum: sha256Hex(firstMedia),
                byteSize: firstMedia.count,
                issueID: issueID
            ),
            makeShot(
                id: secondShotID,
                propertyID: property.id,
                sessionID: session.id,
                filename: "phase-2c-27p-second.jpg",
                checksum: sha256Hex(secondMedia),
                byteSize: secondMedia.count,
                issueID: nil
            )
        ]
        let issue = IssueMetadata(
            issueID: issueID,
            issueStatus: "active",
            currentReason: "27P package parity issue",
            firstSeenAt: Date(timeIntervalSinceReferenceDate: 30_100),
            lastSeenAt: Date(timeIntervalSinceReferenceDate: 30_200),
            lastCaptureSessionId: session.id,
            detailNote: "Real package parity validation",
            shotKey: shots[0].shotKey
        )
        let guided = GuidedShot(
            title: "27P guided checkpoint",
            building: "A",
            targetElevation: "North",
            detailType: "Overview",
            angleIndex: 1,
            referenceImagePath: nil,
            shot: Shot(id: firstShotID, capturedAt: shots[0].createdAt),
            isCompleted: true
        )
        let sourceMetadata = SessionMetadata(
            schemaVersion: 12,
            propertyID: property.id,
            sessionID: session.id,
            orgID: orgID,
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
            issues: [issue],
            guidedShots: [guided]
        )
        try store.saveSessionMetadataAtomically(propertyID: property.id, sessionID: session.id, metadata: sourceMetadata)

        let environment = localEnvironment(orgID: orgID, propertyID: property.id, sessionID: session.id)
        let artifactAppState = AppState(
            localStore: store,
            userDefaults: makeDefaults().defaults,
            environment: environment,
            disableCloudBackupForTests: true
        )
        let snapshotID = UUID()
        let artifacts = try artifactAppState._debugMakeSessionSnapshotUploadArtifactsForTests(
            propertyID: property.id,
            sessionID: session.id,
            snapshotID: snapshotID,
            trigger: "phase_2c_27p_real_snapshot_package_fixture",
            generatedAt: Date(timeIntervalSinceReferenceDate: 30_700)
        )
        let mediaByPath = [
            shots[0].storagePath!: firstMedia,
            shots[1].storagePath!: secondMedia
        ]
        try store.deleteSession(id: session.id, propertyID: property.id)

        let row = artifacts.row
        let object = artifacts.object
        let appState = AppState(
            localStore: store,
            userDefaults: defaultsFixture.defaults,
            environment: environment,
            sessionSnapshotStorageUploadOverride: { _ in
                XCTFail("27P package validation must not upload session snapshots")
            },
            sessionSnapshotRowInsertOverride: { _ in
                XCTFail("27P package validation must not insert session snapshot rows")
            },
            sessionSnapshotRowsFetchOverride: { _, _, _ in [row] },
            sessionSnapshotStorageDownloadOverride: { _, _ in object.payloadData },
            sessionSnapshotMediaDownloadOverride: { _, path in
                guard let data = mediaByPath[path] else {
                    throw NSError(domain: "Phase2C27P", code: 1, userInfo: [NSLocalizedDescriptionKey: "media_payload_unavailable"])
                }
                return data
            },
            sessionSnapshotRemoteParentPreflightOverride: { _, _, _ in
                AppState.SessionSnapshotAuthPreflightRemoteParentStatus(
                    propertyExists: true,
                    sessionExists: true,
                    propertyOrgID: orgID,
                    sessionOrgID: orgID,
                    sessionPropertyIDMatches: true,
                    orgIDsMatch: true,
                    errorMessage: nil
                )
            },
            disableCloudBackupForTests: true
        )
        appState._debugSetOrganizationContextForTests(
            memberships: [ActiveOrganizationMembership(id: orgID, name: "27P Package Org", role: "owner")],
            activeOrganizationID: orgID,
            ready: true
        )
        appState.selectedPropertyID = property.id
        appState.currentSession = session

        return PackageFixture(
            suiteName: defaultsFixture.suiteName,
            defaults: defaultsFixture.defaults,
            storageRoot: root,
            store: store,
            appState: appState,
            orgID: orgID,
            property: property,
            session: session,
            snapshotID: snapshotID,
            row: row,
            object: object,
            sourceMetadata: sourceMetadata,
            mediaByPath: mediaByPath
        )
    }

    private func tearDownFixture(_ fixture: PackageFixture) {
        fixture.appState.shutdown()
        fixture.defaults.removePersistentDomain(forName: fixture.suiteName)
        try? FileManager.default.removeItem(at: fixture.storageRoot)
    }

    private func makeShot(
        id: UUID,
        propertyID: UUID,
        sessionID: UUID,
        filename: String,
        checksum: String,
        byteSize: Int,
        issueID: UUID?
    ) -> ShotMetadata {
        ShotMetadata(
            shotID: id,
            propertyID: propertyID,
            sessionID: sessionID,
            createdAt: Date(timeIntervalSinceReferenceDate: 30_100),
            updatedAt: Date(timeIntervalSinceReferenceDate: 30_200),
            building: "A",
            elevation: "North",
            detailType: filename,
            angleIndex: 1,
            shotKey: "a-north-\(filename)-1",
            isGuided: issueID != nil,
            isFlagged: issueID != nil,
            issueID: issueID,
            issueStatus: issueID == nil ? nil : "active",
            noteText: nil,
            noteCategory: nil,
            originalFilename: filename,
            originalRelativePath: "",
            originalByteSize: byteSize,
            storageBucket: "scoutcapture-originals",
            storagePath: "phase-2c-27p/\(sessionID.uuidString.lowercased())/\(filename)",
            checksumSHA256: checksum,
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

    private func makeHydrationRehearsal(
        scope: AppState.ProductionCohortApprovalScope,
        restore: AppState.SessionSnapshotRestoreDiagnosticsResult,
        hydratedMetadata: SessionMetadata
    ) -> AppState.ProductionSingleSessionHydrationExecutionRehearsal {
        AppState.ProductionSingleSessionHydrationExecutionRehearsal(
            checkedAt: Date(timeIntervalSinceReferenceDate: 31_100),
            state: .testOnlyHydrationRehearsalPassed,
            blockers: [],
            blockedConditions: [
                "test_only_fixture_hydration_only",
                "production_reads_blocked",
                "remote_state_writes_blocked",
                "real_local_user_state_writes_blocked",
                "fallback_retained"
            ],
            hydrationReadinessScope: scope,
            restoreDiagnosticsScope: scope,
            preHydrationFixtureScope: scope,
            hydrationOperationScope: scope,
            postHydrationFixtureScope: scope,
            rollbackOperationScope: scope,
            restoredFixtureScope: scope,
            hydrationReadinessReviewOnly: true,
            exactSingleScopeSelected: true,
            scopesMatch: true,
            productionHydrationDisabled: true,
            executionTargetIsLocalTestFixture: true,
            productionTargetBlocked: true,
            productionReadsBlocked: true,
            remoteStateWritesBlocked: true,
            realLocalUserStateWritesBlocked: true,
            hydrationOperationSucceeded: true,
            postHydrationMatchesSnapshotEvidence: hydratedMetadata.shots.count == restore.snapshotShotCount &&
                hydratedMetadata.issues.count == restore.snapshotIssueCount &&
                hydratedMetadata.guidedShots.count == restore.snapshotGuidedCount,
            rollbackOperationSucceeded: true,
            rollbackRestoredPreHydrationFixture: true,
            fallbackRetained: true,
            noProductionBehaviorChangedText: "test-only 27P hydration rehearsal evidence"
        )
    }

    private func makeMediaRestorationItems(
        fixture: PackageFixture,
        hydratedMetadata: SessionMetadata,
        snapshotID: UUID
    ) throws -> [AppState.ProductionSingleSessionMediaRestorationItem] {
        let recoveredDirectory = fixture.appState.sessionSnapshotRecoveredMediaDirectoryURLForDiagnostics(
            propertyID: fixture.property.id,
            sessionID: fixture.session.id,
            snapshotID: snapshotID
        )
        return hydratedMetadata.shots.map { shot in
            let url = recoveredDirectory.appendingPathComponent(shot.originalFilename, isDirectory: false)
            return AppState.ProductionSingleSessionMediaRestorationItem(
                id: shot.shotID,
                originalFilename: shot.originalFilename,
                payloadData: try? Data(contentsOf: url),
                expectedChecksumSHA256: shot.checksumSHA256,
                failureReason: FileManager.default.fileExists(atPath: url.path) ? nil : "media_payload_unavailable"
            )
        }
    }

    private func fixtureFingerprint(_ fixture: PackageFixture) throws -> String {
        let sessions = try fixture.store.fetchSessions(propertyID: fixture.property.id)
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .map { session in
                [
                    session.id.uuidString,
                    session.propertyID.uuidString,
                    session.status.rawValue,
                    String(session.isSealed)
                ].joined(separator: ":")
            }
        let sessionRoot = fixture.store.sessionFolderURL(
            propertyID: fixture.property.id,
            sessionID: fixture.session.id
        )
        var lines = ["sessions:\(sessions.joined(separator: ","))"]
        if FileManager.default.fileExists(atPath: sessionRoot.path) {
            lines.append("session_root:present")
            let relativePaths = ((try? FileManager.default.subpathsOfDirectory(atPath: sessionRoot.path)) ?? [])
                .sorted()
            for relativePath in relativePaths {
                let url = sessionRoot.appendingPathComponent(relativePath, isDirectory: false)
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                      !isDirectory.boolValue,
                      let data = try? Data(contentsOf: url) else {
                    continue
                }
                lines.append("\(relativePath):\(sha256Hex(data))")
            }
        } else {
            lines.append("session_root:missing")
        }
        return sha256Hex(Data(lines.joined(separator: "\n").utf8))
    }

    private func scope(for fixture: PackageFixture) -> AppState.ProductionCohortApprovalScope {
        AppState.ProductionCohortApprovalScope(
            orgID: fixture.orgID,
            propertyID: fixture.property.id,
            sessionID: fixture.session.id
        )
    }

    private func makeCandidateEvidence(
        fixture: PackageFixture,
        hydratedMetadata: SessionMetadata
    ) -> (
        candidate: AppState.CanonicalReadCandidateDiagnostics,
        overlay: AppState.CanonicalCandidateOverlayBuildResult,
        comparison: AppState.CanonicalCandidateOverlayComparison
    ) {
        let canonicalDiagnostics = AppState.CanonicalReadDiagnosticsResult(
            checkedAt: Date(timeIntervalSinceReferenceDate: 31_200),
            propertyID: fixture.property.id,
            sessionID: fixture.session.id,
            activeOrganizationID: fixture.orgID,
            result: .remoteMatchesLocal,
            remotePropertyFound: true,
            remoteSessionFound: true,
            localPropertyFound: true,
            localSessionFound: true,
            countParity: true,
            statusParity: true,
            parentOrgConsistent: true,
            parentPropertyConsistent: true,
            localShotCount: hydratedMetadata.shots.count,
            remoteShotCount: hydratedMetadata.shots.count,
            localIssueObservationCount: hydratedMetadata.issues.count,
            remoteIssueObservationCount: hydratedMetadata.issues.count,
            localGuidedCount: hydratedMetadata.guidedShots.count,
            remoteGuidedCount: hydratedMetadata.guidedShots.count,
            localUpdatedAt: hydratedMetadata.endedAt ?? hydratedMetadata.startedAt,
            remoteUpdatedAt: hydratedMetadata.endedAt ?? hydratedMetadata.startedAt,
            remoteRevision: 27,
            remoteFreshnessAgeSeconds: 0,
            canonicalRecommendation: "remote_candidate_after_replay_validation",
            blockedReason: nil,
            noBehaviorChangedText: "read only"
        )
        let parityReport = AppState.makeNormalizedParityGapReport(canonicalDiagnostics: canonicalDiagnostics)
        let configuration = AppState.CanonicalReadCandidateConfiguration(
            enabled: true,
            orgAllowlist: [fixture.orgID],
            propertyAllowlist: [fixture.property.id],
            sessionAllowlist: [fixture.session.id],
            parityCompletenessThreshold: 0.95,
            mediaRecoveryConfidenceThreshold: 0.95
        )
        let candidate = AppState.makeCanonicalReadCandidateDiagnostics(
            checkedAt: Date(timeIntervalSinceReferenceDate: 31_300),
            configuration: configuration,
            targetClassification: .localDev,
            canonicalDiagnostics: canonicalDiagnostics,
            parityReport: parityReport,
            mediaRecoveryConfidence: 1
        )
        let overlay = AppState.buildCanonicalCandidateOverlayTestOnly(
            checkedAt: Date(timeIntervalSinceReferenceDate: 31_400),
            targetClassification: .localDev,
            canonicalDiagnostics: canonicalDiagnostics,
            parityReport: parityReport,
            candidateDiagnostics: candidate
        )
        let comparison = AppState.makeCanonicalCandidateOverlayComparison(
            checkedAt: Date(timeIntervalSinceReferenceDate: 31_500),
            canonicalDiagnostics: canonicalDiagnostics,
            overlayResult: overlay,
            parityReport: parityReport,
            localSessionStatus: hydratedMetadata.status.rawValue,
            remoteCandidateSessionStatus: hydratedMetadata.status.rawValue
        )
        return (candidate, overlay, comparison)
    }

    private func makePackageEvidence() async throws -> PackageEvidence {
        let fixture = try makePackageFixture()
        let restore = await fixture.appState.validateLatestSessionSnapshotRestoreDiagnostics()
        let hydration = await fixture.appState.hydrateMetadataFromLatestSessionSnapshot()
        let hydratedMetadata = try fixture.store.loadSessionMetadata(
            propertyID: fixture.property.id,
            sessionID: fixture.session.id
        )
        let mediaRetrieval = await fixture.appState.retrieveSnapshotMediaTestOnly()
        let scope = AppState.ProductionCohortApprovalScope(
            orgID: fixture.orgID,
            propertyID: fixture.property.id,
            sessionID: fixture.session.id
        )
        let mediaItems = try makeMediaRestorationItems(
            fixture: fixture,
            hydratedMetadata: hydratedMetadata,
            snapshotID: fixture.snapshotID
        )
        let mediaRestoration = fixture.appState.rehearseProductionSingleSessionMediaRestorationForTests(
            hydrationRehearsal: makeHydrationRehearsal(
                scope: scope,
                restore: restore,
                hydratedMetadata: hydratedMetadata
            ),
            candidateID: UUID(),
            mediaItems: mediaItems,
            targetClassification: .localDev
        )
        let mediaRollback = fixture.appState.rollbackProductionSingleSessionMediaRestorationRehearsalForTests(
            rehearsal: mediaRestoration
        )
        let candidateEvidence = makeCandidateEvidence(fixture: fixture, hydratedMetadata: hydratedMetadata)
        return PackageEvidence(
            fixture: fixture,
            restore: restore,
            hydration: hydration,
            hydratedMetadata: hydratedMetadata,
            mediaRetrieval: mediaRetrieval,
            mediaRestoration: mediaRestoration,
            mediaRollback: mediaRollback,
            candidate: candidateEvidence.candidate,
            overlay: candidateEvidence.overlay,
            comparison: candidateEvidence.comparison
        )
    }

    private func makeFullyRestoredRollbackEvidence() async throws -> FullyRestoredRollbackEvidence {
        let fixture = try makePackageFixture()
        let preHydrationFingerprint = try fixtureFingerprint(fixture)
        let restore = await fixture.appState.validateLatestSessionSnapshotRestoreDiagnostics()
        let hydration = await fixture.appState.hydrateMetadataFromLatestSessionSnapshot()
        let hydratedMetadata = try fixture.store.loadSessionMetadata(
            propertyID: fixture.property.id,
            sessionID: fixture.session.id
        )
        let originalSentinelData = Data("phase-2c-27q-pre-existing-original".utf8)
        let originalSentinelURL = fixture.store
            .originalsFolderURL(propertyID: fixture.property.id, sessionID: fixture.session.id)
            .appendingPathComponent("phase-2c-27q-existing-original.jpg", isDirectory: false)
        try FileManager.default.createDirectory(
            at: originalSentinelURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try originalSentinelData.write(to: originalSentinelURL, options: .atomic)

        let mediaRetrieval = await fixture.appState.retrieveSnapshotMediaTestOnly()
        let mediaItems = try makeMediaRestorationItems(
            fixture: fixture,
            hydratedMetadata: hydratedMetadata,
            snapshotID: fixture.snapshotID
        )
        let mediaRestoration = fixture.appState.rehearseProductionSingleSessionMediaRestorationForTests(
            hydrationRehearsal: makeHydrationRehearsal(
                scope: scope(for: fixture),
                restore: restore,
                hydratedMetadata: hydratedMetadata
            ),
            candidateID: UUID(),
            mediaItems: mediaItems,
            targetClassification: .localDev
        )
        let originalSentinelPreserved = (try? Data(contentsOf: originalSentinelURL)) == originalSentinelData
        let mediaRollback = fixture.appState.rollbackProductionSingleSessionMediaRestorationRehearsalForTests(
            rehearsal: mediaRestoration
        )
        try fixture.store.deleteSession(id: fixture.session.id, propertyID: fixture.property.id)

        let restoredFingerprint = try fixtureFingerprint(fixture)
        let recoveredMediaDirectory = fixture.appState.sessionSnapshotRecoveredMediaDirectoryURLForDiagnostics(
            propertyID: fixture.property.id,
            sessionID: fixture.session.id,
            snapshotID: fixture.snapshotID
        )
        let recoveredRemoved = !FileManager.default.fileExists(atPath: recoveredMediaDirectory.path)
        let candidateRemoved = mediaRestoration.candidateDirectoryPath.map {
            !FileManager.default.fileExists(atPath: $0)
        } ?? false
        let candidateEvidence = makeCandidateEvidence(fixture: fixture, hydratedMetadata: hydratedMetadata)
        let package = PackageEvidence(
            fixture: fixture,
            restore: restore,
            hydration: hydration,
            hydratedMetadata: hydratedMetadata,
            mediaRetrieval: mediaRetrieval,
            mediaRestoration: mediaRestoration,
            mediaRollback: mediaRollback,
            candidate: candidateEvidence.candidate,
            overlay: candidateEvidence.overlay,
            comparison: candidateEvidence.comparison
        )
        let validation = AppState.makeProductionSingleSessionFullyRestoredPackageRollbackValidation(
            targetScope: scope(for: fixture),
            restoreDiagnostics: restore,
            hydration: hydration,
            mediaRetrieval: mediaRetrieval,
            mediaRestoration: mediaRestoration,
            mediaRollback: mediaRollback,
            preHydrationFixtureFingerprint: preHydrationFingerprint,
            restoredFixtureFingerprint: restoredFingerprint,
            generatedRecoveredMediaArtifactsRemoved: recoveredRemoved,
            generatedPackageCandidateArtifactsRemoved: candidateRemoved,
            originalsPreserved: originalSentinelPreserved
        )
        return FullyRestoredRollbackEvidence(
            package: package,
            preHydrationFixtureFingerprint: preHydrationFingerprint,
            restoredFixtureFingerprint: restoredFingerprint,
            recoveredMediaArtifactsRemoved: recoveredRemoved,
            packageCandidateArtifactsRemoved: candidateRemoved,
            originalSentinelPreservedDuringRestoration: originalSentinelPreserved,
            validation: validation
        )
    }

    private func validate(_ evidence: PackageEvidence) -> AppState.ProductionSingleSessionSnapshotPackageParityValidation {
        AppState.makeProductionSingleSessionSnapshotPackageHydrationParityValidation(
            targetScope: AppState.ProductionCohortApprovalScope(
                orgID: evidence.fixture.orgID,
                propertyID: evidence.fixture.property.id,
                sessionID: evidence.fixture.session.id
            ),
            restoreDiagnostics: evidence.restore,
            hydration: evidence.hydration,
            hydratedMetadata: evidence.hydratedMetadata,
            snapshotShotIDs: Set(evidence.fixture.sourceMetadata.shots.map(\.shotID)),
            snapshotIssueIDs: Set(evidence.fixture.sourceMetadata.issues.map(\.issueID)),
            snapshotGuidedIDs: Set(evidence.fixture.sourceMetadata.guidedShots.map(\.id)),
            mediaRetrieval: evidence.mediaRetrieval,
            mediaRestoration: evidence.mediaRestoration,
            mediaRollback: evidence.mediaRollback,
            candidateDiagnostics: evidence.candidate,
            overlayResult: evidence.overlay,
            overlayComparison: evidence.comparison
        )
    }

    func testRealSnapshotPackageHydrationParityPositivePath() async throws {
        let evidence = try await makePackageEvidence()
        defer { tearDownFixture(evidence.fixture) }

        let validation = validate(evidence)

        XCTAssertEqual(evidence.restore.result, .restorableMetadataCandidate)
        XCTAssertTrue(evidence.restore.checksumVerified)
        XCTAssertTrue(evidence.restore.rowObjectVerified)
        XCTAssertTrue(evidence.restore.parentRemoteVerified)
        XCTAssertEqual(evidence.restore.snapshotSchemaVersion, 1)
        XCTAssertNotEqual(evidence.restore.freshness, "local_newer")
        XCTAssertTrue(evidence.hydration.allowed)
        XCTAssertEqual(evidence.hydratedMetadata.shots.count, evidence.fixture.sourceMetadata.shots.count)
        XCTAssertEqual(evidence.hydratedMetadata.issues.count, evidence.fixture.sourceMetadata.issues.count)
        XCTAssertEqual(evidence.hydratedMetadata.guidedShots.count, evidence.fixture.sourceMetadata.guidedShots.count)
        XCTAssertTrue(evidence.mediaRetrieval.allowed)
        XCTAssertEqual(evidence.mediaRetrieval.downloadedCount, evidence.fixture.sourceMetadata.shots.count)
        XCTAssertEqual(evidence.mediaRetrieval.failedCount, 0)
        XCTAssertEqual(evidence.mediaRestoration.state, .testOnlyMediaRestorationRehearsalPassed)
        XCTAssertEqual(evidence.mediaRestoration.acceptedCandidateMediaCount, evidence.fixture.sourceMetadata.shots.count)
        XCTAssertTrue(evidence.mediaRestoration.existingOriginalsPreserved)
        XCTAssertEqual(evidence.mediaRollback.state, .restoredPreRestorationFixture)
        XCTAssertEqual(validation.state, .testOnlyPackageParityPassed)
        XCTAssertTrue(validation.blockers.isEmpty)
        XCTAssertTrue(validation.fallbackRetained)
        XCTAssertTrue(validation.activeSourceRemainsLocal)
        XCTAssertTrue(validation.productionReadsBlocked)
        XCTAssertTrue(validation.remoteStateWritesBlocked)
        XCTAssertTrue(validation.realLocalUserStateWritesBlocked)
        XCTAssertTrue(validation.originalsOverwriteBlocked)
        XCTAssertTrue(validation.rollbackCleanupVerified)

        let report = AppState.productionSingleSessionSnapshotPackageHydrationParityValidationReportText(validation)
        XCTAssertTrue(report.contains("Production Single-Session Snapshot Package Hydration Parity Validation"))
        XCTAssertTrue(report.contains("- package_parity_state: test_only_package_parity_passed"))
        XCTAssertTrue(report.contains("No production behavior changed"))
    }

    func testLocalHealthOperatorPackageValidationProducesCopyableReports() async throws {
        let fixture = try makePackageFixture()
        defer { tearDownFixture(fixture) }

        let report = await fixture.appState.runLocalHealthSelectedSessionSnapshotPackageValidation()

        XCTAssertEqual(AppState.localHealthSessionSnapshotPackageValidationActionTitle, "Run Package Parity / Rollback Validation")
        XCTAssertEqual(report.snapshotID, fixture.snapshotID)
        XCTAssertEqual(report.packageParity.state, .testOnlyPackageParityPassed)
        XCTAssertEqual(report.fullyRestoredRollback.state, .testOnlyFullyRestoredPackageRollbackPassed)
        XCTAssertTrue(report.packageParity.blockers.isEmpty)
        XCTAssertTrue(report.fullyRestoredRollback.blockers.isEmpty)
        XCTAssertTrue(report.packageParityReportText.contains("Production Single-Session Snapshot Package Hydration Parity Validation"))
        XCTAssertTrue(report.fullyRestoredRollbackReportText.contains("Production Single-Session Fully Restored Package Rollback Validation"))
        XCTAssertTrue(report.combinedReportText.contains("- package_parity_state: test_only_package_parity_passed"))
        XCTAssertTrue(report.combinedReportText.contains("- package_rollback_state: test_only_fully_restored_package_rollback_passed"))
        XCTAssertTrue(report.combinedReportText.contains("- supabase_read_enabled: false"))
        XCTAssertTrue(report.combinedReportText.contains("- activation_performed: false"))
        XCTAssertTrue(report.combinedReportText.contains("- remote_writes_performed: false"))
    }

    func testLocalHealthOperatorPackageValidationRequiresSelectedScope() async throws {
        let fixture = try makePackageFixture()
        defer { tearDownFixture(fixture) }
        fixture.appState.selectedPropertyID = nil
        fixture.appState.currentSession = nil

        let report = await fixture.appState.runLocalHealthSelectedSessionSnapshotPackageValidation()

        XCTAssertEqual(report.packageParity.state, .blocked)
        XCTAssertEqual(report.fullyRestoredRollback.state, .blocked)
        XCTAssertFalse(report.packageParity.blockers.isEmpty)
        XCTAssertFalse(report.fullyRestoredRollback.blockers.isEmpty)
        XCTAssertTrue(report.combinedReportText.contains("selected_session_snapshot_target_required"))
        XCTAssertTrue(report.combinedReportText.contains("- activation_performed: false"))
    }

    func testLocalHealthOperatorPackageValidationBlocksMissingSnapshot() async throws {
        let fixture = try makePackageFixture()
        defer { tearDownFixture(fixture) }
        let appState = AppState(
            localStore: fixture.store,
            userDefaults: fixture.defaults,
            environment: localEnvironment(orgID: fixture.orgID, propertyID: fixture.property.id, sessionID: fixture.session.id),
            sessionSnapshotStorageUploadOverride: { _ in
                XCTFail("Local Health package validation must not upload session snapshots")
            },
            sessionSnapshotRowInsertOverride: { _ in
                XCTFail("Local Health package validation must not insert session snapshot rows")
            },
            sessionSnapshotRowsFetchOverride: { _, _, _ in [] },
            sessionSnapshotStorageDownloadOverride: { _, _ in
                XCTFail("Missing snapshot should not download snapshot payload")
                return Data()
            },
            sessionSnapshotMediaDownloadOverride: { _, _ in
                XCTFail("Missing snapshot should not download media")
                return Data()
            },
            sessionSnapshotRemoteParentPreflightOverride: { _, _, _ in
                AppState.SessionSnapshotAuthPreflightRemoteParentStatus(
                    propertyExists: true,
                    sessionExists: true,
                    propertyOrgID: fixture.orgID,
                    sessionOrgID: fixture.orgID,
                    sessionPropertyIDMatches: true,
                    orgIDsMatch: true,
                    errorMessage: nil
                )
            },
            disableCloudBackupForTests: true
        )
        defer { appState.shutdown() }
        appState._debugSetOrganizationContextForTests(
            memberships: [ActiveOrganizationMembership(id: fixture.orgID, name: "27P Package Org", role: "owner")],
            activeOrganizationID: fixture.orgID,
            ready: true
        )
        appState.selectedPropertyID = fixture.property.id
        appState.currentSession = fixture.session

        let report = await appState.runLocalHealthSelectedSessionSnapshotPackageValidation()

        XCTAssertEqual(report.packageParity.state, .blocked)
        XCTAssertEqual(report.fullyRestoredRollback.state, .blocked)
        XCTAssertTrue(report.packageParity.blockers.contains("restore_diagnostics_not_restorable"))
        XCTAssertTrue(report.fullyRestoredRollback.blockers.contains("restore_diagnostics_not_restorable"))
        XCTAssertNil(report.snapshotID)
        XCTAssertTrue(report.combinedReportText.contains("- remote_writes_performed: false"))
    }

    func testFullyRestoredPackageRollbackRestoresPreHydrationFixture() async throws {
        let evidence = try await makeFullyRestoredRollbackEvidence()
        defer { tearDownFixture(evidence.package.fixture) }

        let validation = evidence.validation

        XCTAssertEqual(evidence.package.restore.result, .restorableMetadataCandidate)
        XCTAssertTrue(evidence.package.hydration.allowed)
        XCTAssertEqual(evidence.package.mediaRestoration.state, .testOnlyMediaRestorationRehearsalPassed)
        XCTAssertEqual(evidence.package.mediaRollback.state, .restoredPreRestorationFixture)
        XCTAssertEqual(evidence.preHydrationFixtureFingerprint, evidence.restoredFixtureFingerprint)
        XCTAssertTrue(evidence.recoveredMediaArtifactsRemoved)
        XCTAssertTrue(evidence.packageCandidateArtifactsRemoved)
        XCTAssertTrue(evidence.originalSentinelPreservedDuringRestoration)
        XCTAssertEqual(validation.state, .testOnlyFullyRestoredPackageRollbackPassed)
        XCTAssertTrue(validation.blockers.isEmpty)
        XCTAssertTrue(validation.preHydrationLocalFixtureRestored)
        XCTAssertTrue(validation.generatedRecoveredMediaArtifactsRemoved)
        XCTAssertTrue(validation.generatedPackageCandidateArtifactsRemoved)
        XCTAssertTrue(validation.originalsPreserved)
        XCTAssertTrue(validation.fallbackRetained)
        XCTAssertTrue(validation.activeSourceRemainsLocal)
        XCTAssertTrue(validation.productionReadsBlocked)
        XCTAssertTrue(validation.broadCanonicalReadsBlocked)
        XCTAssertTrue(validation.activationBlocked)
        XCTAssertTrue(validation.remoteStateWritesBlocked)
        XCTAssertTrue(validation.realLocalUserStateWritesBlocked)
        XCTAssertTrue(validation.exportSealSyncMediaICloudUnchanged)
        XCTAssertTrue(validation.schemaRLSDataUnchanged)

        let report = AppState.productionSingleSessionFullyRestoredPackageRollbackValidationReportText(validation)
        XCTAssertTrue(report.contains("Production Single-Session Fully Restored Package Rollback Validation"))
        XCTAssertTrue(report.contains("- package_rollback_state: test_only_fully_restored_package_rollback_passed"))
        XCTAssertTrue(report.contains("No production behavior changed"))
    }

    func testFullyRestoredPackageRollbackValidationBlocksUnsafeOrIncompleteRollback() async throws {
        let evidence = try await makeFullyRestoredRollbackEvidence()
        defer { tearDownFixture(evidence.package.fixture) }
        var restore = evidence.package.restore
        restore.result = .parentMismatch
        restore.parentRemoteVerified = false
        restore.freshness = "local_newer"
        restore.checksumVerified = false
        let failedItem = AppState.SessionSnapshotMediaRetrievalItemResult(
            id: evidence.package.fixture.sourceMetadata.shots[0].shotID,
            status: .failed,
            checksumVerified: false,
            recoveredLocalPathPresent: false,
            failureReason: "media_payload_unavailable"
        )
        let retrieval = AppState.SessionSnapshotMediaRetrievalResult(
            retrievedAt: evidence.package.mediaRetrieval.retrievedAt,
            allowed: true,
            blockedReason: nil,
            propertyID: evidence.package.mediaRetrieval.propertyID,
            sessionID: evidence.package.mediaRetrieval.sessionID,
            snapshotID: evidence.package.mediaRetrieval.snapshotID,
            attemptedCount: evidence.package.mediaRetrieval.attemptedCount,
            downloadedCount: evidence.package.mediaRetrieval.downloadedCount - 1,
            checksumVerifiedCount: evidence.package.mediaRetrieval.checksumVerifiedCount - 1,
            skippedExistingCount: evidence.package.mediaRetrieval.skippedExistingCount,
            failedCount: 1,
            recoveredLocalPathCount: evidence.package.mediaRetrieval.recoveredLocalPathCount - 1,
            recoveredMediaDirectoryPathPresent: evidence.package.mediaRetrieval.recoveredMediaDirectoryPathPresent,
            items: [failedItem]
        )

        let validation = AppState.makeProductionSingleSessionFullyRestoredPackageRollbackValidation(
            targetScope: scope(for: evidence.package.fixture),
            restoreDiagnostics: restore,
            hydration: evidence.package.hydration,
            mediaRetrieval: retrieval,
            mediaRestoration: evidence.package.mediaRestoration,
            mediaRollback: evidence.package.mediaRollback,
            preHydrationFixtureFingerprint: evidence.preHydrationFixtureFingerprint,
            restoredFixtureFingerprint: "wrong-fingerprint",
            generatedRecoveredMediaArtifactsRemoved: false,
            generatedPackageCandidateArtifactsRemoved: false,
            originalsPreserved: false,
            fallbackRetained: false,
            activeSource: .canonicalCandidate,
            productionReadsEnabled: true,
            broadCanonicalReadRequired: true,
            activationAttempted: true,
            remoteStateWriteAttempted: true,
            realLocalUserStateWriteAttempted: true,
            exportSealSyncMediaICloudBehaviorChanged: true,
            schemaRLSDataBehaviorChanged: true
        )

        XCTAssertEqual(validation.state, .blocked)
        XCTAssertTrue(validation.blockers.contains("metadata_rollback_mismatch"))
        XCTAssertTrue(validation.blockers.contains("leftover_recovered_media_artifacts"))
        XCTAssertTrue(validation.blockers.contains("leftover_candidate_artifacts"))
        XCTAssertTrue(validation.blockers.contains("original_overwrite"))
        XCTAssertTrue(validation.blockers.contains("fallback_missing"))
        XCTAssertTrue(validation.blockers.contains("unsafe_read_write_activation_attempt"))
        XCTAssertTrue(validation.blockers.contains("parent_mismatch"))
        XCTAssertTrue(validation.blockers.contains("local_newer_freshness"))
        XCTAssertTrue(validation.blockers.contains("missing_media"))
        XCTAssertTrue(validation.blockers.contains("checksum_mismatch"))
    }

    func testPackageParityValidationBlocksChecksumMismatch() async throws {
        let evidence = try await makePackageEvidence()
        defer { tearDownFixture(evidence.fixture) }
        var restore = evidence.restore
        restore.result = .checksumFailed
        restore.checksumVerified = false

        let validation = AppState.makeProductionSingleSessionSnapshotPackageHydrationParityValidation(
            targetScope: AppState.ProductionCohortApprovalScope(orgID: evidence.fixture.orgID, propertyID: evidence.fixture.property.id, sessionID: evidence.fixture.session.id),
            restoreDiagnostics: restore,
            hydration: evidence.hydration,
            hydratedMetadata: evidence.hydratedMetadata,
            snapshotShotIDs: Set(evidence.fixture.sourceMetadata.shots.map(\.shotID)),
            snapshotIssueIDs: Set(evidence.fixture.sourceMetadata.issues.map(\.issueID)),
            snapshotGuidedIDs: Set(evidence.fixture.sourceMetadata.guidedShots.map(\.id)),
            mediaRetrieval: evidence.mediaRetrieval,
            mediaRestoration: evidence.mediaRestoration,
            mediaRollback: evidence.mediaRollback,
            candidateDiagnostics: evidence.candidate,
            overlayResult: evidence.overlay,
            overlayComparison: evidence.comparison
        )

        XCTAssertEqual(validation.state, .blocked)
        XCTAssertTrue(validation.blockers.contains("checksum_mismatch"))
        XCTAssertTrue(validation.blockers.contains("snapshot_package_integrity_not_verified"))
    }

    func testPackageParityValidationBlocksMissingMedia() async throws {
        let evidence = try await makePackageEvidence()
        defer { tearDownFixture(evidence.fixture) }
        let failedItem = AppState.SessionSnapshotMediaRetrievalItemResult(
            id: evidence.fixture.sourceMetadata.shots[0].shotID,
            status: .failed,
            checksumVerified: false,
            recoveredLocalPathPresent: false,
            failureReason: "media_payload_unavailable"
        )
        let retrieval = AppState.SessionSnapshotMediaRetrievalResult(
            retrievedAt: evidence.mediaRetrieval.retrievedAt,
            allowed: true,
            blockedReason: nil,
            propertyID: evidence.mediaRetrieval.propertyID,
            sessionID: evidence.mediaRetrieval.sessionID,
            snapshotID: evidence.mediaRetrieval.snapshotID,
            attemptedCount: evidence.mediaRetrieval.attemptedCount,
            downloadedCount: evidence.mediaRetrieval.downloadedCount - 1,
            checksumVerifiedCount: evidence.mediaRetrieval.checksumVerifiedCount - 1,
            skippedExistingCount: evidence.mediaRetrieval.skippedExistingCount,
            failedCount: 1,
            recoveredLocalPathCount: evidence.mediaRetrieval.recoveredLocalPathCount - 1,
            recoveredMediaDirectoryPathPresent: evidence.mediaRetrieval.recoveredMediaDirectoryPathPresent,
            items: [failedItem]
        )

        let validation = AppState.makeProductionSingleSessionSnapshotPackageHydrationParityValidation(
            targetScope: AppState.ProductionCohortApprovalScope(orgID: evidence.fixture.orgID, propertyID: evidence.fixture.property.id, sessionID: evidence.fixture.session.id),
            restoreDiagnostics: evidence.restore,
            hydration: evidence.hydration,
            hydratedMetadata: evidence.hydratedMetadata,
            snapshotShotIDs: Set(evidence.fixture.sourceMetadata.shots.map(\.shotID)),
            snapshotIssueIDs: Set(evidence.fixture.sourceMetadata.issues.map(\.issueID)),
            snapshotGuidedIDs: Set(evidence.fixture.sourceMetadata.guidedShots.map(\.id)),
            mediaRetrieval: retrieval,
            mediaRestoration: evidence.mediaRestoration,
            mediaRollback: evidence.mediaRollback,
            candidateDiagnostics: evidence.candidate,
            overlayResult: evidence.overlay,
            overlayComparison: evidence.comparison
        )

        XCTAssertEqual(validation.state, .blocked)
        XCTAssertTrue(validation.blockers.contains("missing_media"))
        XCTAssertTrue(validation.blockers.contains("media_checksum_parity_failed"))
    }

    func testPackageParityValidationBlocksUnsupportedSchemaAndLocalNewerFreshness() async throws {
        let evidence = try await makePackageEvidence()
        defer { tearDownFixture(evidence.fixture) }
        var restore = evidence.restore
        restore.result = .localNewerConflict
        restore.snapshotSchemaVersion = 99
        restore.freshness = "local_newer"

        let validation = AppState.makeProductionSingleSessionSnapshotPackageHydrationParityValidation(
            targetScope: AppState.ProductionCohortApprovalScope(orgID: evidence.fixture.orgID, propertyID: evidence.fixture.property.id, sessionID: evidence.fixture.session.id),
            restoreDiagnostics: restore,
            hydration: evidence.hydration,
            hydratedMetadata: evidence.hydratedMetadata,
            snapshotShotIDs: Set(evidence.fixture.sourceMetadata.shots.map(\.shotID)),
            snapshotIssueIDs: Set(evidence.fixture.sourceMetadata.issues.map(\.issueID)),
            snapshotGuidedIDs: Set(evidence.fixture.sourceMetadata.guidedShots.map(\.id)),
            mediaRetrieval: evidence.mediaRetrieval,
            mediaRestoration: evidence.mediaRestoration,
            mediaRollback: evidence.mediaRollback,
            candidateDiagnostics: evidence.candidate,
            overlayResult: evidence.overlay,
            overlayComparison: evidence.comparison
        )

        XCTAssertEqual(validation.state, .blocked)
        XCTAssertTrue(validation.blockers.contains("unsupported_schema"))
        XCTAssertTrue(validation.blockers.contains("local_newer_freshness"))
    }

    func testPackageParityValidationDoesNotReportIntegrityFailureForFreshnessOnlyBlock() async throws {
        let evidence = try await makePackageEvidence()
        defer { tearDownFixture(evidence.fixture) }
        var restore = evidence.restore
        restore.result = .localNewerConflict
        restore.failureReason = "local session state is newer than snapshot"
        restore.freshness = "local_newer"

        let validation = AppState.makeProductionSingleSessionSnapshotPackageHydrationParityValidation(
            targetScope: AppState.ProductionCohortApprovalScope(orgID: evidence.fixture.orgID, propertyID: evidence.fixture.property.id, sessionID: evidence.fixture.session.id),
            restoreDiagnostics: restore,
            hydration: evidence.hydration,
            hydratedMetadata: evidence.hydratedMetadata,
            snapshotShotIDs: Set(evidence.fixture.sourceMetadata.shots.map(\.shotID)),
            snapshotIssueIDs: Set(evidence.fixture.sourceMetadata.issues.map(\.issueID)),
            snapshotGuidedIDs: Set(evidence.fixture.sourceMetadata.guidedShots.map(\.id)),
            mediaRetrieval: evidence.mediaRetrieval,
            mediaRestoration: evidence.mediaRestoration,
            mediaRollback: evidence.mediaRollback,
            candidateDiagnostics: evidence.candidate,
            overlayResult: evidence.overlay,
            overlayComparison: evidence.comparison
        )

        XCTAssertEqual(validation.state, .blocked)
        XCTAssertTrue(validation.blockers.contains("restore_diagnostics_not_restorable"))
        XCTAssertTrue(validation.blockers.contains("local_newer_freshness"))
        XCTAssertFalse(validation.blockers.contains("snapshot_package_integrity_not_verified"))
    }

    func testPackageParityValidationBlocksParentAndScopeMismatch() async throws {
        let evidence = try await makePackageEvidence()
        defer { tearDownFixture(evidence.fixture) }
        var restore = evidence.restore
        restore.result = .parentMismatch
        restore.parentRemoteVerified = false

        let validation = AppState.makeProductionSingleSessionSnapshotPackageHydrationParityValidation(
            targetScope: AppState.ProductionCohortApprovalScope(orgID: evidence.fixture.orgID, propertyID: UUID(), sessionID: evidence.fixture.session.id),
            restoreDiagnostics: restore,
            hydration: evidence.hydration,
            hydratedMetadata: evidence.hydratedMetadata,
            snapshotShotIDs: Set(evidence.fixture.sourceMetadata.shots.map(\.shotID)),
            snapshotIssueIDs: Set(evidence.fixture.sourceMetadata.issues.map(\.issueID)),
            snapshotGuidedIDs: Set(evidence.fixture.sourceMetadata.guidedShots.map(\.id)),
            mediaRetrieval: evidence.mediaRetrieval,
            mediaRestoration: evidence.mediaRestoration,
            mediaRollback: evidence.mediaRollback,
            candidateDiagnostics: evidence.candidate,
            overlayResult: evidence.overlay,
            overlayComparison: evidence.comparison
        )

        XCTAssertEqual(validation.state, .blocked)
        XCTAssertTrue(validation.blockers.contains("parent_mismatch"))
        XCTAssertTrue(validation.blockers.contains("scope_mismatch"))
    }

    func testPackageParityValidationBlocksUnsafeWriteAndMissingFallback() async throws {
        let evidence = try await makePackageEvidence()
        defer { tearDownFixture(evidence.fixture) }

        let validation = AppState.makeProductionSingleSessionSnapshotPackageHydrationParityValidation(
            targetScope: AppState.ProductionCohortApprovalScope(orgID: evidence.fixture.orgID, propertyID: evidence.fixture.property.id, sessionID: evidence.fixture.session.id),
            restoreDiagnostics: evidence.restore,
            hydration: evidence.hydration,
            hydratedMetadata: evidence.hydratedMetadata,
            snapshotShotIDs: Set(evidence.fixture.sourceMetadata.shots.map(\.shotID)),
            snapshotIssueIDs: Set(evidence.fixture.sourceMetadata.issues.map(\.issueID)),
            snapshotGuidedIDs: Set(evidence.fixture.sourceMetadata.guidedShots.map(\.id)),
            mediaRetrieval: evidence.mediaRetrieval,
            mediaRestoration: evidence.mediaRestoration,
            mediaRollback: evidence.mediaRollback,
            candidateDiagnostics: evidence.candidate,
            overlayResult: evidence.overlay,
            overlayComparison: evidence.comparison,
            remoteStateWriteAttempted: true,
            realLocalUserStateWriteAttempted: true,
            fallbackRetained: false
        )

        XCTAssertEqual(validation.state, .blocked)
        XCTAssertTrue(validation.blockers.contains("unsafe_write_attempt"))
        XCTAssertTrue(validation.blockers.contains("remote_state_write_attempted"))
        XCTAssertTrue(validation.blockers.contains("real_local_user_state_write_attempted"))
        XCTAssertTrue(validation.blockers.contains("fallback_missing"))
    }

    func testPackageParityValidationBlocksOriginalsOverwriteAttempt() async throws {
        let evidence = try await makePackageEvidence()
        defer { tearDownFixture(evidence.fixture) }

        let validation = AppState.makeProductionSingleSessionSnapshotPackageHydrationParityValidation(
            targetScope: AppState.ProductionCohortApprovalScope(orgID: evidence.fixture.orgID, propertyID: evidence.fixture.property.id, sessionID: evidence.fixture.session.id),
            restoreDiagnostics: evidence.restore,
            hydration: evidence.hydration,
            hydratedMetadata: evidence.hydratedMetadata,
            snapshotShotIDs: Set(evidence.fixture.sourceMetadata.shots.map(\.shotID)),
            snapshotIssueIDs: Set(evidence.fixture.sourceMetadata.issues.map(\.issueID)),
            snapshotGuidedIDs: Set(evidence.fixture.sourceMetadata.guidedShots.map(\.id)),
            mediaRetrieval: evidence.mediaRetrieval,
            mediaRestoration: evidence.mediaRestoration,
            mediaRollback: evidence.mediaRollback,
            candidateDiagnostics: evidence.candidate,
            overlayResult: evidence.overlay,
            overlayComparison: evidence.comparison,
            originalsOverwriteAttempted: true
        )

        XCTAssertEqual(validation.state, .blocked)
        XCTAssertTrue(validation.blockers.contains("originals_overwrite_attempt"))
    }
}
