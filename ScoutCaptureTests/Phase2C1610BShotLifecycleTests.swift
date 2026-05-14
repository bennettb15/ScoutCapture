import XCTest
@testable import ScoutCapture

final class Phase2C1610BShotLifecycleTests: XCTestCase {
    private func makeShot() -> ShotMetadata {
        ShotMetadata(
            shotID: UUID(),
            propertyID: UUID(),
            sessionID: UUID(),
            createdAt: Date(timeIntervalSinceReferenceDate: 100),
            capturedAtLocal: nil,
            updatedAt: Date(timeIntervalSinceReferenceDate: 100),
            building: "Building",
            elevation: "North",
            detailType: "Overview",
            angleIndex: 1,
            trade: nil,
            priority: nil,
            shotKey: "building|north|overview|1",
            isGuided: false,
            isFlagged: false,
            issueID: nil,
            issueStatus: nil,
            captureKind: nil,
            firstCaptureKind: nil,
            noteText: nil,
            noteCategory: nil,
            originalFilename: "shot.heic",
            originalRelativePath: "Originals/shot.heic",
            originalByteSize: 128,
            storageBucket: nil,
            storagePath: nil,
            checksumSHA256: nil,
            byteSize: 128,
            uploadState: "pending",
            uploadAttempts: 0,
            lastUploadError: nil,
            stampedFilename: nil,
            stampedRelativePath: nil,
            captureMode: nil,
            lens: nil,
            exifOrientation: nil,
            orientation: nil,
            latitude: nil,
            longitude: nil,
            accuracyMeters: nil,
            imageWidth: nil,
            imageHeight: nil
        )
    }

    func testExistingShotDefaultsToActiveForLifecycleHelpers() {
        let shot = makeShot()

        XCTAssertTrue(shot.isActiveForDefaultWorkflows)
        XCTAssertFalse(shot.isHistorical)
        XCTAssertFalse(shot.isRetired)
        XCTAssertFalse(shot.isSuperseded)
    }

    func testActiveShotAppearsInDefaultWorkflowHelpers() {
        let shot = makeShot()

        XCTAssertTrue(shot.shouldAppearInDefaultGallery)
        XCTAssertTrue(shot.shouldAppearInDefaultReports)
        XCTAssertTrue(shot.shouldAppearInDefaultExports)
    }

    func testRetiredAndSupersededStatesAreHistoricalAndHiddenByDefaultHelpers() {
        for state in [ShotLifecycleState.retired, .superseded] {
            XCTAssertFalse(state.isActiveForDefaultWorkflows)
            XCTAssertTrue(state.isHistorical)
            XCTAssertFalse(state.shouldAppearInDefaultGallery)
            XCTAssertFalse(state.shouldAppearInDefaultReports)
            XCTAssertFalse(state.shouldAppearInDefaultExports)
        }

        XCTAssertTrue(ShotLifecycleState.retired.isRetired)
        XCTAssertTrue(ShotLifecycleState.superseded.isSuperseded)
    }

    func testSelfSupersessionIsInvalid() {
        let shotID = UUID()

        let errors = ShotLifecycleRules.validateReplacement(
            shotID: shotID,
            supersededByShotID: shotID
        )

        XCTAssertEqual(errors, [.selfSupersession(shotID: shotID)])
    }

    func testSimpleReplacementCycleIsInvalid() {
        let firstShotID = UUID()
        let secondShotID = UUID()

        let errors = ShotLifecycleRules.validateReplacementLinks(
            supersededByShotIDByShotID: [
                firstShotID: secondShotID,
                secondShotID: firstShotID
            ]
        )

        XCTAssertEqual(errors.count, 1)
        guard case .replacementCycle(let shotIDs) = errors[0] else {
            return XCTFail("Expected replacement cycle error")
        }
        XCTAssertEqual(Set(shotIDs), Set([firstShotID, secondShotID]))
    }
}
