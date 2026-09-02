import XCTest
@testable import ScoutCapture

final class ClientPortalPriorityTradeSyncTests: XCTestCase {
    private let older = Date(timeIntervalSinceReferenceDate: 1_000)
    private let newer = Date(timeIntervalSinceReferenceDate: 2_000)

    private func makeStore() throws -> (store: LocalStore, property: Property) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScoutCapture-PortalOverlay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = LocalStore(testStorageRootURL: root)
        let property = try store.createProperty(Property(id: UUID(), orgId: UUID(), name: "Portal Overlay Property"))
        return (store, property)
    }

    private func makeObservation(
        id: UUID = UUID(),
        propertyID: UUID,
        status: Observation.Status = .active,
        priority: String? = "Medium",
        trade: String? = "Paint",
        building: String? = "B1",
        elevation: String? = "North",
        detailType: String? = "Window"
    ) -> Observation {
        Observation(
            id: id,
            propertyID: propertyID,
            sessionID: UUID(),
            createdAt: older,
            updatedAt: older,
            statement: "Cracked pane",
            status: status,
            building: building,
            targetElevation: elevation,
            detailType: detailType,
            priority: priority,
            trade: trade,
            currentReason: "Cracked pane"
        )
    }

    func testPortalPriorityChangeSyncsIntoFutureActiveIssue() throws {
        let fixture = try makeStore()
        let issueID = UUID()
        _ = try fixture.store.createObservation(
            makeObservation(id: issueID, propertyID: fixture.property.id, priority: "Low")
        )

        let result = try fixture.store.applyPortalPunchlistOperationalOverlays(
            propertyID: fixture.property.id,
            overlays: [
                PortalPunchlistOperationalOverlay(
                    issueID: issueID,
                    propertyID: fixture.property.id,
                    priority: "Critical",
                    updatedAt: newer
                )
            ]
        )

        let updated = try XCTUnwrap(try fixture.store.fetchObservations(propertyID: fixture.property.id).first)
        XCTAssertEqual(result.appliedCount, 1)
        XCTAssertEqual(updated.priority, "Critical")
        XCTAssertEqual(updated.trade, "Paint")
    }

    func testPortalTradeChangeSyncsIntoFutureActiveIssue() throws {
        let fixture = try makeStore()
        let issueID = UUID()
        _ = try fixture.store.createObservation(
            makeObservation(id: issueID, propertyID: fixture.property.id, trade: "Paint")
        )

        let result = try fixture.store.applyPortalPunchlistOperationalOverlays(
            propertyID: fixture.property.id,
            overlays: [
                PortalPunchlistOperationalOverlay(
                    issueID: issueID,
                    propertyID: fixture.property.id,
                    trade: "Electrical",
                    updatedAt: newer
                )
            ]
        )

        let updated = try XCTUnwrap(try fixture.store.fetchObservations(propertyID: fixture.property.id).first)
        XCTAssertEqual(result.appliedCount, 1)
        XCTAssertEqual(updated.priority, "Medium")
        XCTAssertEqual(updated.trade, "Electrical")
    }

    func testNoPortalOverrideKeepsScoutCaptureOriginalValues() throws {
        let fixture = try makeStore()
        let issueID = UUID()
        _ = try fixture.store.createObservation(
            makeObservation(id: issueID, propertyID: fixture.property.id, priority: "High", trade: "Roofing")
        )

        let result = try fixture.store.applyPortalPunchlistOperationalOverlays(
            propertyID: fixture.property.id,
            overlays: [
                PortalPunchlistOperationalOverlay(
                    issueID: issueID,
                    propertyID: fixture.property.id,
                    updatedAt: newer
                )
            ]
        )

        let updated = try XCTUnwrap(try fixture.store.fetchObservations(propertyID: fixture.property.id).first)
        XCTAssertEqual(result.appliedCount, 0)
        XCTAssertEqual(updated.priority, "High")
        XCTAssertEqual(updated.trade, "Roofing")
    }

    func testResolvedIssueDoesNotReappearActiveBecauseOfPriorityTradeSync() throws {
        let fixture = try makeStore()
        let issueID = UUID()
        _ = try fixture.store.createObservation(
            makeObservation(id: issueID, propertyID: fixture.property.id, status: .resolved, priority: "Medium", trade: "Paint")
        )

        let result = try fixture.store.applyPortalPunchlistOperationalOverlays(
            propertyID: fixture.property.id,
            overlays: [
                PortalPunchlistOperationalOverlay(
                    issueID: issueID,
                    propertyID: fixture.property.id,
                    status: .active,
                    priority: "Critical",
                    trade: "Plumbing",
                    updatedAt: newer
                )
            ]
        )

        let updated = try XCTUnwrap(try fixture.store.fetchObservations(propertyID: fixture.property.id).first)
        XCTAssertEqual(result.appliedCount, 0)
        XCTAssertEqual(result.skippedResolvedCount, 1)
        XCTAssertEqual(updated.status, .resolved)
        XCTAssertEqual(updated.priority, "Medium")
        XCTAssertEqual(updated.trade, "Paint")
    }

    func testMissingIssueIDMatchesStableLocationIdentity() throws {
        let fixture = try makeStore()
        _ = try fixture.store.createObservation(
            makeObservation(propertyID: fixture.property.id, priority: "Low", trade: "Paint")
        )

        let result = try fixture.store.applyPortalPunchlistOperationalOverlays(
            propertyID: fixture.property.id,
            overlays: [
                PortalPunchlistOperationalOverlay(
                    issueID: nil,
                    propertyID: fixture.property.id,
                    priority: "High",
                    trade: "Electrical",
                    updatedAt: newer,
                    building: "B1",
                    targetElevation: "North",
                    detailType: "Window",
                    angleIndex: 1
                )
            ]
        )

        let updated = try XCTUnwrap(try fixture.store.fetchObservations(propertyID: fixture.property.id).first)
        XCTAssertEqual(result.appliedCount, 1)
        XCTAssertEqual(updated.priority, "High")
        XCTAssertEqual(updated.trade, "Electrical")
    }

    func testAmbiguousLocationMatchDoesNotOverwriteLocalMetadata() throws {
        let fixture = try makeStore()
        _ = try fixture.store.createObservation(
            makeObservation(propertyID: fixture.property.id, priority: "Low", trade: "Paint")
        )
        _ = try fixture.store.createObservation(
            makeObservation(propertyID: fixture.property.id, priority: "High", trade: "Carpentry")
        )

        let result = try fixture.store.applyPortalPunchlistOperationalOverlays(
            propertyID: fixture.property.id,
            overlays: [
                PortalPunchlistOperationalOverlay(
                    issueID: nil,
                    propertyID: fixture.property.id,
                    priority: "Critical",
                    trade: "Electrical",
                    updatedAt: newer,
                    building: "B1",
                    targetElevation: "North",
                    detailType: "Window",
                    angleIndex: 1
                )
            ]
        )

        let observations = try fixture.store.fetchObservations(propertyID: fixture.property.id)
        XCTAssertEqual(result.appliedCount, 0)
        XCTAssertEqual(result.skippedAmbiguousCount, 1)
        XCTAssertEqual(Set(observations.compactMap(\.priority)), Set(["Low", "High"]))
        XCTAssertEqual(Set(observations.compactMap(\.trade)), Set(["Paint", "Carpentry"]))
    }
}
