import XCTest
@testable import ScoutCapture

final class Phase2C19CPropertyOpenFreshnessTests: XCTestCase {
    private let propertyID = UUID()
    private let orgID = UUID()
    private let older = Date(timeIntervalSinceReferenceDate: 1_000)
    private let newer = Date(timeIntervalSinceReferenceDate: 2_000)

    private func remote(
        propertyID: UUID? = nil,
        orgID: UUID? = nil,
        updatedAt: Date? = nil,
        deletedAt: Date? = nil,
        isArchived: Bool = false
    ) -> AppState.PropertyOpenFreshnessRemoteSnapshot {
        AppState.PropertyOpenFreshnessRemoteSnapshot(
            propertyID: propertyID ?? self.propertyID,
            orgID: orgID ?? self.orgID,
            updatedAt: updatedAt ?? older,
            revision: 2,
            deletedAt: deletedAt,
            isArchived: isArchived,
            captureProfile: "interior"
        )
    }

    private func freshnessSnapshot(
        propertyID: UUID,
        status: AppState.PropertyOpenFreshnessStatus,
        reason: String
    ) -> AppState.PropertyOpenFreshnessSnapshot {
        AppState.PropertyOpenFreshnessSnapshot(
            propertyID: propertyID,
            status: status,
            checkedAt: Date(timeIntervalSinceReferenceDate: 3_000),
            localUpdatedAt: older,
            remoteUpdatedAt: older,
            remoteRevision: 2,
            hasUnsyncedLocalPropertyWork: false,
            reason: reason
        )
    }

