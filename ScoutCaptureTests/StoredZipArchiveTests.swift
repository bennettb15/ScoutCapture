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

    func testZip32FilenameLimitIsEnforced() {
        let oversizedPath = String(repeating: "a", count: Int(UInt16.max) + 1)
        XCTAssertThrowsError(try StoredZipArchive.buildData(entries: [(path: oversizedPath, data: Data())]))
    }
}
