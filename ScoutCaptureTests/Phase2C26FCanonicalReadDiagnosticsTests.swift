import XCTest
@testable import ScoutCapture

final class Phase2C26FCanonicalReadDiagnosticsTests: XCTestCase {
    private let orgID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let propertyID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let sessionID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    private func local(
        orgID: UUID? = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        propertyID: UUID? = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
        sessionID: UUID? = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
        sessionPropertyID: UUID? = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
        status: String? = "completed",
        shotCount: Int? = 2,
        issueObservationCount: Int? = 1,
        guidedCount: Int? = 0,
        updatedAt: Date? = Date(timeIntervalSinceReferenceDate: 1_000),
        localKnownStateSource: String? = "metadata_exported_at",
        propertyFound: Bool = true,
        sessionFound: Bool = true
    ) -> AppState.CanonicalReadLocalSnapshot {
        AppState.CanonicalReadLocalSnapshot(
            propertyID: propertyID,
            orgID: orgID,
            sessionID: sessionID,
            sessionPropertyID: sessionPropertyID,
            sessionStatus: status,
            shotCount: shotCount,
            issueObservationCount: issueObservationCount,
            guidedCount: guidedCount,
            updatedAt: updatedAt,
            localKnownStateSource: localKnownStateSource,
            localPropertyFound: propertyFound,
            localSessionFound: sessionFound
        )
    }

    private func remote(
        orgID: UUID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        propertyID: UUID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
        sessionID: UUID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
        sessionPropertyID: UUID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
        status: String? = "completed",
        shotCount: Int = 2,
        observationCount: Int? = 1,
        updatedAt: Date? = Date(timeIntervalSinceReferenceDate: 1_000),
        revision: Int64? = 7,
        includeProperty: Bool = true,
        includeSession: Bool = true
    ) -> AppState.CanonicalReadRemoteSnapshot {
        let shots = (0..<shotCount).map { index in
            AppState.CanonicalReadRemoteShotRow(
                id: UUID(uuidString: "44444444-4444-4444-4444-44444444444\(index)") ?? UUID(),
                sessionID: sessionID,
                deletedAt: nil
            )
        }
        let observations = observationCount.map { count in
            (0..<count).map { index in
                AppState.CanonicalReadRemoteObservationRow(
                    id: UUID(uuidString: "55555555-5555-5555-5555-55555555555\(index)") ?? UUID(),
                    sessionID: sessionID,
                    deletedAt: nil
                )
            }
        }
        return AppState.CanonicalReadRemoteSnapshot(
            properties: includeProperty ? [
                AppState.CanonicalReadRemotePropertyRow(
                    id: propertyID,
                    orgID: orgID,
                    updatedAt: updatedAt,
                    revision: revision,
                    deletedAt: nil
                )
            ] : [],
            sessions: includeSession ? [
                AppState.CanonicalReadRemoteSessionRow(
                    id: sessionID,
                    orgID: orgID,
                    propertyID: sessionPropertyID,
                    status: status,
                    updatedAt: updatedAt,
                    revision: revision,
                    deletedAt: nil
                )
            ] : [],
            shots: shots,
            observations: observations
        )
    }

    private func diagnose(
        local: AppState.CanonicalReadLocalSnapshot,
        remote: AppState.CanonicalReadRemoteSnapshot?
    ) -> AppState.CanonicalReadDiagnosticsResult {
        AppState.makeCanonicalReadDiagnostics(
            checkedAt: Date(timeIntervalSinceReferenceDate: 1_060),
            activeOrganizationID: orgID,
            local: local,
            remote: remote
        )
    }

    func testRemoteMatchesLocal() {
        let result = diagnose(local: local(), remote: remote())

        XCTAssertEqual(result.result, .remoteMatchesLocal)
        XCTAssertEqual(result.canonicalRecommendation, "local_preferred_remote_verified")
        XCTAssertEqual(result.countParity, true)
        XCTAssertEqual(result.statusParity, true)
        XCTAssertNil(result.blockedReason)
    }

    func testRemoteMissing() {
        let result = diagnose(
            local: local(),
            remote: AppState.CanonicalReadRemoteSnapshot(properties: [], sessions: [], shots: [], observations: [])
        )

        XCTAssertEqual(result.result, .remoteMissing)
        XCTAssertEqual(result.blockedReason, "remote_property_or_session_missing")
        XCTAssertFalse(result.remotePropertyFound)
        XCTAssertFalse(result.remoteSessionFound)
    }

    func testLocalNewerConflict() {
        let result = diagnose(
            local: local(
                updatedAt: Date(timeIntervalSinceReferenceDate: 1_200),
                localKnownStateSource: "metadata_ended_at"
            ),
            remote: remote(updatedAt: Date(timeIntervalSinceReferenceDate: 1_000))
        )

        XCTAssertEqual(result.result, .localNewerConflict)
        XCTAssertEqual(result.blockedReason, "local_updated_at_newer_than_remote")
        XCTAssertEqual(result.localKnownStateAt, Date(timeIntervalSinceReferenceDate: 1_200))
        XCTAssertEqual(result.localKnownStateSource, "metadata_ended_at")
    }

