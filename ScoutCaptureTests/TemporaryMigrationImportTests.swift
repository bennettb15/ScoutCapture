import XCTest
@testable import ScoutCapture

@MainActor
final class TemporaryMigrationImportTests: XCTestCase {
    private let applicationSupportPrefix = "ScoutCapture_Migration/Application Support/"

    func testRestorePathsAcceptNestedFilesAndRejectTraversal() throws {
        XCTAssertEqual(
            try TemporaryMigrationImportManager.validatedRestoreRelativePath(
                "\(applicationSupportPrefix)Profiles/One.json",
                after: applicationSupportPrefix
            ),
            "Profiles/One.json"
        )

        for relativePath in ["../outside.json", "Profiles/../../outside.json", "/outside.json", "./inside.json", "Profiles//one.json", "Profiles\\one.json", "bad\nname.json", ""] {
            XCTAssertThrowsError(
                try TemporaryMigrationImportManager.validatedRestoreRelativePath(
                    applicationSupportPrefix + relativePath,
                    after: applicationSupportPrefix
                ),
                relativePath
            )
        }
    }

    func testUnsafeArchivePathIsRejectedBeforeClearingPreferences() throws {
        let suiteName = "TemporaryMigrationImportTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("preserved", forKey: "scoutcapture.refactor.importPreflight")

        let archiveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: archiveURL) }
        let archive = try StoredZipArchive.buildData(entries: [
            (path: "ScoutCapture_Migration/", data: Data()),
            (path: applicationSupportPrefix + "../outside.json", data: Data("bad".utf8))
        ])
        try archive.write(to: archiveURL)

        XCTAssertThrowsError(
            try TemporaryMigrationImportManager.importMigrationArchive(
                from: archiveURL,
                userDefaults: defaults
            )
        )
        XCTAssertEqual(defaults.string(forKey: "scoutcapture.refactor.importPreflight"), "preserved")
    }
}
