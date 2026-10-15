import XCTest
@testable import ScoutCapture

@MainActor
final class DetailTypesModelTests: XCTestCase {
    func testFastAndStandardCaptureUseTheSamePresetData() throws {
        let suiteName = "DetailTypesModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = DetailTypesModel(userDefaults: defaults)
        let itemID = model.insertBlankItem(for: CameraChromeLocationMode.interior, profile: .residential)
        model.updateItem("Shared Detail", id: itemID, for: CameraChromeLocationMode.interior, profile: .residential)

        XCTAssertTrue(model.types(for: ContentView.LocationMode.interior, profile: .residential)
            .contains { $0.id == itemID && $0.name == "Shared Detail" })
        XCTAssertTrue(model.names(for: CameraChromeLocationMode.interior, profile: .residential)
            .contains("Shared Detail"))

        let reloaded = DetailTypesModel(userDefaults: defaults)
        XCTAssertTrue(reloaded.items(for: CameraChromeLocationMode.interior, profile: .residential)
            .contains { $0.id == itemID && $0.name == "Shared Detail" })
    }

    func testFastCaptureResetKeepsCaseInsensitiveOverviewSelection() throws {
        let suiteName = "DetailTypesModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let items = [
            DetailTypesModel.DetailTypeItem(name: "Other"),
            DetailTypesModel.DetailTypeItem(name: "overview")
        ]
        defaults.set(try JSONEncoder().encode(items), forKey: "scout.detailTypes.residential.interior.list.v1")

        let model = DetailTypesModel(userDefaults: defaults)
        model.resetFastLaneSelectionsToOverview(for: .residential)

        XCTAssertEqual(model.selected(for: ContentView.LocationMode.interior, profile: .residential), "overview")
    }
}
