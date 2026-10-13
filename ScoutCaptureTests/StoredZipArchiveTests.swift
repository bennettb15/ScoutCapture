import XCTest
@testable import ScoutCapture

@MainActor
final class StoredZipArchiveTests: XCTestCase {
    func testTimestampedAndLegacyArchivesListExpectedEntries() throws {
        let timestamped = try StoredZipArchive.buildData(entries: [
            (path: "Session/", data: Data(), modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)),
            (path: "Session/session.json", data: Data("{}".utf8), modifiedAt: Date(timeIntervalSince1970: 1_700_000_000))
        ])
        let legacy = try StoredZipArchive.buildData(entries: [
            (path: "session.json", data: Data("{}".utf8))
        ])
        let directory = FileManager.default.temporaryDirectory
        let timestampedURL = directory.appendingPathComponent("\(UUID().uuidString).zip")
        let legacyURL = directory.appendingPathComponent("\(UUID().uuidString).zip")
        defer {
            try? FileManager.default.removeItem(at: timestampedURL)
            try? FileManager.default.removeItem(at: legacyURL)
        }
        try timestamped.write(to: timestampedURL)
        try legacy.write(to: legacyURL)
        XCTAssertEqual(try StoredZipArchive.entryPaths(at: timestampedURL), ["Session/", "Session/session.json"])
        XCTAssertEqual(try StoredZipArchive.entryPaths(at: legacyURL), ["session.json"])
        XCTAssertThrowsError(try StoredZipArchive.entryPaths(at: directory.appendingPathComponent("absent-\(UUID().uuidString).zip")))
    }

    func testStreamingArchivePreservesFilesAndCleansUpOnFailure() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("session.json")
        let archive = directory.appendingPathComponent("export.zip")
        try Data("{\"ok\":true}".utf8).write(to: source)
        let entries = [
            StorageRoot.ExportZipEntry(path: "Session/", fileURL: nil, modifiedAt: nil),
            StorageRoot.ExportZipEntry(path: "Session/session.json", fileURL: source, modifiedAt: nil)
        ]
        try StoredZipArchive.writeFileArchive(entries: entries, at: archive)
        XCTAssertEqual(try StoredZipArchive.entryPaths(at: archive), ["Session/", "Session/session.json"])

        let missing = StorageRoot.ExportZipEntry(
            path: "missing.json", fileURL: directory.appendingPathComponent("missing.json"), modifiedAt: nil
        )
        XCTAssertThrowsError(try StoredZipArchive.writeFileArchive(entries: [missing], at: archive))
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.path))
    }

    func testMigrationStyleArchiveUsesSharedWriter() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("userdefaults_export.json")
        let archive = directory.appendingPathComponent("migration.zip")
        try Data("{\"selection\":true}".utf8).write(to: source)
        let modifiedAt = Date(timeIntervalSince1970: 1_700_000_000)
        try StoredZipArchive.writeFileArchive(
            entries: [
                (path: "ScoutCapture_Migration/", fileURL: nil, modifiedAt: modifiedAt),
                (path: "ScoutCapture_Migration/userdefaults_export.json", fileURL: source, modifiedAt: modifiedAt)
            ],
            at: archive,
            onProgress: { completed, total in
                XCTAssertEqual(total, 2)
                XCTAssertTrue((1...2).contains(completed))
            }
        )
        XCTAssertEqual(
            try StoredZipArchive.entryPaths(at: archive),
            ["ScoutCapture_Migration/", "ScoutCapture_Migration/userdefaults_export.json"]
        )
    }

    func testZip32FilenameLimitIsEnforced() {
        let oversizedPath = String(repeating: "a", count: Int(UInt16.max) + 1)
        XCTAssertThrowsError(try StoredZipArchive.buildData(entries: [(path: oversizedPath, data: Data())]))
    }
}