    func testFutureReExportExpiresAtDoesNotCreateLocalNewerConflict() {
        let startedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        let exportedAt = Date(timeIntervalSinceReferenceDate: 1_100)
        let firstDeliveredAt = Date(timeIntervalSinceReferenceDate: 1_120)
        let futureReExportExpiresAt = Date(timeIntervalSinceReferenceDate: 9_000)
        let knownState = AppState.canonicalReadLocalKnownState(
            propertyUpdatedAt: Date(timeIntervalSinceReferenceDate: 1_050),
            sessionStartedAt: startedAt,
            sessionEndedAt: nil,
            sessionExportedAt: exportedAt,
            sessionFirstDeliveredAt: firstDeliveredAt,
            sessionReExportExpiresAt: futureReExportExpiresAt,
            metadataStartedAt: startedAt,
            metadataEndedAt: nil,
            metadataExportedAt: exportedAt,
            metadataFirstDeliveredAt: nil,
            metadataReExportExpiresAt: futureReExportExpiresAt
        )

        let result = diagnose(
            local: local(
                issueObservationCount: 0,
                updatedAt: knownState.at,
                localKnownStateSource: knownState.source
            ),
            remote: remote(
                observationCount: 0,
                updatedAt: firstDeliveredAt
            )
        )

        XCTAssertEqual(knownState.at, firstDeliveredAt)
        XCTAssertEqual(knownState.source, "session_first_delivered_at")
        XCTAssertEqual(result.result, .remoteMatchesLocal)
        XCTAssertNotEqual(result.result, .localNewerConflict)
        XCTAssertEqual(result.localKnownStateAt, firstDeliveredAt)
        XCTAssertEqual(result.localKnownStateSource, "session_first_delivered_at")
    }

    func testRemoteNewerCandidate() {
        let result = diagnose(
            local: local(updatedAt: Date(timeIntervalSinceReferenceDate: 1_000)),
            remote: remote(updatedAt: Date(timeIntervalSinceReferenceDate: 1_200))
        )

        XCTAssertEqual(result.result, .remoteNewerCandidate)
        XCTAssertEqual(result.canonicalRecommendation, "manual_review_remote_candidate")
        XCTAssertNil(result.blockedReason)
    }

    func testDivergentConflict() {
        let result = diagnose(
            local: local(shotCount: 2, issueObservationCount: 1),
            remote: remote(shotCount: 3, observationCount: 1)
        )

        XCTAssertEqual(result.result, .divergentConflict)
        XCTAssertEqual(result.countParity, false)
        XCTAssertEqual(result.blockedReason, "remote_rows_diverge_from_local_counts_or_status")
    }

    func testParentOrgMismatch() {
        let mismatchedOrgID = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!
        let result = diagnose(
            local: local(),
            remote: remote(orgID: mismatchedOrgID)
        )

        XCTAssertEqual(result.result, .parentMismatch)
        XCTAssertEqual(result.parentOrgConsistent, false)
        XCTAssertEqual(result.blockedReason, "parent_org_or_property_mismatch")
    }

    func testParentPropertyMismatch() {
        let mismatchedPropertyID = UUID(uuidString: "88888888-8888-8888-8888-888888888888")!
        let result = diagnose(
            local: local(),
            remote: remote(sessionPropertyID: mismatchedPropertyID)
        )

        XCTAssertEqual(result.result, .parentMismatch)
        XCTAssertEqual(result.parentPropertyConsistent, false)
    }

    func testDiagnosticsReportIsSanitized() {
        let result = diagnose(local: local(), remote: remote())
        let report = AppState.canonicalReadDiagnosticsText(result)

        XCTAssertTrue(report.contains("Canonical Read Diagnostics"))
        XCTAssertTrue(report.contains("local_known_state_at"))
        XCTAssertTrue(report.contains("local_known_state_source"))
        XCTAssertTrue(report.contains("does not switch canonical reads"))
        XCTAssertTrue(report.contains("Report rows intentionally omit"))
        XCTAssertFalse(report.contains("/Users/"))
        XCTAssertFalse(report.localizedCaseInsensitiveContains("signed_url="))
        XCTAssertFalse(report.localizedCaseInsensitiveContains("auth_token="))
        XCTAssertFalse(report.localizedCaseInsensitiveContains("media bytes:"))
    }

    func testNoLocalWritesOccurForPureDiagnostics() {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Phase2C26F-\(UUID().uuidString)", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))

        let result = diagnose(local: local(), remote: remote())

        XCTAssertEqual(result.result, .remoteMatchesLocal)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
}
