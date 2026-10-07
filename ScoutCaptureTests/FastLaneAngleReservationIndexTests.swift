import XCTest
@testable import ScoutCapture

@MainActor
final class FastLaneAngleReservationIndexTests: XCTestCase {
    func testReservationsStayScopedToBuildingElevationAndDetailAcrossCaptures() {
        var index = FastLaneAngleReservationIndex()
        index.reserve(building: "B1", elevation: "South", detailType: "Overview", angleIndex: 1)
        index.reserve(building: "b1", elevation: "south", detailType: "overview", angleIndex: 3)
        index.reserve(building: "B1", elevation: "North", detailType: "Overview", angleIndex: 2)
        index.reserve(building: "B2", elevation: "South", detailType: "Overview", angleIndex: 2)
        index.reserve(building: "B1", elevation: "South", detailType: "Window", angleIndex: 2)

        XCTAssertEqual(index.usedAngles(building: "B1", elevation: "South", detailType: "Overview"), Set([1, 3]))
        index.reserve(building: "B1", elevation: "South", detailType: "Overview", angleIndex: 2)
        XCTAssertEqual(index.usedAngles(building: "B1", elevation: "South", detailType: "Overview"), Set([1, 2, 3]))
        XCTAssertEqual(index.usedAngles(building: "B1", elevation: "North", detailType: "Overview"), Set([2]))
        XCTAssertTrue(index.usedAngles(building: "B1", elevation: "East", detailType: "Overview").isEmpty)
    }
}
