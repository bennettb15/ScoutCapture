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

    func testCorruptFilePayloadIsRejectedBeforeClearingPreferences() throws {
        let suiteName = "TemporaryMigrationImportTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("preserved", forKey: "scoutcapture.refactor.importPreflight")

        let archiveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: archiveURL) }
        var archive = try StoredZipArchive.buildData(entries: [
            (path: applicationSupportPrefix + "Profiles/One.json", data: Data("original-payload".utf8))
        ])
        let payloadRange = try XCTUnwrap(archive.range(of: Data("original-payload".utf8)))
        archive[payloadRange.lowerBound] ^= 0x01
        try archive.write(to: archiveURL)

        XCTAssertThrowsError(
            try TemporaryMigrationImportManager.importMigrationArchive(
                from: archiveURL,
                userDefaults: defaults
            )
        )
        XCTAssertEqual(defaults.string(forKey: "scoutcapture.refactor.importPreflight"), "preserved")
    }

    func testMalformedPreferencesAreRejectedBeforeClearingPreferences() throws {
        let suiteName = "TemporaryMigrationImportTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("preserved", forKey: "scoutcapture.refactor.importPreflight")

        let archiveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: archiveURL) }
        let archive = try StoredZipArchive.buildData(entries: [
            (path: "ScoutCapture_Migration/userdefaults_export.json", data: Data("not-json".utf8))
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

    func testTruncatedDirectoryIsRejectedBeforeClearingPreferences() throws {
        let suiteName = "TemporaryMigrationImportTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("preserved", forKey: "scoutcapture.refactor.importPreflight")

        let archiveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: archiveURL) }
        var archive = try StoredZipArchive.buildData(entries: [
            (path: applicationSupportPrefix + "Profiles/One.json", data: Data("valid".utf8))
        ])
        archive[archive.count - 22 + 10] = 2 // Claim a second central-directory entry that does not exist.
        try archive.write(to: archiveURL)

        XCTAssertThrowsError(
            try TemporaryMigrationImportManager.importMigrationArchive(
                from: archiveURL,
                userDefaults: defaults
            )
        )
        XCTAssertEqual(defaults.string(forKey: "scoutcapture.refactor.importPreflight"), "preserved")
    }

    func testValidMigrationArchiveRestoresFilesAndPreferences() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let applicationSupport = directory.appendingPathComponent("Application Support", isDirectory: true)
        let documents = directory.appendingPathComponent("Documents", isDirectory: true)
        try fileManager.createDirectory(at: applicationSupport, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: documents, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }
        try Data("old".utf8).write(to: applicationSupport.appendingPathComponent("stale.json"))
        try Data("old".utf8).write(to: documents.appendingPathComponent("stale.txt"))

        let suiteName = "TemporaryMigrationImportTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("old", forKey: "scoutcapture.refactor.importPreflight")
        let selectedPropertyID = UUID()
        let preferences = try JSONSerialization.data(withJSONObject: [
            "values": [
                "scoutcapture.selectedPropertyID": selectedPropertyID.uuidString,
                "scoutcapture.refactor.importPreflight": "restored"
            ]
        ])
        let multiChunkPayload = Data(repeating: 0x5A, count: 256 * 1024)
        let archiveURL = directory.appendingPathComponent("migration.zip")
        let archive = try StoredZipArchive.buildData(entries: [
            (path: "ScoutCapture_Migration/", data: Data()),
            (path: "ScoutCapture_Migration/userdefaults_export.json", data: preferences),
            (path: applicationSupportPrefix + "Profiles/One.json", data: Data("new-profile".utf8)),
            (path: "ScoutCapture_Migration/Documents/notes.txt", data: Data("new-note".utf8)),
            (path: "ScoutCapture_Migration/Documents/large.bin", data: multiChunkPayload)
        ])
        try archive.write(to: archiveURL)

        let restoredID = try TemporaryMigrationImportManager.importMigrationArchive(
            from: archiveURL,
            userDefaults: defaults,
            restoreRoots: (applicationSupport: applicationSupport, documents: documents)
        )
        XCTAssertEqual(restoredID, selectedPropertyID)
        XCTAssertEqual(defaults.string(forKey: "scoutcapture.refactor.importPreflight"), "restored")
        XCTAssertEqual(
            try String(contentsOf: applicationSupport.appendingPathComponent("Profiles/One.json"), encoding: .utf8),
            "new-profile"
        )
        XCTAssertEqual(try String(contentsOf: documents.appendingPathComponent("notes.txt"), encoding: .utf8), "new-note")
        XCTAssertEqual(try Data(contentsOf: documents.appendingPathComponent("large.bin")), multiChunkPayload)
        XCTAssertFalse(fileManager.fileExists(atPath: applicationSupport.appendingPathComponent("stale.json").path))
        XCTAssertFalse(fileManager.fileExists(atPath: documents.appendingPathComponent("stale.txt").path))
    }
}
