import Foundation
import XCTest
@testable import ScoutCapture

@MainActor
final class FastLaneThumbnailSourceTests: XCTestCase {
    func testReplacementDoesNotUseCachedPreviousPhoto() {
        let newPath = "/Sessions/new/Originals/new-shot.jpeg"
        let oldPath = "/Cache/old-shot.jpeg"

        XCTAssertEqual(
            FastLaneThumbnailSource.path(for: newPath, resolvedPath: oldPath),
            newPath
        )
    }

    func testSamePhotoCanUseDownloadedCacheCopy() {
        let storedPath = "/Sessions/new/Originals/new-shot.jpeg"
        let downloadedPath = "/Cache/new-shot.jpeg"

        XCTAssertEqual(
            FastLaneThumbnailSource.path(for: storedPath, resolvedPath: downloadedPath),
            downloadedPath
        )
    }

    func testIssueSelectsLinkedReplacementInsteadOfAvailableHistory() {
        let previous = Shot(
            capturedAt: Date(timeIntervalSince1970: 200),
            imageLocalIdentifier: "/Cache/previous.jpeg"
        )
        let replacement = Shot(
            capturedAt: Date(timeIntervalSince1970: 100),
            imageLocalIdentifier: "/Sessions/new/Originals/replacement.jpeg"
        )

        let selected = FastLaneThumbnailSource.currentIssueShot(
            in: [previous, replacement],
            linkedShotID: replacement.id
        )

        XCTAssertEqual(selected?.id, replacement.id)
        XCTAssertEqual(
            FastLaneThumbnailSource.path(
                for: selected?.imageLocalIdentifier ?? "",
                resolvedPath: previous.imageLocalIdentifier
            ),
            replacement.imageLocalIdentifier
        )
    }
}
