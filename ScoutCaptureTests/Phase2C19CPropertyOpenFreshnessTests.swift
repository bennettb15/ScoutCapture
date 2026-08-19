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
}
