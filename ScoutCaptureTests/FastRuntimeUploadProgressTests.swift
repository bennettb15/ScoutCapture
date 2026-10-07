import Foundation
import XCTest
@testable import ScoutCapture

@MainActor
final class FastRuntimeUploadProgressTests: XCTestCase {
    func testSavedProgressKeepsPhotoCountAcrossRelaunch() throws {
        let confirmed = Set((0..<15).map { _ in UUID() })
        let progress = AppState.FastRuntimeOriginalUploadProgress(
            organizationID: UUID(),
            ownerUserID: UUID(),
            propertyID: UUID(),
            sessionID: UUID(),
            totalCount: 70,
            confirmedShotIDs: confirmed,
            phase: .uploading
        )
        let restored = try JSONDecoder().decode(
            AppState.FastRuntimeOriginalUploadProgress.self,
            from: JSONEncoder().encode(progress)
        )
        XCTAssertEqual(restored.confirmedCount, 15)
        XCTAssertEqual(restored.totalCount, 70)
        XCTAssertEqual(restored.confirmedShotIDs, confirmed)
    }

    func testBackgroundResultKeyChangesWithPhotoChecksum() {
        let sessionID = UUID()
        let shotID = UUID()
        let endpoint = URL(string: "https://example.supabase.co/storage/v1/object/bucket/photo.jpg")!
        let fileURL = URL(fileURLWithPath: "/photo.jpg")
        let oldPhoto = FastRuntimeBackgroundOriginalUploader.Upload(
            sessionID: sessionID,
            shotID: shotID,
            checksumSHA256: "old",
            endpoint: endpoint,
            fileURL: fileURL,
            contentType: "image/jpeg",
            accessToken: "token",
            anonKey: "anon"
        )
        let changedPhoto = FastRuntimeBackgroundOriginalUploader.Upload(
            sessionID: sessionID,
            shotID: shotID,
            checksumSHA256: "new",
            endpoint: endpoint,
            fileURL: fileURL,
            contentType: "image/jpeg",
            accessToken: "token",
            anonKey: "anon"
        )
        XCTAssertNotEqual(oldPhoto.key, changedPhoto.key)
    }
}
