import XCTest
@testable import ScoutCapture

final class Phase2C1610BShotLifecycleTests: XCTestCase {
    private func makeShot(
        lifecycleState: ShotLifecycleState = .active,
        retiredAt: Date? = nil,
        retiredReason: String? = nil,
        retiredByUserID: UUID? = nil,
        supersededByShotID: UUID? = nil,
        supersedesShotID: UUID? = nil,
        replacementReason: String? = nil,
        hiddenFromReports: Bool? = nil,
        hiddenFromGallery: Bool? = nil,
        lifecycleUpdatedAt: Date? = nil
    ) -> ShotMetadata {
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
            imageHeight: nil,
            lifecycleState: lifecycleState,
            retiredAt: retiredAt,
            retiredReason: retiredReason,
            retiredByUserID: retiredByUserID,
            supersededByShotID: supersededByShotID,
            supersedesShotID: supersedesShotID,
            replacementReason: replacementReason,
            hiddenFromReports: hiddenFromReports,
            hiddenFromGallery: hiddenFromGallery,
            lifecycleUpdatedAt: lifecycleUpdatedAt
        )
    }

    private func roundTrip(_ shot: ShotMetadata) throws -> ShotMetadata {
        let data = try JSONEncoder().encode(shot)
        return try JSONDecoder().decode(ShotMetadata.self, from: data)
    }

    func testOldJSONWithoutLifecycleFieldsDecodesAsActive() throws {
        let json = """
        {
          "shotID": "\(UUID().uuidString)",
          "createdAt": 100,
          "updatedAt": 100,
          "building": "Building",
          "elevation": "North",
          "detailType": "Overview",
          "angleIndex": 1,
          "shotKey": "building|north|overview|1",
          "isGuided": false,
          "isFlagged": false,
          "originalFilename": "shot.heic",
          "originalRelativePath": "Originals/shot.heic",
          "uploadState": "pending",
          "uploadAttempts": 0
        }
        """

        let shot = try JSONDecoder().decode(ShotMetadata.self, from: Data(json.utf8))

        XCTAssertEqual(shot.lifecycleState, .active)
        XCTAssertTrue(shot.isActiveForDefaultWorkflows)
        XCTAssertTrue(shot.shouldAppearInDefaultGallery)
        XCTAssertTrue(shot.shouldAppearInDefaultReports)
        XCTAssertTrue(shot.shouldAppearInDefaultExports)
    }

    func testExistingShotDefaultsToActiveForLifecycleHelpers() {
        let shot = makeShot()

        XCTAssertEqual(shot.lifecycleState, .active)
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

    func testActiveShotEncodesAndDecodesSafely() throws {
        let shot = makeShot()

        let decoded = try roundTrip(shot)

        XCTAssertEqual(decoded.lifecycleState, .active)
        XCTAssertNil(decoded.retiredAt)
        XCTAssertNil(decoded.supersededByShotID)
        XCTAssertTrue(decoded.shouldAppearInDefaultGallery)
        XCTAssertTrue(decoded.shouldAppearInDefaultReports)
        XCTAssertTrue(decoded.shouldAppearInDefaultExports)
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

    func testRetiredShotDecodesAsHistoricalAndHiddenByDefault() throws {
        let shot = makeShot(
            lifecycleState: .retired,
            retiredAt: Date(timeIntervalSinceReferenceDate: 200),
            retiredReason: "Duplicate capture",
            retiredByUserID: UUID(),
            lifecycleUpdatedAt: Date(timeIntervalSinceReferenceDate: 201)
        )

        let decoded = try roundTrip(shot)

        XCTAssertEqual(decoded.lifecycleState, .retired)
        XCTAssertTrue(decoded.isHistorical)
        XCTAssertTrue(decoded.isRetired)
        XCTAssertFalse(decoded.shouldAppearInDefaultGallery)
        XCTAssertFalse(decoded.shouldAppearInDefaultReports)
        XCTAssertFalse(decoded.shouldAppearInDefaultExports)
        XCTAssertEqual(decoded.retiredReason, "Duplicate capture")
        XCTAssertNotNil(decoded.retiredAt)
        XCTAssertNotNil(decoded.retiredByUserID)
        XCTAssertNotNil(decoded.lifecycleUpdatedAt)
    }

    func testSupersededShotDecodesAsHistoricalAndHiddenByDefault() throws {
        let replacementID = UUID()
        let shot = makeShot(
            lifecycleState: .superseded,
            supersededByShotID: replacementID,
            replacementReason: "Retake",
            lifecycleUpdatedAt: Date(timeIntervalSinceReferenceDate: 250)
        )

        let decoded = try roundTrip(shot)

        XCTAssertEqual(decoded.lifecycleState, .superseded)
        XCTAssertTrue(decoded.isHistorical)
        XCTAssertTrue(decoded.isSuperseded)
        XCTAssertFalse(decoded.shouldAppearInDefaultGallery)
        XCTAssertFalse(decoded.shouldAppearInDefaultReports)
        XCTAssertFalse(decoded.shouldAppearInDefaultExports)
        XCTAssertEqual(decoded.supersededByShotID, replacementID)
        XCTAssertEqual(decoded.replacementReason, "Retake")
        XCTAssertNotNil(decoded.lifecycleUpdatedAt)
    }

    func testHiddenOverridesAffectGalleryAndReportVisibilityHelpers() {
        let activeHidden = makeShot(
            hiddenFromReports: true,
            hiddenFromGallery: true
        )
        let retiredShown = makeShot(
            lifecycleState: .retired,
            hiddenFromReports: false,
            hiddenFromGallery: false
        )

        XCTAssertFalse(activeHidden.shouldAppearInDefaultGallery)
        XCTAssertFalse(activeHidden.shouldAppearInDefaultReports)
        XCTAssertTrue(activeHidden.shouldAppearInDefaultExports)
        XCTAssertTrue(retiredShown.shouldAppearInDefaultGallery)
        XCTAssertTrue(retiredShown.shouldAppearInDefaultReports)
        XCTAssertFalse(retiredShown.shouldAppearInDefaultExports)
    }

    func testReplacementRelationshipFieldsRoundTrip() throws {
        let olderShotID = UUID()
        let newerShotID = UUID()
        let oldShot = makeShot(
            lifecycleState: .superseded,
            supersededByShotID: newerShotID,
            replacementReason: "Retake requested"
        )
        let newShot = makeShot(
            supersedesShotID: olderShotID,
            replacementReason: "Retake requested"
        )

        let decodedOldShot = try roundTrip(oldShot)
        let decodedNewShot = try roundTrip(newShot)

        XCTAssertEqual(decodedOldShot.supersededByShotID, newerShotID)
        XCTAssertNil(decodedOldShot.supersedesShotID)
        XCTAssertEqual(decodedOldShot.replacementReason, "Retake requested")
        XCTAssertEqual(decodedNewShot.supersedesShotID, olderShotID)
        XCTAssertNil(decodedNewShot.supersededByShotID)
        XCTAssertEqual(decodedNewShot.replacementReason, "Retake requested")
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