    private func makeFreshnessHUDAppState() throws -> AppState {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScoutCapture-FreshnessHUD-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: "ScoutCapture-FreshnessHUD-\(UUID().uuidString)") ?? .standard
        return AppState(
            localStore: LocalStore(testStorageRootURL: root),
            userDefaults: defaults,
            environment: [:],
            disableCloudBackupForTests: true
        )
    }

    func testRemoteOlderOrEqualClassifiesCurrent() {
        let olderResult = AppState.evaluatePropertyOpenFreshness(
            localPropertyID: propertyID,
            localOrgID: orgID,
            localUpdatedAt: newer,
            localIsArchived: false,
            activeOrganizationID: orgID,
            remote: remote(updatedAt: older),
            hasUnsyncedLocalPropertyWork: false
        )
        let equalResult = AppState.evaluatePropertyOpenFreshness(
            localPropertyID: propertyID,
            localOrgID: orgID,
            localUpdatedAt: older,
            localIsArchived: false,
            activeOrganizationID: orgID,
            remote: remote(updatedAt: older),
            hasUnsyncedLocalPropertyWork: false
        )

        XCTAssertEqual(olderResult.status, .current)
        XCTAssertEqual(equalResult.status, .current)
    }

    func testRemoteNewerWithoutUnsyncedWorkClassifiesRemoteUpdatesAvailable() {
        let result = AppState.evaluatePropertyOpenFreshness(
            localPropertyID: propertyID,
            localOrgID: orgID,
            localUpdatedAt: older,
            localIsArchived: false,
            activeOrganizationID: orgID,
            remote: remote(updatedAt: newer),
            hasUnsyncedLocalPropertyWork: false
        )

        XCTAssertEqual(result.status, .remoteUpdatesAvailable)
        XCTAssertEqual(result.reason, "remote_updated_at_newer")
    }

    func testRemoteNewerWithUnsyncedPropertyWorkClassifiesNeedsReview() {
        let result = AppState.evaluatePropertyOpenFreshness(
            localPropertyID: propertyID,
            localOrgID: orgID,
            localUpdatedAt: older,
            localIsArchived: false,
            activeOrganizationID: orgID,
            remote: remote(updatedAt: newer),
            hasUnsyncedLocalPropertyWork: true
        )

        XCTAssertEqual(result.status, .needsReview)
        XCTAssertEqual(result.reason, "remote_newer_with_unsynced_local_property_work")
    }

    func testDeletedRemotePropertyClassifiesNeedsReview() {
        let result = AppState.evaluatePropertyOpenFreshness(
            localPropertyID: propertyID,
            localOrgID: orgID,
            localUpdatedAt: older,
            localIsArchived: false,
            activeOrganizationID: orgID,
            remote: remote(updatedAt: newer, deletedAt: newer),
            hasUnsyncedLocalPropertyWork: false
        )

        XCTAssertEqual(result.status, .needsReview)
        XCTAssertEqual(result.reason, "remote_deleted")
    }

    func testRemoteOrgMismatchClassifiesNeedsReview() {
        let result = AppState.evaluatePropertyOpenFreshness(
            localPropertyID: propertyID,
            localOrgID: orgID,
            localUpdatedAt: older,
            localIsArchived: false,
            activeOrganizationID: orgID,
            remote: remote(orgID: UUID(), updatedAt: newer),
            hasUnsyncedLocalPropertyWork: false
        )

        XCTAssertEqual(result.status, .needsReview)
        XCTAssertEqual(result.reason, "remote_org_mismatch")
    }

    func testRemoteCheckFailureUsesLocalCacheOrOffline() {
        let networkError = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        let unknownError = NSError(domain: "ScoutCapture.Test", code: 1)

        XCTAssertEqual(AppState.propertyOpenFreshnessStatusForRemoteFailure(networkError), .offline)
        XCTAssertEqual(AppState.propertyOpenFreshnessStatusForRemoteFailure(unknownError), .usingLocalCache)
    }

    func testUnsyncedLocalGuardFindsPendingAndFailedPropertyWorkOnly() {
        let pending = LocalStore.QueuedMutation(
            entityType: "property",
            entityID: propertyID,
            organizationID: orgID,
            operation: "update_property",
            payloadData: Data(),
            idempotencyKey: "pending",
            status: .pending
        )
        let acknowledgedFailed = LocalStore.QueuedMutation(
            entityType: "property",
            entityID: propertyID,
            organizationID: orgID,
            operation: "update_property",
            payloadData: Data(),
            idempotencyKey: "acknowledged",
            status: .failed,
            acknowledgedAt: older
        )
        let sessionMutation = LocalStore.QueuedMutation(
            entityType: "session",
            entityID: UUID(),
            organizationID: orgID,
            propertyID: propertyID,
            operation: "update_session",
            payloadData: Data(),
            idempotencyKey: "session",
            status: .pending
        )

        XCTAssertTrue(AppState.hasUnsyncedLocalPropertyWork(propertyID: propertyID, queuedMutations: [pending]))
        XCTAssertFalse(AppState.hasUnsyncedLocalPropertyWork(propertyID: propertyID, queuedMutations: [acknowledgedFailed]))
        XCTAssertFalse(AppState.hasUnsyncedLocalPropertyWork(propertyID: propertyID, queuedMutations: [sessionMutation]))
    }

    func testFreshnessEvaluationDoesNotMutateQueueInputs() {
        let queued = [
            LocalStore.QueuedMutation(
                entityType: "property",
                entityID: propertyID,
                organizationID: orgID,
                operation: "update_property",
                payloadData: Data(),
                idempotencyKey: "read-only",
                status: .failed
            )
        ]
        let before = queued

        _ = AppState.hasUnsyncedLocalPropertyWork(propertyID: propertyID, queuedMutations: queued)
        _ = AppState.evaluatePropertyOpenFreshness(
            localPropertyID: propertyID,
            localOrgID: orgID,
            localUpdatedAt: older,
            localIsArchived: false,
            activeOrganizationID: orgID,
            remote: remote(updatedAt: newer),
            hasUnsyncedLocalPropertyWork: true
        )

        XCTAssertEqual(queued, before)
    }

    @MainActor
    func testOperationalMediaHydrationSuccessRechecksReferencePendingFreshnessAndConvergesCurrent() async throws {
        let appState = try makeFreshnessHUDAppState()
        let entered = expectation(description: "scoped freshness recheck entered")
        var releaseRecheck: CheckedContinuation<Void, Never>?
        var recheckedPropertyIDs: [UUID] = []

        appState.selectedPropertyID = propertyID
        appState._debugSetPropertyOpenFreshnessSnapshotForTests(
            freshnessSnapshot(
                propertyID: propertyID,
                status: .remoteUpdatesAvailable,
                reason: "reference_media_pending"
            )
        )
        appState._debugSetPropertyOpenFreshnessRecheckOverrideForTests { propertyID in
            recheckedPropertyIDs.append(propertyID)
            entered.fulfill()
            await withCheckedContinuation { continuation in
                releaseRecheck = continuation
            }
            appState._debugSetPropertyOpenFreshnessSnapshotForTests(
                self.freshnessSnapshot(
                    propertyID: propertyID,
                    status: .current,
                    reason: "reference_metadata_current"
                )
            )
        }

        let firstSignal = Task { @MainActor in
            await appState._debugNotifyOperationalMediaHydrationSucceededForTests(propertyID: propertyID)
        }
        await fulfillment(of: [entered], timeout: 5.0)
        await appState._debugNotifyOperationalMediaHydrationSucceededForTests(propertyID: propertyID)
        releaseRecheck?.resume()
        await firstSignal.value

        XCTAssertEqual(recheckedPropertyIDs, [propertyID])
        XCTAssertEqual(appState.propertyOpenFreshness(for: propertyID)?.status, .current)
        XCTAssertEqual(appState.propertyOpenFreshness(for: propertyID)?.reason, "reference_metadata_current")

        await appState._debugNotifyOperationalMediaHydrationSucceededForTests(propertyID: propertyID)
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(recheckedPropertyIDs, [propertyID])
    }

    @MainActor
    func testOperationalMediaHydrationSuccessDoesNotRecheckUnrelatedOrAlreadyCurrentProperties() async throws {
        let appState = try makeFreshnessHUDAppState()
        let unrelatedPropertyID = UUID()
        var recheckedPropertyIDs: [UUID] = []

        appState.selectedPropertyID = propertyID
        appState._debugSetPropertyOpenFreshnessSnapshotForTests(
            freshnessSnapshot(
                propertyID: unrelatedPropertyID,
                status: .remoteUpdatesAvailable,
                reason: "reference_media_pending"
            )
        )
        appState._debugSetPropertyOpenFreshnessSnapshotForTests(
            freshnessSnapshot(
                propertyID: propertyID,
                status: .current,
                reason: "reference_metadata_current"
            )
        )
        appState._debugSetPropertyOpenFreshnessRecheckOverrideForTests { propertyID in
            recheckedPropertyIDs.append(propertyID)
        }

        await appState._debugNotifyOperationalMediaHydrationSucceededForTests(propertyID: unrelatedPropertyID)
        await appState._debugNotifyOperationalMediaHydrationSucceededForTests(propertyID: propertyID)
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertTrue(recheckedPropertyIDs.isEmpty)
        XCTAssertEqual(appState.propertyOpenFreshness(for: unrelatedPropertyID)?.status, .remoteUpdatesAvailable)
        XCTAssertEqual(appState.propertyOpenFreshness(for: propertyID)?.status, .current)
    }
}
