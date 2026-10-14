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

    func testExportEnumerationAndWriterPreservePhotoSet() throws {
        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: workspace) }
        let exportRoot = workspace
            .appendingPathComponent("Property", isDirectory: true)
            .appendingPathComponent("Session", isDirectory: true)
        let originals = exportRoot.appendingPathComponent("Originals", isDirectory: true)
        try fileManager.createDirectory(at: originals, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: exportRoot.appendingPathComponent("session.json"))
        try Data("passed".utf8).write(to: exportRoot.appendingPathComponent("validation.txt"))

        let photoCount = 24
        let photoSize = 128 * 1024
        for index in 0..<photoCount {
            let photo = originals.appendingPathComponent(String(format: "photo-%02d.heic", index))
            try Data(repeating: UInt8(index), count: photoSize).write(to: photo)
        }

        let archive = workspace.appendingPathComponent("export.zip")
        var expectedPaths: Set<String> = ["session.json", "validation.txt", "Originals/"]
        for index in 0..<photoCount {
            expectedPaths.insert(String(format: "Originals/photo-%02d.heic", index))
        }
        let result = try SessionExportZip.package(
            exportRoot: exportRoot,
            expectedPaths: expectedPaths,
            finalURL: archive,
            errorDomain: "ScoutCapture.Export"
        )
        let paths = result.listedEntries
        XCTAssertEqual(result.url, archive)
        XCTAssertTrue(Set(expectedPaths.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) })
            .isSubset(of: result.relativePaths))
        XCTAssertTrue(paths.contains("Property/session.json"))
        XCTAssertTrue(paths.contains("Property/validation.txt"))
        XCTAssertEqual(paths.filter { $0.hasPrefix("Property/Originals/photo-") }.count, photoCount)

        let input = try FileHandle(forReadingFrom: archive)
        defer { try? input.close() }
        let archiveEntries = try StoredZipArchive.entries(from: input)
        for index in 0..<photoCount {
            let path = String(format: "Property/Originals/photo-%02d.heic", index)
            let entry = try XCTUnwrap(archiveEntries.first { $0.path == path })
            XCTAssertEqual(entry.uncompressedSize, UInt32(photoSize))
            try input.seek(toOffset: UInt64(entry.localHeaderOffset) + 30 + UInt64(path.utf8.count))
            let bytes = try XCTUnwrap(input.read(upToCount: photoSize))
            XCTAssertEqual(bytes, Data(repeating: UInt8(index), count: photoSize))
        }
    }
}
