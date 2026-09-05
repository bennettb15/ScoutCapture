import XCTest
@testable import ScoutCapture

final class Phase2C11LocalConflictRulesTests: XCTestCase {
    private func makeTempStorageRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScoutCapture-2C11b-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeShot(
        shotID: UUID = UUID(),
        createdAt: Date = Date(timeIntervalSinceReferenceDate: 10),
        updatedAt: Date,
        originalRelativePath: String,
        isGuided: Bool = false,
        isFlagged: Bool = false,
        issueID: UUID? = nil,
        issueStatus: String? = nil,
        captureKind: String? = nil
    ) -> ShotMetadata {
        ShotMetadata(
            shotID: shotID,
            propertyID: UUID(),
            sessionID: UUID(),
            createdAt: createdAt,
            capturedAtLocal: nil,
            updatedAt: updatedAt,
            building: "Building",
            elevation: "North",
            detailType: "Overview",
            angleIndex: 1,
            trade: nil,
            priority: nil,
            shotKey: "building|north|overview|1",
            isGuided: isGuided,
            isFlagged: isFlagged,
            issueID: issueID,
            issueStatus: issueStatus,
            captureKind: captureKind,
            firstCaptureKind: nil,
            noteText: nil,
            noteCategory: nil,
            originalFilename: URL(fileURLWithPath: originalRelativePath).lastPathComponent,
            originalRelativePath: originalRelativePath,
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

    private func makeGuidedShot(
        id: UUID = UUID(),
        title: String = "Panel",
        isCompleted: Bool = false,
        building: String? = nil,
        targetElevation: String? = nil,
        detailType: String? = nil,
        angleIndex: Int? = nil,
        referenceImageLocalIdentifier: String? = nil,
        referenceImagePath: String? = nil,
        shot: Shot? = nil,
        status: GuidedCheckpointStatus = .active,
        isRetired: Bool = false,
        retiredAt: Date? = nil,
        retiredInSessionID: UUID? = nil
    ) -> GuidedShot {
        GuidedShot(
            id: id,
            status: status,
            title: title,
            building: building,
            targetElevation: targetElevation,
            detailType: detailType,
            angleIndex: angleIndex,
            referenceImageLocalIdentifier: referenceImageLocalIdentifier,
            referenceImagePath: referenceImagePath,
            shot: shot,
            isCompleted: isCompleted,
            isRetired: isRetired,
            retiredAt: retiredAt,
            retiredInSessionID: retiredInSessionID
        )
    }

    private func makeObservation(
        id: UUID = UUID(),
        updatedAt: Date,
        status: Observation.Status,
        historyEvents: [ObservationHistoryEvent] = [],
        updateHistory: [ObservationUpdateEntry] = []
    ) -> Observation {
        Observation(
            id: id,
            propertyID: UUID(),
            sessionID: UUID(),
            createdAt: Date(timeIntervalSinceReferenceDate: 10),
            updatedAt: updatedAt,
            statement: "Observation",
            status: status,
            historyEvents: historyEvents,
            updateHistory: updateHistory
        )
    }

    private func makeLocalStoreFixture() throws -> (localStore: LocalStore, storageRoot: URL, organizationID: UUID, propertyID: UUID, sessionID: UUID) {
        let storageRoot = try makeTempStorageRoot()
        let localStore = LocalStore(testStorageRootURL: storageRoot)
        let organizationID = UUID()
        let propertyID = UUID()
        let sessionID = UUID()

        _ = try localStore.createOrganization(Organization(id: organizationID, name: "Org"))
        _ = try localStore.createProperty(
            Property(
                id: propertyID,
                orgId: organizationID,
                name: "Property",
                address: "123 Main Street"
            )
        )
        _ = try localStore.upsertSession(
            Session(
                id: sessionID,
                propertyID: propertyID,
                startedAt: Date(timeIntervalSinceReferenceDate: 50),
                status: .draft
            )
        )

        return (localStore, storageRoot, organizationID, propertyID, sessionID)
    }

    func testManualRetiredGuidedShotRemainsRestorable() {
        let retired = GuidedShot(
            status: .retired,
            title: "Building North Overview",
            building: "Building",
            targetElevation: "North",
            detailType: "Overview",
            angleIndex: 1,
            skipReason: .inaccessible,
            skipSessionID: UUID(),
            isRetired: true,
            retiredAt: Date(timeIntervalSinceReferenceDate: 100),
            retiredInSessionID: UUID()
        )

        XCTAssertTrue(
            LocalConflictRules.retiredGuidedShotIsRestorable(
                retired,
                promotionEvidence: LocalConflictRules.ActiveFlaggedGuidedSuppressionEvidence(),
                retiredGuidedShots: [retired]
            )
        )
    }

    func testIssueCaptureIndicatorRequiresCurrentSessionLinkedShot() {
        let currentSessionID = UUID()
        let previousSessionID = UUID()
        let currentShotID = UUID()
        let priorShotID = UUID()

        XCTAssertTrue(
            LocalConflictRules.issueLinkedShotIsCurrentSessionCapture(
                linkedShotID: currentShotID,
                updatedInSessionID: currentSessionID,
                resolvedInSessionID: nil,
                currentSessionID: currentSessionID,
                currentSessionShotIDs: [currentShotID]
            )
        )
        XCTAssertFalse(
            LocalConflictRules.issueLinkedShotIsCurrentSessionCapture(
                linkedShotID: priorShotID,
                updatedInSessionID: previousSessionID,
                resolvedInSessionID: nil,
                currentSessionID: currentSessionID,
                currentSessionShotIDs: [currentShotID]
            )
        )
        XCTAssertFalse(
            LocalConflictRules.issueLinkedShotIsCurrentSessionCapture(
                linkedShotID: priorShotID,
                updatedInSessionID: currentSessionID,
                resolvedInSessionID: nil,
                currentSessionID: currentSessionID,
                currentSessionShotIDs: [currentShotID]
            )
        )
    }

    func testPropertyLWWAppliesOnlyWhenIncomingIsNewer() {
        let current = Date(timeIntervalSinceReferenceDate: 200)

        XCTAssertTrue(
            LocalConflictRules.shouldApplyPropertyLastWriteWins(
                currentUpdatedAt: current,
                incomingUpdatedAt: Date(timeIntervalSinceReferenceDate: 201)
            )
        )
        XCTAssertFalse(
            LocalConflictRules.shouldApplyPropertyLastWriteWins(
                currentUpdatedAt: current,
                incomingUpdatedAt: current
            )
        )
        XCTAssertFalse(
            LocalConflictRules.shouldApplyPropertyLastWriteWins(
                currentUpdatedAt: current,
                incomingUpdatedAt: Date(timeIntervalSinceReferenceDate: 199)
            )
        )
    }

    func testMediaAppendOnlyDoesNotDuplicateExistingShotID() {
        let shotID = UUID()
        let current = makeShot(
            shotID: shotID,
            updatedAt: Date(timeIntervalSinceReferenceDate: 100),
            originalRelativePath: "Originals/old.heic"
        )
        let incoming = makeShot(
            shotID: shotID,
            updatedAt: Date(timeIntervalSinceReferenceDate: 200),
            originalRelativePath: "Originals/new.heic"
        )

        let merged = LocalConflictRules.applyAppendOnlyMediaRef(
            current: [current],
            incoming: incoming
        )

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].shotID, shotID)
        XCTAssertEqual(merged[0].originalRelativePath, "Originals/new.heic")
    }

    func testCurrentIssueShotSelectionPrefersLinkedFlaggedRetakeWhenTimestampsTie() {
        let issueID = UUID()
        let originalPromotedShotID = UUID()
        let currentFlaggedRetakeShotID = UUID()
        let tiedUpdate = Date(timeIntervalSinceReferenceDate: 300)

        let originalPromotedShot = makeShot(
            shotID: originalPromotedShotID,
            createdAt: Date(timeIntervalSinceReferenceDate: 100),
            updatedAt: tiedUpdate,
            originalRelativePath: "Originals/original-promoted.jpg",
            isGuided: true,
            isFlagged: false,
            issueID: issueID,
            issueStatus: "active"
        )
        let currentFlaggedRetakeShot = makeShot(
            shotID: currentFlaggedRetakeShotID,
            createdAt: Date(timeIntervalSinceReferenceDate: 200),
            updatedAt: tiedUpdate,
            originalRelativePath: "Originals/current-flagged-retake.jpg",
            isGuided: false,
            isFlagged: true,
            issueID: issueID,
            issueStatus: "active"
        )

        let chosen = [originalPromotedShot, currentFlaggedRetakeShot].sorted {
            LocalConflictRules.currentIssueShotSortPrecedes(
                $0,
                $1,
                linkedShotID: currentFlaggedRetakeShotID
            )
        }.first

        XCTAssertEqual(chosen?.shotID, currentFlaggedRetakeShotID)
    }

    func testMediaAppendOnlyAppendsNewShotID() {
        let current = makeShot(
            updatedAt: Date(timeIntervalSinceReferenceDate: 100),
            originalRelativePath: "Originals/one.heic"
        )
        let incoming = makeShot(
            updatedAt: Date(timeIntervalSinceReferenceDate: 200),
            originalRelativePath: "Originals/two.heic"
        )

        let merged = LocalConflictRules.applyAppendOnlyMediaRef(
            current: [current],
            incoming: incoming
        )

        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].shotID, current.shotID)
        XCTAssertEqual(merged[1].shotID, incoming.shotID)
    }

    func testGuidedCompletionReducerIsStableForRepeatedStateByID() {
        let guidedID = UUID()
        let initial = makeGuidedShot(id: guidedID, isCompleted: false)
        let completed = makeGuidedShot(id: guidedID, isCompleted: true)

        let once = LocalConflictRules.applyGuidedCompletionState(
            current: [initial],
            incoming: completed
        )
        let twice = LocalConflictRules.applyGuidedCompletionState(
            current: once,
            incoming: completed
        )

        XCTAssertEqual(once, twice)
        XCTAssertEqual(twice.count, 1)
        XCTAssertTrue(twice[0].isCompleted)
    }

    func testGuidedCompletionNormalizerCollapsesDuplicateIDs() {
        let guidedID = UUID()
        let pending = makeGuidedShot(id: guidedID, title: "Pending", isCompleted: false)
        let completed = makeGuidedShot(id: guidedID, title: "Completed", isCompleted: true)

        let normalized = LocalConflictRules.normalizeGuidedCompletionStates([
            pending,
            completed
        ])

        XCTAssertEqual(normalized.count, 1)
        XCTAssertEqual(normalized[0].id, guidedID)
        XCTAssertEqual(normalized[0].title, "Completed")
        XCTAssertTrue(normalized[0].isCompleted)
    }

    func testGuidedCompletionNormalizerSuppressesOlderActiveDuplicateWhenNewerResolvedMatchesGuidedKey() throws {
        let activeShot = Shot(
            id: UUID(),
            capturedAt: Date(timeIntervalSinceReferenceDate: 100),
            imageLocalIdentifier: "/tmp/stale-active.jpg",
            note: nil
        )
        let active = makeGuidedShot(
            id: UUID(),
            title: "Stale active panel",
            isCompleted: true,
            building: "Building",
            targetElevation: "North",
            detailType: "Panel",
            angleIndex: 1,
            shot: activeShot
        )
        let resolved = makeGuidedShot(
            id: UUID(),
            title: "Resolved panel",
            isCompleted: true,
            building: " building ",
            targetElevation: "north",
            detailType: "panel",
            angleIndex: 1,
            shot: Shot(
                id: UUID(),
                capturedAt: Date(timeIntervalSinceReferenceDate: 200),
                imageLocalIdentifier: "/tmp/resolved.jpg",
                note: nil
            ),
            status: .retired,
            isRetired: true,
            retiredAt: Date(timeIntervalSinceReferenceDate: 200),
            retiredInSessionID: UUID()
        )

        let normalized = LocalConflictRules.normalizeGuidedCompletionStates([active, resolved])
        let stale = try XCTUnwrap(normalized.first(where: { $0.id == active.id }))

        XCTAssertEqual(normalized.count, 2)
        XCTAssertEqual(stale.status, .retired)
        XCTAssertEqual(stale.isRetired, true)
        XCTAssertEqual(stale.retiredAt, resolved.retiredAt)
        XCTAssertEqual(normalized.filter { $0.status != .retired && !$0.isRetired }.count, 0)
    }

    func testGuidedCompletionNormalizerPreservesNewerActiveDuplicateAfterReopen() throws {
        let resolved = makeGuidedShot(
            id: UUID(),
            title: "Resolved panel",
            isCompleted: true,
            building: "Building",
            targetElevation: "North",
            detailType: "Panel",
            angleIndex: 1,
            shot: Shot(
                id: UUID(),
                capturedAt: Date(timeIntervalSinceReferenceDate: 100),
                imageLocalIdentifier: "/tmp/resolved.jpg",
                note: nil
            ),
            status: .retired,
            isRetired: true,
            retiredAt: Date(timeIntervalSinceReferenceDate: 100),
            retiredInSessionID: UUID()
        )
        let reopened = makeGuidedShot(
            id: UUID(),
            title: "Reopened panel",
            isCompleted: true,
            building: "Building",
            targetElevation: "North",
            detailType: "Panel",
            angleIndex: 1,
            shot: Shot(
                id: UUID(),
                capturedAt: Date(timeIntervalSinceReferenceDate: 200),
                imageLocalIdentifier: "/tmp/reopened.jpg",
                note: nil
            )
        )

        let normalized = LocalConflictRules.normalizeGuidedCompletionStates([resolved, reopened])
        let active = try XCTUnwrap(normalized.first(where: { $0.id == reopened.id }))

        XCTAssertEqual(active.status, .active)
        XCTAssertEqual(active.isRetired, false)
    }

    func testActiveFlaggedObservationSuppressesRepresentedGuidedChecklistRows() {
        let sharedImageIdentifier = "/tmp/bottom-photo.heic"
        let convertedGuided = makeGuidedShot(
            id: UUID(),
            title: "Angle 9",
            isCompleted: true,
            building: "Building",
            targetElevation: "North",
            detailType: "Bottom",
            angleIndex: 9,
            shot: Shot(
                id: UUID(),
                capturedAt: Date(timeIntervalSinceReferenceDate: 100),
                imageLocalIdentifier: sharedImageIdentifier,
                note: nil
            )
        )
        let normalGuided = makeGuidedShot(
            id: UUID(),
            title: "Angle 11",
            isCompleted: true,
            building: "Building",
            targetElevation: "North",
            detailType: "Bottom",
            angleIndex: 11,
            shot: Shot(
                id: UUID(),
                capturedAt: Date(timeIntervalSinceReferenceDate: 90),
                imageLocalIdentifier: "/tmp/ordinary-guided.heic",
                note: nil
            )
        )
        let activeFlagged = Observation(
            propertyID: UUID(),
            sessionID: UUID(),
            createdAt: Date(timeIntervalSinceReferenceDate: 100),
            updatedAt: Date(timeIntervalSinceReferenceDate: 120),
            statement: "Convert",
            status: .active,
            linkedShotID: UUID(),
            currentReason: "Convert",
            shots: [
                Shot(
                    id: UUID(),
                    capturedAt: Date(timeIntervalSinceReferenceDate: 120),
                    imageLocalIdentifier: sharedImageIdentifier,
                    note: nil
                )
            ]
        )

        let visible = LocalConflictRules.suppressGuidedShotsRepresentedByActiveFlaggedObservations(
            [convertedGuided, normalGuided],
            observations: [activeFlagged]
        )

        XCTAssertEqual(visible.map(\.id), [normalGuided.id])
    }

    func testLaterGuidedReferenceWithLineageSurvivesPromotionBaseFallbackSuppression() {
        let promotedShotID = UUID()
        let laterGuidedShotID = UUID()
        let promotedMetadata = ShotMetadata(
            shotID: promotedShotID,
            propertyID: UUID(),
            sessionID: UUID(),
            createdAt: Date(timeIntervalSinceReferenceDate: 100),
            capturedAtLocal: nil,
            updatedAt: Date(timeIntervalSinceReferenceDate: 300),
            building: "Building",
            elevation: "North",
            detailType: "Panel",
            angleIndex: 2,
            trade: nil,
            priority: nil,
            shotKey: "building|north|panel|2",
            isGuided: true,
            isFlagged: true,
            issueID: UUID(),
            issueStatus: "active",
            captureKind: "captured",
            firstCaptureKind: "captured",
            noteText: nil,
            noteCategory: nil,
            originalFilename: "promoted.jpg",
            originalRelativePath: "Originals/promoted.jpg",
            originalByteSize: 128,
            stampedFilename: nil,
            stampedRelativePath: nil,
            captureMode: nil,
            lens: nil,
            exifOrientation: nil,
            latitude: nil,
            longitude: nil,
            accuracyMeters: nil,
            imageWidth: nil,
            imageHeight: nil
        )

        let laterGuided = makeGuidedShot(
            id: laterGuidedShotID,
            title: "Building North Panel",
            isCompleted: false,
            building: "Building",
            targetElevation: "North",
            detailType: "Panel",
            angleIndex: 3,
            referenceImageLocalIdentifier: "/tmp/later-guided.jpg",
            referenceImagePath: "/tmp/later-guided.jpg",
            shot: Shot(
                id: laterGuidedShotID,
                capturedAt: Date(timeIntervalSinceReferenceDate: 150),
                imageLocalIdentifier: "/tmp/later-guided.jpg",
                note: nil
            )
        )
        let evidence = LocalConflictRules.activeFlaggedGuidedSuppressionEvidence(
            issueLinkedGuidedShots: [promotedMetadata]
        )

        let visible = LocalConflictRules.suppressGuidedShotsRepresentedByActiveFlaggedObservations(
            [laterGuided],
            observations: [],
            evidence: evidence
        )

        XCTAssertEqual(visible.map(\.id), [laterGuidedShotID])
    }

    func testResolvedFlaggedObservationDoesNotSuppressGuidedChecklistRows() {
        let shotID = UUID()
        let guided = makeGuidedShot(
            id: UUID(),
            title: "Angle 9",
            isCompleted: true,
            shot: Shot(
                id: shotID,
                capturedAt: Date(timeIntervalSinceReferenceDate: 100),
                imageLocalIdentifier: "/tmp/bottom-photo.heic",
                note: nil
            )
        )
        let resolvedFlagged = Observation(
            propertyID: UUID(),
            sessionID: UUID(),
            createdAt: Date(timeIntervalSinceReferenceDate: 100),
            updatedAt: Date(timeIntervalSinceReferenceDate: 120),
            statement: "Resolved",
            status: .resolved,
            linkedShotID: shotID,
            shots: [
                Shot(
                    id: shotID,
                    capturedAt: Date(timeIntervalSinceReferenceDate: 120),
                    imageLocalIdentifier: "/tmp/bottom-photo.heic",
                    note: nil
                )
            ]
        )

        let visible = LocalConflictRules.suppressGuidedShotsRepresentedByActiveFlaggedObservations(
            [guided],
            observations: [resolvedFlagged]
        )

        XCTAssertEqual(visible.map(\.id), [guided.id])
    }

    func testActiveFlaggedObservationGuidedReferencesSuppressGuidedChecklistRows() {
        let guidedID = UUID()
        let guided = makeGuidedShot(
            id: guidedID,
            title: "Angle 9",
            isCompleted: true,
            shot: Shot(
                id: UUID(),
                capturedAt: Date(timeIntervalSinceReferenceDate: 100),
                imageLocalIdentifier: "/tmp/bottom-photo.heic",
                note: nil
            )
        )
        let activeFlagged = Observation(
            propertyID: UUID(),
            sessionID: UUID(),
            createdAt: Date(timeIntervalSinceReferenceDate: 100),
            updatedAt: Date(timeIntervalSinceReferenceDate: 120),
            statement: "Convert",
            status: .active,
            currentReason: "Convert",
            guidedShots: [
                makeGuidedShot(
                    id: guidedID,
                    title: "Angle 9",
                    referenceImagePath: "/tmp/bottom-photo.heic"
                )
            ]
        )

        let visible = LocalConflictRules.suppressGuidedShotsRepresentedByActiveFlaggedObservations(
            [guided],
            observations: [activeFlagged]
        )

        XCTAssertTrue(visible.isEmpty)
    }

    func testActiveIssueMetadataKeySuppressesBlankGuidedShellRow() {
        let issueID = UUID()
        let blankGuidedShell = makeGuidedShot(
            id: UUID(),
            title: "Angle 9",
            isCompleted: false,
            building: "Building",
            targetElevation: "North",
            detailType: "Overview",
            angleIndex: 1,
            shot: nil
        )
        let promotedMetadata = makeShot(
            updatedAt: Date(timeIntervalSinceReferenceDate: 100),
            originalRelativePath: "Originals/promoted.heic",
            isGuided: true,
            isFlagged: true,
            issueID: issueID,
            issueStatus: "active",
            captureKind: "retake"
        )
        let evidence = LocalConflictRules.activeFlaggedGuidedSuppressionEvidence(
            issueLinkedGuidedShots: [promotedMetadata]
        )

        let visible = LocalConflictRules.suppressGuidedShotsRepresentedByActiveFlaggedObservations(
            [blankGuidedShell],
            observations: [],
            evidence: evidence
        )

        XCTAssertTrue(visible.isEmpty)
    }

    func testActiveIssueMetadataShotIDSuppressesPropertyCarryForwardGuidedRow() {
        let guidedID = UUID()
        let issueID = UUID()
        let propertyCarryForward = makeGuidedShot(
            id: guidedID,
            title: "Angle 9",
            isCompleted: true,
            building: "Building",
            targetElevation: "North",
            detailType: "Overview",
            angleIndex: 1,
            shot: Shot(
                id: guidedID,
                capturedAt: Date(timeIntervalSinceReferenceDate: 90),
                imageLocalIdentifier: "/tmp/original-guided.heic",
                note: nil
            )
        )
        let promotedMetadata = makeShot(
            shotID: guidedID,
            updatedAt: Date(timeIntervalSinceReferenceDate: 100),
            originalRelativePath: "Originals/promoted-retake.heic",
            isGuided: true,
            isFlagged: true,
            issueID: issueID,
            issueStatus: "active",
            captureKind: "retake"
        )
        let evidence = LocalConflictRules.activeFlaggedGuidedSuppressionEvidence(
            issueLinkedGuidedShots: [promotedMetadata]
        )

        let visible = LocalConflictRules.suppressGuidedShotsRepresentedByActiveFlaggedObservations(
            [propertyCarryForward],
            observations: [],
            evidence: evidence
        )

        XCTAssertTrue(visible.isEmpty)
    }

    func testIssueLinkedGuidedShotMetadataIsNotOrdinaryGuidedWork() {
        let issueID = UUID()
        let promoted = makeShot(
            updatedAt: Date(timeIntervalSinceReferenceDate: 100),
            originalRelativePath: "Originals/promoted.heic",
            isGuided: true,
            isFlagged: true,
            issueID: issueID,
            issueStatus: "active",
            captureKind: "retake"
        )
        let resolved = makeShot(
            updatedAt: Date(timeIntervalSinceReferenceDate: 120),
            originalRelativePath: "Originals/resolved.heic",
            isGuided: true,
            isFlagged: false,
            issueID: issueID,
            issueStatus: "resolved",
            captureKind: "resolved_capture"
        )

        XCTAssertFalse(LocalConflictRules.shotMetadataIsOrdinaryGuidedWork(promoted))
        XCTAssertFalse(LocalConflictRules.shotMetadataIsOrdinaryGuidedWork(resolved))
    }

    func testNormalGuidedShotMetadataRemainsOrdinaryGuidedWork() {
        let guided = makeShot(
            updatedAt: Date(timeIntervalSinceReferenceDate: 100),
            originalRelativePath: "Originals/guided.heic",
            isGuided: true
        )

        XCTAssertTrue(LocalConflictRules.shotMetadataIsOrdinaryGuidedWork(guided))
    }

    func testObservationReconcileTieKeepsCurrentStatusAndAppendsAudit() {
        let observationID = UUID()
        let sharedTimestamp = Date(timeIntervalSinceReferenceDate: 100)
        let currentEvent = ObservationHistoryEvent(
            timestamp: Date(timeIntervalSinceReferenceDate: 10),
            sessionID: UUID(),
            kind: .created,
            beforeValue: nil,
            afterValue: "active",
            field: "status",
            shotID: nil
        )
        let incomingEvent = ObservationHistoryEvent(
            timestamp: Date(timeIntervalSinceReferenceDate: 20),
            sessionID: UUID(),
            kind: .resolved,
            beforeValue: "active",
            afterValue: "resolved",
            field: "status",
            shotID: nil
        )

        let current = makeObservation(
            id: observationID,
            updatedAt: sharedTimestamp,
            status: .active,
            historyEvents: [currentEvent]
        )
        let incoming = makeObservation(
            id: observationID,
            updatedAt: sharedTimestamp,
            status: .resolved,
            historyEvents: [currentEvent, incomingEvent]
        )

        let reconciled = LocalConflictRules.reconcileObservationStatus(
            current: current,
            incoming: incoming
        )

        XCTAssertEqual(reconciled.status, .active)
        XCTAssertEqual(reconciled.updatedAt, sharedTimestamp)
        XCTAssertEqual(reconciled.historyEvents.count, 2)
        XCTAssertEqual(reconciled.historyEvents.map(\.id), [currentEvent.id, incomingEvent.id])
    }

    func testObservationReconcileNewerStatusWinsAndHistoryRemainsAppendOnly() {
        let observationID = UUID()
        let sharedEventID = UUID()
        let currentEvent = ObservationHistoryEvent(
            id: sharedEventID,
            timestamp: Date(timeIntervalSinceReferenceDate: 10),
            sessionID: UUID(),
            kind: .created,
            beforeValue: nil,
            afterValue: "active",
            field: "status",
            shotID: nil
        )
        let incomingEvent = ObservationHistoryEvent(
            timestamp: Date(timeIntervalSinceReferenceDate: 20),
            sessionID: UUID(),
            kind: .resolved,
            beforeValue: "active",
            afterValue: "resolved",
            field: "status",
            shotID: nil
        )
        let updateEntry = ObservationUpdateEntry(
            createdAt: Date(timeIntervalSinceReferenceDate: 15),
            kind: .revisedObservation,
            text: "Updated detail",
            shotID: nil
        )

        let current = makeObservation(
            id: observationID,
            updatedAt: Date(timeIntervalSinceReferenceDate: 100),
            status: .active,
            historyEvents: [currentEvent],
            updateHistory: [updateEntry]
        )
        let incoming = makeObservation(
            id: observationID,
            updatedAt: Date(timeIntervalSinceReferenceDate: 200),
            status: .resolved,
            historyEvents: [currentEvent, incomingEvent],
            updateHistory: [updateEntry]
        )

        let reconciled = LocalConflictRules.reconcileObservationStatus(
            current: current,
            incoming: incoming
        )

        XCTAssertEqual(reconciled.status, .resolved)
        XCTAssertEqual(reconciled.updatedAt, Date(timeIntervalSinceReferenceDate: 200))
        XCTAssertEqual(reconciled.historyEvents.count, 2)
        XCTAssertEqual(reconciled.updateHistory.count, 1)
    }

    func testObservationNormalizerSuppressesOlderActiveDuplicateWhenNewerResolvedMatchesSameIssue() throws {
        let resolvedSessionID = UUID()
        let issueID = UUID()
        let staleActive = Observation(
            id: issueID,
            propertyID: UUID(),
            sessionID: UUID(),
            createdAt: Date(timeIntervalSinceReferenceDate: 100),
            updatedAt: Date(timeIntervalSinceReferenceDate: 100),
            statement: "Stale active issue",
            status: .active,
            linkedShotID: UUID(),
            building: "Building",
            targetElevation: "North",
            detailType: "Panel",
            priority: "High",
            currentReason: "Stale active issue",
            note: "Stale active issue"
        )
        let resolved = Observation(
            id: issueID,
            propertyID: staleActive.propertyID,
            sessionID: resolvedSessionID,
            createdAt: Date(timeIntervalSinceReferenceDate: 90),
            updatedAt: Date(timeIntervalSinceReferenceDate: 200),
            statement: "Resolved issue",
            status: .resolved,
            linkedShotID: UUID(),
            resolutionPhotoRef: "/tmp/resolved.jpg",
            resolutionStatement: "Resolved in the field",
            updatedInSessionID: resolvedSessionID,
            resolvedInSessionID: resolvedSessionID,
            building: " building ",
            targetElevation: "north",
            detailType: "panel",
            priority: "Low",
            currentReason: "Resolved issue",
            note: "Resolved issue"
        )

        let normalized = LocalConflictRules.normalizeObservations([staleActive, resolved])
        let suppressed = try XCTUnwrap(normalized.first(where: { $0.id == staleActive.id }))

        XCTAssertEqual(suppressed.status, .resolved)
        XCTAssertEqual(suppressed.updatedAt, resolved.updatedAt)
        XCTAssertEqual(suppressed.resolvedInSessionID, resolvedSessionID)
        XCTAssertEqual(suppressed.resolutionPhotoRef, "/tmp/resolved.jpg")
        XCTAssertEqual(normalized.filter { $0.status == .active }.count, 0)
    }

    func testObservationNormalizerPreservesNewerActiveDuplicateAfterReopen() throws {
        let resolved = Observation(
            id: UUID(),
            propertyID: UUID(),
            sessionID: UUID(),
            createdAt: Date(timeIntervalSinceReferenceDate: 100),
            updatedAt: Date(timeIntervalSinceReferenceDate: 100),
            statement: "Resolved issue",
            status: .resolved,
            linkedShotID: UUID(),
            resolvedInSessionID: UUID(),
            building: "Building",
            targetElevation: "North",
            detailType: "Panel",
            priority: "Low",
            currentReason: "Resolved issue",
            note: "Resolved issue"
        )
        let reopened = Observation(
            id: UUID(),
            propertyID: resolved.propertyID,
            sessionID: UUID(),
            createdAt: Date(timeIntervalSinceReferenceDate: 110),
            updatedAt: Date(timeIntervalSinceReferenceDate: 200),
            statement: "Reopened issue",
            status: .active,
            linkedShotID: UUID(),
            building: "Building",
            targetElevation: "North",
            detailType: "Panel",
            priority: "High",
            currentReason: "Reopened issue",
            note: "Reopened issue"
        )

        let normalized = LocalConflictRules.normalizeObservations([resolved, reopened])
        let active = try XCTUnwrap(normalized.first(where: { $0.id == reopened.id }))

        XCTAssertEqual(active.status, .active)
    }

    func testSaveGuidedShotsNormalizesDuplicateIDsBeforePersist() throws {
        let fixture = try makeLocalStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.storageRoot) }

        let guidedID = UUID()
        try fixture.localStore.saveGuidedShots(
            [
                makeGuidedShot(id: guidedID, title: "First", isCompleted: false),
                makeGuidedShot(id: guidedID, title: "Second", isCompleted: true)
            ],
            propertyID: fixture.propertyID
        )

        let persisted = try fixture.localStore.fetchGuidedShots(propertyID: fixture.propertyID)
        XCTAssertEqual(persisted.count, 1)
        XCTAssertEqual(persisted[0].title, "Second")
        XCTAssertTrue(persisted[0].isCompleted)
    }

    func testSyncGuidedShotsToSessionMetadataNormalizesDuplicateIDs() throws {
        let fixture = try makeLocalStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.storageRoot) }

        let guidedID = UUID()
        try fixture.localStore.syncGuidedShotsToSessionMetadata(
            propertyID: fixture.propertyID,
            sessionID: fixture.sessionID,
            guidedShots: [
                makeGuidedShot(id: guidedID, title: "First", isCompleted: false),
                makeGuidedShot(id: guidedID, title: "Second", isCompleted: true)
            ]
        )

        let metadata = try fixture.localStore.loadSessionMetadata(
            propertyID: fixture.propertyID,
            sessionID: fixture.sessionID
        )
        XCTAssertEqual(metadata.guidedShots.count, 1)
        XCTAssertEqual(metadata.guidedShots[0].title, "Second")
        XCTAssertTrue(metadata.guidedShots[0].isCompleted)
    }

    func testUpdateObservationPersistsNormalizedAuditHistory() throws {
        let fixture = try makeLocalStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.storageRoot) }

        let sharedEventID = UUID()
        let sharedUpdateID = UUID()
        let createdEvent = ObservationHistoryEvent(
            id: sharedEventID,
            timestamp: Date(timeIntervalSinceReferenceDate: 10),
            sessionID: fixture.sessionID,
            kind: .created,
            beforeValue: nil,
            afterValue: "active",
            field: "status",
            shotID: nil
        )
        let created = try fixture.localStore.createObservation(
            Observation(
                propertyID: fixture.propertyID,
                sessionID: fixture.sessionID,
                createdAt: Date(timeIntervalSinceReferenceDate: 10),
                updatedAt: Date(timeIntervalSinceReferenceDate: 10),
                statement: "Observation",
                status: .active,
                historyEvents: [createdEvent],
                updateHistory: [
                    ObservationUpdateEntry(
                        id: sharedUpdateID,
                        createdAt: Date(timeIntervalSinceReferenceDate: 11),
                        kind: .revisedObservation,
                        text: "First",
                        shotID: nil
                    )
                ]
            )
        )

        var updated = created
        let resolvedEvent = ObservationHistoryEvent(
            timestamp: Date(timeIntervalSinceReferenceDate: 20),
            sessionID: fixture.sessionID,
            kind: .resolved,
            beforeValue: "active",
            afterValue: "resolved",
            field: "status",
            shotID: nil
        )
        updated.status = .resolved
        updated.historyEvents = [createdEvent, createdEvent, resolvedEvent]
        updated.updateHistory = [
            ObservationUpdateEntry(
                id: sharedUpdateID,
                createdAt: Date(timeIntervalSinceReferenceDate: 11),
                kind: .revisedObservation,
                text: "First",
                shotID: nil
            ),
            ObservationUpdateEntry(
                id: sharedUpdateID,
                createdAt: Date(timeIntervalSinceReferenceDate: 11),
                kind: .revisedObservation,
                text: "First",
                shotID: nil
            )
        ]

        _ = try fixture.localStore.updateObservation(updated)

        let persisted = try fixture.localStore.fetchObservations(propertyID: fixture.propertyID)
        XCTAssertEqual(persisted.count, 1)
        XCTAssertEqual(persisted[0].status, .resolved)
        XCTAssertEqual(persisted[0].historyEvents.count, 2)
        XCTAssertEqual(persisted[0].updateHistory.count, 1)
    }

    func testUpsertShotReplaceGuidedKeyKeepsSingleShotRecord() throws {
        let fixture = try makeLocalStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.storageRoot) }

        let originalShotID = UUID()
        try fixture.localStore.upsertShot(
            propertyID: fixture.propertyID,
            sessionID: fixture.sessionID,
            shot: ShotMetadata(
                shotID: originalShotID,
                propertyID: fixture.propertyID,
                sessionID: fixture.sessionID,
                createdAt: Date(timeIntervalSinceReferenceDate: 100),
                capturedAtLocal: nil,
                updatedAt: Date(timeIntervalSinceReferenceDate: 100),
                building: "Building",
                elevation: "North",
                detailType: "Panel",
                angleIndex: 1,
                trade: nil,
                priority: nil,
                shotKey: "building|north|panel|1",
                isGuided: true,
                isFlagged: false,
                issueID: nil,
                issueStatus: nil,
                captureKind: nil,
                firstCaptureKind: "captured",
                noteText: nil,
                noteCategory: nil,
                originalFilename: "old.heic",
                originalRelativePath: "Originals/old.heic",
                originalByteSize: 100,
                stampedFilename: nil,
                stampedRelativePath: nil,
                captureMode: nil,
                lens: nil,
                exifOrientation: nil,
                latitude: nil,
                longitude: nil,
                accuracyMeters: nil,
                imageWidth: nil,
                imageHeight: nil
            ),
            matchMode: .replaceGuidedKey
        )

        try fixture.localStore.upsertShot(
            propertyID: fixture.propertyID,
            sessionID: fixture.sessionID,
            shot: ShotMetadata(
                shotID: UUID(),
                propertyID: fixture.propertyID,
                sessionID: fixture.sessionID,
                createdAt: Date(timeIntervalSinceReferenceDate: 200),
                capturedAtLocal: nil,
                updatedAt: Date(timeIntervalSinceReferenceDate: 200),
                building: "Building",
                elevation: "North",
                detailType: "Panel",
                angleIndex: 1,
                trade: nil,
                priority: nil,
                shotKey: "building|north|panel|1",
                isGuided: true,
                isFlagged: false,
                issueID: nil,
                issueStatus: nil,
                captureKind: "retake",
                firstCaptureKind: nil,
                noteText: nil,
                noteCategory: nil,
                originalFilename: "new.heic",
                originalRelativePath: "Originals/new.heic",
                originalByteSize: 100,
                stampedFilename: nil,
                stampedRelativePath: nil,
                captureMode: nil,
                lens: nil,
                exifOrientation: nil,
                latitude: nil,
                longitude: nil,
                accuracyMeters: nil,
                imageWidth: nil,
                imageHeight: nil
            ),
            matchMode: .replaceGuidedKey
        )

        let metadata = try fixture.localStore.loadSessionMetadata(
            propertyID: fixture.propertyID,
            sessionID: fixture.sessionID
        )
        XCTAssertEqual(metadata.shots.count, 1)
        XCTAssertEqual(metadata.shots[0].shotID, originalShotID)
        XCTAssertEqual(metadata.shots[0].originalRelativePath, "Originals/new.heic")
    }

    func testFlaggedObservationReasonSyncKeepsShotAndIssueInSessionMetadataAligned() throws {
        let fixture = try makeLocalStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.storageRoot) }

        let issueID = UUID()
        let shotID = UUID()
        let originalObservation = Observation(
            id: issueID,
            propertyID: fixture.propertyID,
            sessionID: fixture.sessionID,
            createdAt: Date(timeIntervalSinceReferenceDate: 100),
            updatedAt: Date(timeIntervalSinceReferenceDate: 101),
            statement: "Original reason",
            status: .active,
            linkedShotID: shotID,
            updatedInSessionID: fixture.sessionID,
            priority: "High",
            currentReason: "Original reason",
            note: "Original reason"
        )
        _ = try fixture.localStore.createObservation(originalObservation)

        var metadata = try fixture.localStore.loadSessionMetadata(
            propertyID: fixture.propertyID,
            sessionID: fixture.sessionID
        )
        metadata.shots = [
            ShotMetadata(
                shotID: shotID,
                propertyID: fixture.propertyID,
                sessionID: fixture.sessionID,
                createdAt: Date(timeIntervalSinceReferenceDate: 100),
                capturedAtLocal: nil,
                updatedAt: Date(timeIntervalSinceReferenceDate: 101),
                building: "Building",
                elevation: "North",
                detailType: "Panel",
                angleIndex: 1,
                trade: "Electrical",
                priority: "High",
                shotKey: "building|north|panel|1",
                isGuided: false,
                isFlagged: true,
                issueID: issueID,
                issueStatus: "active",
                captureKind: "captured",
                firstCaptureKind: "captured",
                noteText: "Original reason",
                noteCategory: nil,
                originalFilename: "flagged.jpg",
                originalRelativePath: "Originals/flagged.jpg",
                originalByteSize: 128,
                stampedFilename: nil,
                stampedRelativePath: nil,
                captureMode: nil,
                lens: nil,
                exifOrientation: nil,
                latitude: nil,
                longitude: nil,
                accuracyMeters: nil,
                imageWidth: nil,
                imageHeight: nil
            )
        ]
        metadata.issues = [
            IssueMetadata(
                issueID: issueID,
                issueStatus: "active",
                currentReason: "Original reason"
            )
        ]
        try fixture.localStore.saveSessionMetadataAtomically(
            propertyID: fixture.propertyID,
            sessionID: fixture.sessionID,
            metadata: metadata
        )

        var revisedObservation = originalObservation
        revisedObservation.currentReason = "Final exported reason"
        revisedObservation.note = "Final exported reason"
        revisedObservation.statement = "Final exported reason"
        revisedObservation.previousReason = "Original reason"
        revisedObservation.priority = "Medium"
        let persistedObservation = try fixture.localStore.updateObservation(revisedObservation)

        _ = try fixture.localStore.syncFlaggedObservationUpdateToSessionMetadata(
            propertyID: fixture.propertyID,
            sessionID: fixture.sessionID,
            observation: persistedObservation,
            shotID: shotID,
            trade: "Plumbing",
            activeCaptureKind: "follow_up_capture",
            updatedAt: Date(timeIntervalSinceReferenceDate: 120)
        )

        let reloaded = try fixture.localStore.loadSessionMetadata(
            propertyID: fixture.propertyID,
            sessionID: fixture.sessionID
        )
        let reloadedShot = reloaded.shots.first(where: { $0.shotID == shotID })
        let reloadedIssue = reloaded.issues.first(where: { $0.issueID == issueID })
        XCTAssertEqual(reloadedShot?.noteText, "Final exported reason")
        XCTAssertEqual(reloadedShot?.priority, "Medium")
        XCTAssertEqual(reloadedShot?.trade, "Plumbing")
        XCTAssertEqual(reloadedIssue?.currentReason, "Final exported reason")
        XCTAssertEqual(reloadedIssue?.issueStatus, "active")
    }

    func testActiveFlaggedGuidedUpsertRetiresPromotedGuidedCarryForwardRow() throws {
        let fixture = try makeLocalStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.storageRoot) }

        let issueID = UUID()
        let originalGuidedShotID = UUID()
        let promotedShotID = UUID()
        let guided = GuidedShot(
            id: originalGuidedShotID,
            title: "Building North Panel",
            building: "Building",
            targetElevation: "North",
            detailType: "Panel",
            angleIndex: 1,
            referenceImageLocalIdentifier: "/tmp/reference.jpg",
            referenceImagePath: "/tmp/reference.jpg",
            shot: nil,
            isCompleted: false
        )
        try fixture.localStore.saveGuidedShots([guided], propertyID: fixture.propertyID)

        var sessionMetadata = try fixture.localStore.loadSessionMetadata(
            propertyID: fixture.propertyID,
            sessionID: fixture.sessionID
        )
        sessionMetadata.guidedShots = [guided]
        try fixture.localStore.saveSessionMetadataAtomically(
            propertyID: fixture.propertyID,
            sessionID: fixture.sessionID,
            metadata: sessionMetadata
        )

        let promotedMetadata = ShotMetadata(
            shotID: promotedShotID,
            propertyID: fixture.propertyID,
            sessionID: fixture.sessionID,
            createdAt: Date(timeIntervalSinceReferenceDate: 100),
            capturedAtLocal: nil,
            updatedAt: Date(timeIntervalSinceReferenceDate: 110),
            building: "Building",
            elevation: "North",
            detailType: "Panel",
            angleIndex: 2,
            trade: "Electrical",
            priority: "High",
            shotKey: "building|north|panel|2",
            isGuided: true,
            isFlagged: true,
            issueID: issueID,
            issueStatus: "active",
            captureKind: "captured",
            firstCaptureKind: "captured",
            noteText: "Convert",
            noteCategory: nil,
            originalFilename: "promoted-guided.jpg",
            originalRelativePath: "Originals/promoted-guided.jpg",
            originalByteSize: 128,
            stampedFilename: nil,
            stampedRelativePath: nil,
            captureMode: nil,
            lens: nil,
            exifOrientation: nil,
            latitude: nil,
            longitude: nil,
            accuracyMeters: nil,
            imageWidth: nil,
            imageHeight: nil
        )

        try fixture.localStore.upsertShot(
            propertyID: fixture.propertyID,
            sessionID: fixture.sessionID,
            shot: promotedMetadata,
            matchMode: .append
        )

        let propertyGuided = try fixture.localStore.fetchGuidedShots(propertyID: fixture.propertyID)
        XCTAssertEqual(propertyGuided.filter { !$0.isRetired && $0.status != .retired }.count, 0)
        let retiredPropertyGuided = try XCTUnwrap(propertyGuided.first(where: { $0.id == originalGuidedShotID }))
        XCTAssertEqual(retiredPropertyGuided.status, .retired)
        XCTAssertTrue(retiredPropertyGuided.isRetired)
        XCTAssertEqual(retiredPropertyGuided.retiredInSessionID, fixture.sessionID)

        let reloaded = try fixture.localStore.loadSessionMetadata(
            propertyID: fixture.propertyID,
            sessionID: fixture.sessionID
        )
        let promotionEvidence = LocalConflictRules.flaggedGuidedPromotionEvidence(
            issueLinkedGuidedShots: reloaded.shots,
            includeResolved: true
        )
        XCTAssertFalse(
            LocalConflictRules.retiredGuidedShotIsRestorable(
                retiredPropertyGuided,
                promotionEvidence: promotionEvidence,
                retiredGuidedShots: [retiredPropertyGuided]
            )
        )
        XCTAssertThrowsError(
            try fixture.localStore.restoreRetiredGuidedShot(
                propertyID: fixture.propertyID,
                sessionID: fixture.sessionID,
                guidedShotID: retiredPropertyGuided.id
            )
        )
        let retiredMetadataGuided = try XCTUnwrap(reloaded.guidedShots.first(where: { $0.id == originalGuidedShotID }))
        XCTAssertEqual(retiredMetadataGuided.status, .retired)
        XCTAssertTrue(retiredMetadataGuided.isRetired)
        XCTAssertEqual(retiredMetadataGuided.retiredInSessionID, fixture.sessionID)
        XCTAssertEqual(reloaded.shots.first(where: { $0.shotID == promotedShotID })?.issueStatus, "active")
    }

    func testFetchGuidedShotsRetiresStalePromotionCarryForwardRowByBaseIdentity() throws {
        let fixture = try makeLocalStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.storageRoot) }

        let issueID = UUID()
        let originalGuidedShotID = UUID()
        let promotedShotID = UUID()
        let guided = GuidedShot(
            id: originalGuidedShotID,
            title: "Building North Panel",
            building: "Building",
            targetElevation: "North",
            detailType: "Panel",
            angleIndex: 1,
            referenceImageLocalIdentifier: "/tmp/reference.jpg",
            referenceImagePath: "/tmp/reference.jpg",
            shot: Shot(
                id: originalGuidedShotID,
                capturedAt: Date(timeIntervalSinceReferenceDate: 90),
                imageLocalIdentifier: "/tmp/original-guided.jpg"
            ),
            isCompleted: true
        )
        try fixture.localStore.saveGuidedShots([guided], propertyID: fixture.propertyID)

        var sessionMetadata = try fixture.localStore.loadSessionMetadata(
            propertyID: fixture.propertyID,
            sessionID: fixture.sessionID
        )
        sessionMetadata.shots = [
            ShotMetadata(
                shotID: promotedShotID,
                propertyID: fixture.propertyID,
                sessionID: fixture.sessionID,
                createdAt: Date(timeIntervalSinceReferenceDate: 100),
                capturedAtLocal: nil,
                updatedAt: Date(timeIntervalSinceReferenceDate: 110),
                building: "Building",
                elevation: "North",
                detailType: "Panel",
                angleIndex: 2,
                trade: "Electrical",
                priority: "High",
                shotKey: "building|north|panel|2",
                isGuided: true,
                isFlagged: true,
                issueID: issueID,
                issueStatus: "active",
                captureKind: "captured",
                firstCaptureKind: "captured",
                noteText: "Convert",
                noteCategory: nil,
                originalFilename: "promoted-guided.jpg",
                originalRelativePath: "Originals/promoted-guided.jpg",
                originalByteSize: 128,
                stampedFilename: nil,
                stampedRelativePath: nil,
                captureMode: nil,
                lens: nil,
                exifOrientation: nil,
                latitude: nil,
                longitude: nil,
                accuracyMeters: nil,
                imageWidth: nil,
                imageHeight: nil
            )
        ]
        try fixture.localStore.saveSessionMetadataAtomically(
            propertyID: fixture.propertyID,
            sessionID: fixture.sessionID,
            metadata: sessionMetadata
        )

        let propertyGuided = try fixture.localStore.fetchGuidedShots(propertyID: fixture.propertyID)
        let retiredGuided = try XCTUnwrap(propertyGuided.first(where: { $0.id == originalGuidedShotID }))
        XCTAssertEqual(retiredGuided.status, .retired)
        XCTAssertTrue(retiredGuided.isRetired)
        XCTAssertEqual(retiredGuided.retiredInSessionID, fixture.sessionID)
    }

    func testNormalGuidedCapturedAfterFlaggedPromotionStillCarriesForward() throws {
        let fixture = try makeLocalStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.storageRoot) }

        let issueID = UUID()
        let staleGuidedShotID = UUID()
        let promotedShotID = UUID()
        let laterGuidedShotID = UUID()
        let staleGuided = GuidedShot(
            id: staleGuidedShotID,
            title: "Building North Panel",
            building: "Building",
            targetElevation: "North",
            detailType: "Panel",
            angleIndex: 1,
            referenceImageLocalIdentifier: "/tmp/original-guided.jpg",
            referenceImagePath: "/tmp/original-guided.jpg",
            shot: Shot(
                id: staleGuidedShotID,
                capturedAt: Date(timeIntervalSinceReferenceDate: 90),
                imageLocalIdentifier: "/tmp/original-guided.jpg"
            ),
            isCompleted: true
        )
        let laterGuided = GuidedShot(
            id: laterGuidedShotID,
            title: "Building North Panel",
            building: "Building",
            targetElevation: "North",
            detailType: "Panel",
            angleIndex: 3,
            referenceImageLocalIdentifier: "/tmp/later-normal-guided.jpg",
            referenceImagePath: "/tmp/later-normal-guided.jpg",
            shot: Shot(
                id: laterGuidedShotID,
                capturedAt: Date(timeIntervalSinceReferenceDate: 150),
                imageLocalIdentifier: "/tmp/later-normal-guided.jpg"
            ),
            isCompleted: true
        )
        try fixture.localStore.saveGuidedShots([staleGuided, laterGuided], propertyID: fixture.propertyID)

        var sessionMetadata = try fixture.localStore.loadSessionMetadata(
            propertyID: fixture.propertyID,
            sessionID: fixture.sessionID
        )
        sessionMetadata.shots = [
            ShotMetadata(
                shotID: promotedShotID,
                propertyID: fixture.propertyID,
                sessionID: fixture.sessionID,
                createdAt: Date(timeIntervalSinceReferenceDate: 100),
                capturedAtLocal: nil,
                updatedAt: Date(timeIntervalSinceReferenceDate: 110),
                building: "Building",
                elevation: "North",
                detailType: "Panel",
                angleIndex: 2,
                trade: "Electrical",
                priority: "High",
                shotKey: "building|north|panel|2",
                isGuided: true,
                isFlagged: true,
                issueID: issueID,
                issueStatus: "active",
                captureKind: "captured",
                firstCaptureKind: "captured",
                noteText: "Convert",
                noteCategory: nil,
                originalFilename: "promoted-guided.jpg",
                originalRelativePath: "Originals/promoted-guided.jpg",
                originalByteSize: 128,
                stampedFilename: nil,
                stampedRelativePath: nil,
                captureMode: nil,
                lens: nil,
                exifOrientation: nil,
                latitude: nil,
                longitude: nil,
                accuracyMeters: nil,
                imageWidth: nil,
                imageHeight: nil
            )
        ]
        try fixture.localStore.saveSessionMetadataAtomically(
            propertyID: fixture.propertyID,
            sessionID: fixture.sessionID,
            metadata: sessionMetadata
        )

        let propertyGuided = try fixture.localStore.fetchGuidedShots(propertyID: fixture.propertyID)
        let retiredOriginal = try XCTUnwrap(propertyGuided.first(where: { $0.id == staleGuidedShotID }))
        let carriedNormal = try XCTUnwrap(propertyGuided.first(where: { $0.id == laterGuidedShotID }))
        XCTAssertEqual(retiredOriginal.status, .retired)
        XCTAssertTrue(retiredOriginal.isRetired)
        XCTAssertEqual(carriedNormal.status, .active)
        XCTAssertFalse(carriedNormal.isRetired)
        XCTAssertTrue(carriedNormal.isCompleted)
        XCTAssertEqual(carriedNormal.shot?.id, laterGuidedShotID)
    }

    func testNormalGuidedCapturedAfterPromotionIsRecoveredWhenPropertyRowIsMissing() throws {
        let fixture = try makeLocalStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.storageRoot) }

        let firstSessionID = UUID()
        let promotionSessionID = UUID()
        let laterSessionID = UUID()
        let originalGuidedShotID = UUID()
        let promotedShotID = UUID()
        let laterGuidedShotID = UUID()
        let issueID = UUID()
        let originalCaptureAt = Date(timeIntervalSinceReferenceDate: 90)
        let promotionCaptureAt = Date(timeIntervalSinceReferenceDate: 100)
        let lateSyncAt = Date(timeIntervalSinceReferenceDate: 300)
        let laterGuidedCaptureAt = Date(timeIntervalSinceReferenceDate: 150)

        _ = try fixture.localStore.upsertSession(
            Session(
                id: firstSessionID,
                propertyID: fixture.propertyID,
                startedAt: originalCaptureAt,
                status: .completed,
                endedAt: originalCaptureAt,
                isSealed: true,
                firstDeliveredAt: originalCaptureAt
            )
        )
        var firstMetadata = try fixture.localStore.loadSessionMetadata(
            propertyID: fixture.propertyID,
            sessionID: firstSessionID
        )
        firstMetadata.shots = [
            ShotMetadata(
                shotID: originalGuidedShotID,
                propertyID: fixture.propertyID,
                sessionID: firstSessionID,
                createdAt: originalCaptureAt,
                capturedAtLocal: nil,
                updatedAt: originalCaptureAt,
                building: "Building",
                elevation: "North",
                detailType: "Panel",
                angleIndex: 1,
                trade: nil,
                priority: nil,
                shotKey: "building|north|panel|1",
                isGuided: true,
                isFlagged: false,
                issueID: nil,
                issueStatus: nil,
                captureKind: "captured",
                firstCaptureKind: "captured",
                noteText: nil,
                noteCategory: nil,
                originalFilename: "original-guided.jpg",
                originalRelativePath: "Originals/original-guided.jpg",
                originalByteSize: 128,
                stampedFilename: nil,
                stampedRelativePath: nil,
                captureMode: nil,
                lens: nil,
                exifOrientation: nil,
                latitude: nil,
                longitude: nil,
                accuracyMeters: nil,
                imageWidth: nil,
                imageHeight: nil
            )
        ]
        firstMetadata.guidedShots = [
            GuidedShot(
                id: UUID(),
                title: "Building North Panel",
                building: "Building",
                targetElevation: "North",
                detailType: "Panel",
                angleIndex: 1,
                referenceImageLocalIdentifier: "/tmp/original-guided.jpg",
                referenceImagePath: "/tmp/original-guided.jpg",
                shot: Shot(
                    id: originalGuidedShotID,
                    capturedAt: originalCaptureAt,
                    imageLocalIdentifier: "/tmp/original-guided.jpg"
                ),
                isCompleted: true
            )
        ]
        try fixture.localStore.saveSessionMetadataAtomically(
            propertyID: fixture.propertyID,
            sessionID: firstSessionID,
            metadata: firstMetadata
        )

        _ = try fixture.localStore.upsertSession(
            Session(
                id: promotionSessionID,
                propertyID: fixture.propertyID,
                startedAt: promotionCaptureAt,
                status: .completed,
                endedAt: promotionCaptureAt,
                isSealed: true,
                firstDeliveredAt: promotionCaptureAt
            )
        )
        var promotionMetadata = try fixture.localStore.loadSessionMetadata(
            propertyID: fixture.propertyID,
            sessionID: promotionSessionID
        )
        promotionMetadata.shots = [
            ShotMetadata(
                shotID: promotedShotID,
                propertyID: fixture.propertyID,
                sessionID: promotionSessionID,
                createdAt: promotionCaptureAt,
                capturedAtLocal: nil,
                updatedAt: lateSyncAt,
                building: "Building",
                elevation: "North",
                detailType: "Panel",
                angleIndex: 2,
                trade: "Electrical",
                priority: "Low",
                shotKey: "building|north|panel|2",
                isGuided: true,
                isFlagged: true,
                issueID: issueID,
                issueStatus: "active",
                captureKind: "captured",
                firstCaptureKind: "captured",
                noteText: "Promoted",
                noteCategory: nil,
                originalFilename: "promoted-guided.jpg",
                originalRelativePath: "Originals/promoted-guided.jpg",
                originalByteSize: 128,
                stampedFilename: nil,
                stampedRelativePath: nil,
                captureMode: nil,
                lens: nil,
                exifOrientation: nil,
                latitude: nil,
                longitude: nil,
                accuracyMeters: nil,
                imageWidth: nil,
                imageHeight: nil
            )
        ]
        try fixture.localStore.saveSessionMetadataAtomically(
            propertyID: fixture.propertyID,
            sessionID: promotionSessionID,
            metadata: promotionMetadata
        )

        let retiredOriginal = GuidedShot(
            id: UUID(),
            status: .retired,
            title: "Building North Panel",
            building: "Building",
            targetElevation: "North",
            detailType: "Panel",
            angleIndex: 1,
            referenceImageLocalIdentifier: "/tmp/promoted-guided.jpg",
            referenceImagePath: "/tmp/promoted-guided.jpg",
            shot: Shot(
                id: promotedShotID,
                capturedAt: promotionCaptureAt,
                imageLocalIdentifier: "/tmp/promoted-guided.jpg"
            ),
            isCompleted: true,
            isRetired: true,
            retiredAt: promotionCaptureAt,
            retiredInSessionID: promotionSessionID
        )
        try fixture.localStore.saveGuidedShots([retiredOriginal], propertyID: fixture.propertyID)

        _ = try fixture.localStore.upsertSession(
            Session(
                id: laterSessionID,
                propertyID: fixture.propertyID,
                startedAt: laterGuidedCaptureAt,
                status: .completed,
                endedAt: laterGuidedCaptureAt,
                isSealed: true,
                firstDeliveredAt: laterGuidedCaptureAt
            )
        )
        var laterMetadata = try fixture.localStore.loadSessionMetadata(
            propertyID: fixture.propertyID,
            sessionID: laterSessionID
        )
        laterMetadata.shots = [
            ShotMetadata(
                shotID: laterGuidedShotID,
                propertyID: fixture.propertyID,
                sessionID: laterSessionID,
                createdAt: laterGuidedCaptureAt,
                capturedAtLocal: nil,
                updatedAt: laterGuidedCaptureAt,
                building: "Building",
                elevation: "North",
                detailType: "Panel",
                angleIndex: 3,
                trade: nil,
                priority: nil,
                shotKey: "building|north|panel|3",
                isGuided: true,
                isFlagged: false,
                issueID: nil,
                issueStatus: nil,
                captureKind: "captured",
                firstCaptureKind: "captured",
                noteText: nil,
                noteCategory: nil,
                originalFilename: "later-normal-guided.jpg",
                originalRelativePath: "Originals/later-normal-guided.jpg",
                originalByteSize: 128,
                stampedFilename: nil,
                stampedRelativePath: nil,
                captureMode: nil,
                lens: nil,
                exifOrientation: nil,
                latitude: nil,
                longitude: nil,
                accuracyMeters: nil,
                imageWidth: nil,
                imageHeight: nil
            )
        ]
        laterMetadata.guidedShots = [
            GuidedShot(
                id: UUID(),
                status: .retired,
                title: "Building North Panel",
                building: "Building",
                targetElevation: "North",
                detailType: "Panel",
                angleIndex: 3,
                referenceImageLocalIdentifier: "/tmp/later-normal-guided.jpg",
                referenceImagePath: "/tmp/later-normal-guided.jpg",
                shot: Shot(
                    id: laterGuidedShotID,
                    capturedAt: laterGuidedCaptureAt,
                    imageLocalIdentifier: "/tmp/later-normal-guided.jpg"
                ),
                isCompleted: true,
                isRetired: true,
                retiredAt: lateSyncAt,
                retiredInSessionID: laterSessionID
            )
        ]
        try fixture.localStore.saveSessionMetadataAtomically(
            propertyID: fixture.propertyID,
            sessionID: laterSessionID,
            metadata: laterMetadata
        )

        let propertyGuided = try fixture.localStore.fetchGuidedShots(propertyID: fixture.propertyID)
        XCTAssertTrue(propertyGuided.contains { guided in
            guided.shot?.id == promotedShotID &&
                guided.status == .retired &&
                guided.isRetired
        })
        let carriedNormal = try XCTUnwrap(propertyGuided.first(where: { $0.shot?.id == laterGuidedShotID }))
        XCTAssertEqual(carriedNormal.status, .active)
        XCTAssertFalse(carriedNormal.isRetired)
        XCTAssertTrue(carriedNormal.isCompleted)
    }

    func testActiveFlaggedGuidedFallbackDoesNotRetireAmbiguousSameDetailAngles() throws {
        let fixture = try makeLocalStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.storageRoot) }

        let issueID = UUID()
        let firstGuidedID = UUID()
        let secondGuidedID = UUID()
        let promotedShotID = UUID()
        let firstGuided = GuidedShot(
            id: firstGuidedID,
            title: "Building North Panel 1",
            building: "Building",
            targetElevation: "North",
            detailType: "Panel",
            angleIndex: 1,
            referenceImageLocalIdentifier: "/tmp/reference-1.jpg",
            referenceImagePath: "/tmp/reference-1.jpg"
        )
        let secondGuided = GuidedShot(
            id: secondGuidedID,
            title: "Building North Panel 2",
            building: "Building",
            targetElevation: "North",
            detailType: "Panel",
            angleIndex: 2,
            referenceImageLocalIdentifier: "/tmp/reference-2.jpg",
            referenceImagePath: "/tmp/reference-2.jpg"
        )
        try fixture.localStore.saveGuidedShots([firstGuided, secondGuided], propertyID: fixture.propertyID)

        let promotedMetadata = ShotMetadata(
            shotID: promotedShotID,
            propertyID: fixture.propertyID,
            sessionID: fixture.sessionID,
            createdAt: Date(timeIntervalSinceReferenceDate: 100),
            capturedAtLocal: nil,
            updatedAt: Date(timeIntervalSinceReferenceDate: 110),
            building: "Building",
            elevation: "North",
            detailType: "Panel",
            angleIndex: 3,
            trade: "Electrical",
            priority: "High",
            shotKey: "building|north|panel|3",
            isGuided: true,
            isFlagged: true,
            issueID: issueID,
            issueStatus: "active",
            captureKind: "captured",
            firstCaptureKind: "captured",
            noteText: "Convert",
            noteCategory: nil,
            originalFilename: "promoted-guided.jpg",
            originalRelativePath: "Originals/promoted-guided.jpg",
            originalByteSize: 128,
            stampedFilename: nil,
            stampedRelativePath: nil,
            captureMode: nil,
            lens: nil,
            exifOrientation: nil,
            latitude: nil,
            longitude: nil,
            accuracyMeters: nil,
            imageWidth: nil,
            imageHeight: nil
        )

        try fixture.localStore.upsertShot(
            propertyID: fixture.propertyID,
            sessionID: fixture.sessionID,
            shot: promotedMetadata,
            matchMode: .append
        )

        let propertyGuided = try fixture.localStore.fetchGuidedShots(propertyID: fixture.propertyID)
        XCTAssertEqual(propertyGuided.filter { !$0.isRetired && $0.status != .retired }.count, 2)
        XCTAssertTrue(propertyGuided.contains(where: { $0.id == firstGuidedID && !$0.isRetired }))
        XCTAssertTrue(propertyGuided.contains(where: { $0.id == secondGuidedID && !$0.isRetired }))
    }

    func testFlaggedObservationResolveSyncsResolvedShotAndIssueState() throws {
        let fixture = try makeLocalStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.storageRoot) }

        let issueID = UUID()
        let shotID = UUID()
        let activeObservation = Observation(
            id: issueID,
            propertyID: fixture.propertyID,
            sessionID: fixture.sessionID,
            createdAt: Date(timeIntervalSinceReferenceDate: 100),
            updatedAt: Date(timeIntervalSinceReferenceDate: 105),
            statement: "Active reason",
            status: .active,
            linkedShotID: shotID,
            updatedInSessionID: fixture.sessionID,
            priority: "Medium",
            currentReason: "Active reason",
            note: "Active reason"
        )
        _ = try fixture.localStore.createObservation(activeObservation)

        var metadata = try fixture.localStore.loadSessionMetadata(
            propertyID: fixture.propertyID,
            sessionID: fixture.sessionID
        )
        metadata.shots = [
            ShotMetadata(
                shotID: shotID,
                propertyID: fixture.propertyID,
                sessionID: fixture.sessionID,
                createdAt: Date(timeIntervalSinceReferenceDate: 100),
                capturedAtLocal: nil,
                updatedAt: Date(timeIntervalSinceReferenceDate: 105),
                building: "Building",
                elevation: "North",
                detailType: "Panel",
                angleIndex: 1,
                trade: "Electrical",
                priority: "Medium",
                shotKey: "building|north|panel|1",
                isGuided: false,
                isFlagged: true,
                issueID: issueID,
                issueStatus: "active",
                captureKind: "reference",
                firstCaptureKind: "captured",
                noteText: "Active reason",
                noteCategory: nil,
                originalFilename: "resolved.jpg",
                originalRelativePath: "Originals/resolved.jpg",
                originalByteSize: 128,
                stampedFilename: nil,
                stampedRelativePath: nil,
                captureMode: nil,
                lens: nil,
                exifOrientation: nil,
                latitude: nil,
                longitude: nil,
                accuracyMeters: nil,
                imageWidth: nil,
                imageHeight: nil
            )
        ]
        metadata.issues = [
            IssueMetadata(
                issueID: issueID,
                issueStatus: "active",
                currentReason: "Active reason"
            )
        ]
        try fixture.localStore.saveSessionMetadataAtomically(
            propertyID: fixture.propertyID,
            sessionID: fixture.sessionID,
            metadata: metadata
        )

        var resolvedObservation = activeObservation
        resolvedObservation.status = .resolved
        resolvedObservation.resolvedInSessionID = fixture.sessionID
        resolvedObservation.resolutionPhotoRef = "resolved-photo"
        resolvedObservation.resolutionStatement = "Condition no longer visibly present."
        resolvedObservation.currentReason = "Resolved reason"
        resolvedObservation.note = "Resolved reason"
        resolvedObservation.statement = "Resolved reason"
        let persistedObservation = try fixture.localStore.updateObservation(resolvedObservation)

        _ = try fixture.localStore.syncFlaggedObservationUpdateToSessionMetadata(
            propertyID: fixture.propertyID,
            sessionID: fixture.sessionID,
            observation: persistedObservation,
            shotID: shotID,
            trade: "Electrical",
            activeCaptureKind: "follow_up_capture",
            updatedAt: Date(timeIntervalSinceReferenceDate: 130)
        )

        let reloaded = try fixture.localStore.loadSessionMetadata(
            propertyID: fixture.propertyID,
            sessionID: fixture.sessionID
        )
        let reloadedShot = reloaded.shots.first(where: { $0.shotID == shotID })
        let reloadedIssue = reloaded.issues.first(where: { $0.issueID == issueID })
        XCTAssertEqual(reloadedShot?.isFlagged, false)
        XCTAssertEqual(reloadedShot?.issueStatus, "resolved")
        XCTAssertEqual(reloadedShot?.captureKind, "resolved_capture")
        XCTAssertEqual(reloadedShot?.noteText, "Resolved reason")
        XCTAssertEqual(reloadedShot?.priority, "Medium")
        XCTAssertEqual(reloadedIssue?.issueStatus, "resolved")
        XCTAssertEqual(reloadedIssue?.currentReason, "Resolved reason")
        XCTAssertNotNil(reloadedIssue?.resolvedAt)
        XCTAssertEqual(reloadedIssue?.lastCaptureSessionId, fixture.sessionID)
        XCTAssertEqual(reloaded.flaggedIssues.count, 0)
    }

    func testResolvedFlaggedGuidedObservationRetiresGuidedCarryForwardRow() throws {
        let fixture = try makeLocalStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.storageRoot) }

        let issueID = UUID()
        let shotID = UUID()
        let capturedAt = Date(timeIntervalSinceReferenceDate: 100)
        let activeShot = Shot(
            id: shotID,
            capturedAt: capturedAt,
            imageLocalIdentifier: "/tmp/active-guided.jpg",
            note: "Active reason"
        )
        let activeObservation = Observation(
            id: issueID,
            propertyID: fixture.propertyID,
            sessionID: fixture.sessionID,
            createdAt: capturedAt,
            updatedAt: Date(timeIntervalSinceReferenceDate: 105),
            statement: "Active reason",
            status: .active,
            linkedShotID: shotID,
            updatedInSessionID: fixture.sessionID,
            priority: "High",
            currentReason: "Active reason",
            note: "Active reason",
            shots: [activeShot]
        )
        _ = try fixture.localStore.createObservation(activeObservation)

        let guided = GuidedShot(
            id: shotID,
            title: "Building North Panel",
            building: "Building",
            targetElevation: "North",
            detailType: "Panel",
            angleIndex: 1,
            referenceImageLocalIdentifier: "/tmp/reference.jpg",
            referenceImagePath: "/tmp/reference.jpg",
            shot: activeShot,
            isCompleted: true
        )
        try fixture.localStore.saveGuidedShots([guided], propertyID: fixture.propertyID)

        var metadata = try fixture.localStore.loadSessionMetadata(
            propertyID: fixture.propertyID,
            sessionID: fixture.sessionID
        )
        metadata.guidedShots = [guided]
        metadata.shots = [
            ShotMetadata(
                shotID: shotID,
                propertyID: fixture.propertyID,
                sessionID: fixture.sessionID,
                createdAt: capturedAt,
                capturedAtLocal: nil,
                updatedAt: Date(timeIntervalSinceReferenceDate: 105),
                building: "Building",
                elevation: "North",
                detailType: "Panel",
                angleIndex: 1,
                trade: "Electrical",
                priority: "High",
                shotKey: "building|north|panel|1",
                isGuided: true,
                isFlagged: true,
                issueID: issueID,
                issueStatus: "active",
                captureKind: "captured",
                firstCaptureKind: "captured",
                noteText: "Active reason",
                noteCategory: nil,
                originalFilename: "active-guided.jpg",
                originalRelativePath: "Originals/active-guided.jpg",
                originalByteSize: 128,
                stampedFilename: nil,
                stampedRelativePath: nil,
                captureMode: nil,
                lens: nil,
                exifOrientation: nil,
                latitude: nil,
                longitude: nil,
                accuracyMeters: nil,
                imageWidth: nil,
                imageHeight: nil
            )
        ]
        metadata.issues = [
            IssueMetadata(
                issueID: issueID,
                issueStatus: "active",
                currentReason: "Active reason",
                firstSeenAt: capturedAt,
                lastSeenAt: Date(timeIntervalSinceReferenceDate: 105),
                lastCaptureSessionId: fixture.sessionID,
                detailNote: "Active reason",
                shotKey: "building|north|panel|1"
            )
        ]
        try fixture.localStore.saveSessionMetadataAtomically(
            propertyID: fixture.propertyID,
            sessionID: fixture.sessionID,
            metadata: metadata
        )

        var resolvedObservation = activeObservation
        resolvedObservation.status = .resolved
        resolvedObservation.resolvedInSessionID = fixture.sessionID
        resolvedObservation.resolutionPhotoRef = "/tmp/active-guided.jpg"
        resolvedObservation.resolutionStatement = "Condition no longer visibly present."
        let persistedObservation = try fixture.localStore.updateObservation(resolvedObservation)

        _ = try fixture.localStore.syncFlaggedObservationUpdateToSessionMetadata(
            propertyID: fixture.propertyID,
            sessionID: fixture.sessionID,
            observation: persistedObservation,
            shotID: shotID,
            trade: "Electrical",
            activeCaptureKind: "follow_up_capture",
            updatedAt: Date(timeIntervalSinceReferenceDate: 130)
        )

        let propertyGuided = try XCTUnwrap(
            fixture.localStore.fetchGuidedShots(propertyID: fixture.propertyID).first(where: { $0.id == shotID })
        )
        XCTAssertEqual(propertyGuided.status, .retired)
        XCTAssertTrue(propertyGuided.isRetired)
        XCTAssertEqual(propertyGuided.retiredInSessionID, fixture.sessionID)

        let reloaded = try fixture.localStore.loadSessionMetadata(
            propertyID: fixture.propertyID,
            sessionID: fixture.sessionID
        )
        let metadataGuided = try XCTUnwrap(reloaded.guidedShots.first(where: { $0.id == shotID }))
        XCTAssertEqual(metadataGuided.status, .retired)
        XCTAssertTrue(metadataGuided.isRetired)
        XCTAssertEqual(metadataGuided.retiredInSessionID, fixture.sessionID)
    }

    func testResolvedFlaggedObservationRetiresOlderActiveGuidedDuplicateByGuidedKey() throws {
        let fixture = try makeLocalStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.storageRoot) }

        let issueID = UUID()
        let staleGuidedID = UUID()
        let resolvedShotID = UUID()
        let staleShot = Shot(
            id: staleGuidedID,
            capturedAt: Date(timeIntervalSinceReferenceDate: 100),
            imageLocalIdentifier: "/tmp/stale-active-guided.jpg",
            note: "Stale active reason"
        )
        let staleGuided = GuidedShot(
            id: staleGuidedID,
            title: "Building North Panel",
            building: "Building",
            targetElevation: "North",
            detailType: "Panel",
            angleIndex: 1,
            referenceImageLocalIdentifier: "/tmp/reference.jpg",
            referenceImagePath: "/tmp/reference.jpg",
            shot: staleShot,
            isCompleted: true
        )
        try fixture.localStore.saveGuidedShots([staleGuided], propertyID: fixture.propertyID)

        let observation = Observation(
            id: issueID,
            propertyID: fixture.propertyID,
            sessionID: fixture.sessionID,
            createdAt: Date(timeIntervalSinceReferenceDate: 100),
            updatedAt: Date(timeIntervalSinceReferenceDate: 105),
            statement: "Active reason",
            status: .active,
            linkedShotID: resolvedShotID,
            updatedInSessionID: fixture.sessionID,
            priority: "High",
            currentReason: "Active reason",
            note: "Active reason"
        )
        _ = try fixture.localStore.createObservation(observation)

        var metadata = try fixture.localStore.loadSessionMetadata(
            propertyID: fixture.propertyID,
            sessionID: fixture.sessionID
        )
        metadata.guidedShots = [staleGuided]
        metadata.shots = [
            ShotMetadata(
                shotID: resolvedShotID,
                propertyID: fixture.propertyID,
                sessionID: fixture.sessionID,
                createdAt: Date(timeIntervalSinceReferenceDate: 120),
                capturedAtLocal: nil,
                updatedAt: Date(timeIntervalSinceReferenceDate: 120),
                building: "Building",
                elevation: "North",
                detailType: "Panel",
                angleIndex: 1,
                trade: "Electrical",
                priority: "High",
                shotKey: "building|north|panel|1",
                isGuided: true,
                isFlagged: true,
                issueID: issueID,
                issueStatus: "active",
                captureKind: "captured",
                firstCaptureKind: "captured",
                noteText: "Active reason",
                noteCategory: nil,
                originalFilename: "resolved-guided.jpg",
                originalRelativePath: "Originals/resolved-guided.jpg",
                originalByteSize: 128,
                stampedFilename: nil,
                stampedRelativePath: nil,
                captureMode: nil,
                lens: nil,
                exifOrientation: nil,
                latitude: nil,
                longitude: nil,
                accuracyMeters: nil,
                imageWidth: nil,
                imageHeight: nil
            )
        ]
        metadata.issues = [
            IssueMetadata(
                issueID: issueID,
                issueStatus: "active",
                currentReason: "Active reason",
                firstSeenAt: Date(timeIntervalSinceReferenceDate: 100),
                lastSeenAt: Date(timeIntervalSinceReferenceDate: 120),
                lastCaptureSessionId: fixture.sessionID,
                detailNote: "Active reason",
                shotKey: "building|north|panel|1"
            )
        ]
        try fixture.localStore.saveSessionMetadataAtomically(
            propertyID: fixture.propertyID,
            sessionID: fixture.sessionID,
            metadata: metadata
        )

        var resolvedObservation = observation
        resolvedObservation.status = .resolved
        resolvedObservation.resolvedInSessionID = fixture.sessionID
        resolvedObservation.resolutionPhotoRef = "/tmp/resolved-guided.jpg"
        resolvedObservation.resolutionStatement = "Condition no longer visibly present."
        let persistedObservation = try fixture.localStore.updateObservation(resolvedObservation)

        _ = try fixture.localStore.syncFlaggedObservationUpdateToSessionMetadata(
            propertyID: fixture.propertyID,
            sessionID: fixture.sessionID,
            observation: persistedObservation,
            shotID: resolvedShotID,
            trade: "Electrical",
            activeCaptureKind: "follow_up_capture",
            updatedAt: Date(timeIntervalSinceReferenceDate: 130)
        )

        let propertyGuided = try fixture.localStore.fetchGuidedShots(propertyID: fixture.propertyID)
        XCTAssertEqual(propertyGuided.filter { $0.status != .retired && !$0.isRetired }.count, 0)
        let suppressed = try XCTUnwrap(propertyGuided.first(where: { $0.id == staleGuidedID }))
        XCTAssertEqual(suppressed.status, .retired)
        XCTAssertTrue(suppressed.isRetired)
        XCTAssertEqual(suppressed.retiredInSessionID, fixture.sessionID)

        let reloaded = try fixture.localStore.loadSessionMetadata(
            propertyID: fixture.propertyID,
            sessionID: fixture.sessionID
        )
        XCTAssertEqual(reloaded.guidedShots.filter { $0.status != .retired && !$0.isRetired }.count, 0)
    }

    func testFlaggedObservationReopenSyncClearsResolvedShotAndIssueState() throws {
        let fixture = try makeLocalStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.storageRoot) }

        let issueID = UUID()
        let shotID = UUID()
        let resolvedObservation = Observation(
            id: issueID,
            propertyID: fixture.propertyID,
            sessionID: fixture.sessionID,
            createdAt: Date(timeIntervalSinceReferenceDate: 100),
            updatedAt: Date(timeIntervalSinceReferenceDate: 105),
            statement: "Resolved reason",
            status: .resolved,
            linkedShotID: shotID,
            resolutionPhotoRef: "resolved-photo",
            resolutionStatement: "Resolved in the field",
            updatedInSessionID: fixture.sessionID,
            resolvedInSessionID: fixture.sessionID,
            priority: "Low",
            currentReason: "Resolved reason",
            note: "Resolved reason"
        )
        _ = try fixture.localStore.createObservation(resolvedObservation)

        var metadata = try fixture.localStore.loadSessionMetadata(
            propertyID: fixture.propertyID,
            sessionID: fixture.sessionID
        )
        metadata.shots = [
            ShotMetadata(
                shotID: shotID,
                propertyID: fixture.propertyID,
                sessionID: fixture.sessionID,
                createdAt: Date(timeIntervalSinceReferenceDate: 100),
                capturedAtLocal: nil,
                updatedAt: Date(timeIntervalSinceReferenceDate: 105),
                building: "Building",
                elevation: "North",
                detailType: "Panel",
                angleIndex: 1,
                trade: "Electrical",
                priority: "Low",
                shotKey: "building|north|panel|1",
                isGuided: false,
                isFlagged: true,
                issueID: issueID,
                issueStatus: "resolved",
                captureKind: "resolved_capture",
                firstCaptureKind: "captured",
                noteText: "Resolved reason",
                noteCategory: nil,
                originalFilename: "resolved.jpg",
                originalRelativePath: "Originals/resolved.jpg",
                originalByteSize: 128,
                stampedFilename: nil,
                stampedRelativePath: nil,
                captureMode: nil,
                lens: nil,
                exifOrientation: nil,
                latitude: nil,
                longitude: nil,
                accuracyMeters: nil,
                imageWidth: nil,
                imageHeight: nil
            )
        ]
        metadata.issues = [
            IssueMetadata(
                issueID: issueID,
                issueStatus: "resolved",
                currentReason: "Resolved reason",
                resolvedAt: Date(timeIntervalSinceReferenceDate: 105),
                resolvedAtLocal: "resolved-local"
            )
        ]
        try fixture.localStore.saveSessionMetadataAtomically(
            propertyID: fixture.propertyID,
            sessionID: fixture.sessionID,
            metadata: metadata
        )

        var reopenedObservation = resolvedObservation
        reopenedObservation.status = .active
        reopenedObservation.resolvedInSessionID = nil
        reopenedObservation.resolutionPhotoRef = nil
        reopenedObservation.resolutionStatement = nil
        reopenedObservation.currentReason = "Retaken flagged reason"
        reopenedObservation.note = "Retaken flagged reason"
        reopenedObservation.statement = "Retaken flagged reason"
        reopenedObservation.priority = "High"
        let persistedObservation = try fixture.localStore.updateObservation(reopenedObservation)

        _ = try fixture.localStore.syncFlaggedObservationUpdateToSessionMetadata(
            propertyID: fixture.propertyID,
            sessionID: fixture.sessionID,
            observation: persistedObservation,
            shotID: shotID,
            trade: "Electrical",
            activeCaptureKind: "retake",
            updatedAt: Date(timeIntervalSinceReferenceDate: 130)
        )

        let persistedObservations = try fixture.localStore.fetchObservations(propertyID: fixture.propertyID)
        XCTAssertEqual(persistedObservations.first?.status, .active)
        XCTAssertNil(persistedObservations.first?.resolvedInSessionID)
        XCTAssertNil(persistedObservations.first?.resolutionPhotoRef)
        XCTAssertNil(persistedObservations.first?.resolutionStatement)

        let reloaded = try fixture.localStore.loadSessionMetadata(
            propertyID: fixture.propertyID,
            sessionID: fixture.sessionID
        )
        let reloadedShot = reloaded.shots.first(where: { $0.shotID == shotID })
        let reloadedIssue = reloaded.issues.first(where: { $0.issueID == issueID })
        XCTAssertEqual(reloadedShot?.isFlagged, true)
        XCTAssertEqual(reloadedShot?.issueStatus, "active")
        XCTAssertEqual(reloadedShot?.captureKind, "retake")
        XCTAssertEqual(reloadedShot?.noteText, "Retaken flagged reason")
        XCTAssertEqual(reloadedShot?.priority, "High")
        XCTAssertNotNil(
            reloadedIssue,
            "Expected issue \(issueID.uuidString), got \(reloaded.issues.map { $0.issueID.uuidString })"
        )
        XCTAssertEqual(reloadedIssue?.issueStatus, "active")
        XCTAssertEqual(reloadedIssue?.currentReason, "Retaken flagged reason")
        XCTAssertNil(reloadedIssue?.resolvedAt)
        XCTAssertNil(reloadedIssue?.resolvedAtLocal)
        XCTAssertEqual(reloaded.flaggedIssues.count, 1)
    }

    func testReopenedFlaggedGuidedObservationKeepsGuidedCarryForwardRowRetired() throws {
        let fixture = try makeLocalStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.storageRoot) }

        let issueID = UUID()
        let shotID = UUID()
        let resolvedShot = Shot(
            id: shotID,
            capturedAt: Date(timeIntervalSinceReferenceDate: 100),
            imageLocalIdentifier: "/tmp/resolved-guided.jpg",
            note: "Resolved reason"
        )
        let resolvedGuided = GuidedShot(
            id: shotID,
            status: .retired,
            title: "Building North Panel",
            building: "Building",
            targetElevation: "North",
            detailType: "Panel",
            angleIndex: 1,
            referenceImageLocalIdentifier: "/tmp/reference.jpg",
            referenceImagePath: "/tmp/reference.jpg",
            shot: resolvedShot,
            isCompleted: true,
            isRetired: true,
            retiredAt: Date(timeIntervalSinceReferenceDate: 110),
            retiredInSessionID: fixture.sessionID
        )
        try fixture.localStore.saveGuidedShots([resolvedGuided], propertyID: fixture.propertyID)

        let resolvedObservation = Observation(
            id: issueID,
            propertyID: fixture.propertyID,
            sessionID: fixture.sessionID,
            createdAt: Date(timeIntervalSinceReferenceDate: 100),
            updatedAt: Date(timeIntervalSinceReferenceDate: 110),
            statement: "Resolved reason",
            status: .resolved,
            linkedShotID: shotID,
            resolutionPhotoRef: "/tmp/resolved-guided.jpg",
            resolutionStatement: "Resolved in the field",
            updatedInSessionID: fixture.sessionID,
            resolvedInSessionID: fixture.sessionID,
            priority: "Low",
            currentReason: "Resolved reason",
            note: "Resolved reason",
            shots: [resolvedShot]
        )
        _ = try fixture.localStore.createObservation(resolvedObservation)

        var metadata = try fixture.localStore.loadSessionMetadata(
            propertyID: fixture.propertyID,
            sessionID: fixture.sessionID
        )
        metadata.guidedShots = [resolvedGuided]
        metadata.shots = [
            ShotMetadata(
                shotID: shotID,
                propertyID: fixture.propertyID,
                sessionID: fixture.sessionID,
                createdAt: Date(timeIntervalSinceReferenceDate: 100),
                capturedAtLocal: nil,
                updatedAt: Date(timeIntervalSinceReferenceDate: 110),
                building: "Building",
                elevation: "North",
                detailType: "Panel",
                angleIndex: 1,
                trade: "Electrical",
                priority: "Low",
                shotKey: "building|north|panel|1",
                isGuided: true,
                isFlagged: false,
                issueID: issueID,
                issueStatus: "resolved",
                captureKind: "resolved_capture",
                firstCaptureKind: "captured",
                noteText: "Resolved reason",
                noteCategory: nil,
                originalFilename: "resolved-guided.jpg",
                originalRelativePath: "Originals/resolved-guided.jpg",
                originalByteSize: 128,
                stampedFilename: nil,
                stampedRelativePath: nil,
                captureMode: nil,
                lens: nil,
                exifOrientation: nil,
                latitude: nil,
                longitude: nil,
                accuracyMeters: nil,
                imageWidth: nil,
                imageHeight: nil
            )
        ]
        metadata.issues = [
            IssueMetadata(
                issueID: issueID,
                issueStatus: "resolved",
                currentReason: "Resolved reason",
                resolvedAt: Date(timeIntervalSinceReferenceDate: 110),
                lastCaptureSessionId: fixture.sessionID,
                detailNote: "Resolved reason",
                shotKey: "building|north|panel|1"
            )
        ]
        try fixture.localStore.saveSessionMetadataAtomically(
            propertyID: fixture.propertyID,
            sessionID: fixture.sessionID,
            metadata: metadata
        )

        var reopenedObservation = resolvedObservation
        reopenedObservation.status = .active
        reopenedObservation.resolvedInSessionID = nil
        reopenedObservation.resolutionPhotoRef = nil
        reopenedObservation.resolutionStatement = nil
        reopenedObservation.currentReason = "Retaken flagged reason"
        reopenedObservation.note = "Retaken flagged reason"
        reopenedObservation.statement = "Retaken flagged reason"
        reopenedObservation.priority = "High"
        let persistedObservation = try fixture.localStore.updateObservation(reopenedObservation)

        _ = try fixture.localStore.syncFlaggedObservationUpdateToSessionMetadata(
            propertyID: fixture.propertyID,
            sessionID: fixture.sessionID,
            observation: persistedObservation,
            shotID: shotID,
            trade: "Electrical",
            activeCaptureKind: "retake",
            updatedAt: Date(timeIntervalSinceReferenceDate: 130)
        )

        let propertyGuided = try XCTUnwrap(
            fixture.localStore.fetchGuidedShots(propertyID: fixture.propertyID).first(where: { $0.id == shotID })
        )
        XCTAssertEqual(propertyGuided.status, .retired)
        XCTAssertTrue(propertyGuided.isRetired)
        XCTAssertNotNil(propertyGuided.retiredAt)
        XCTAssertEqual(propertyGuided.retiredInSessionID, fixture.sessionID)

        let reloaded = try fixture.localStore.loadSessionMetadata(
            propertyID: fixture.propertyID,
            sessionID: fixture.sessionID
        )
        let metadataGuided = try XCTUnwrap(reloaded.guidedShots.first(where: { $0.id == shotID }))
        XCTAssertEqual(metadataGuided.status, .retired)
        XCTAssertTrue(metadataGuided.isRetired)
        XCTAssertEqual(metadataGuided.retiredInSessionID, fixture.sessionID)
        let promotionEvidence = LocalConflictRules.flaggedGuidedPromotionEvidence(
            issueLinkedGuidedShots: reloaded.shots,
            includeResolved: true
        )
        XCTAssertFalse(
            LocalConflictRules.retiredGuidedShotIsRestorable(
                propertyGuided,
                promotionEvidence: promotionEvidence,
                retiredGuidedShots: [propertyGuided]
            )
        )
        let reloadedShot = reloaded.shots.first(where: { $0.shotID == shotID })
        let reloadedIssue = reloaded.issues.first(where: { $0.issueID == issueID })
        XCTAssertEqual(reloadedShot?.isFlagged, true)
        XCTAssertEqual(reloadedShot?.issueStatus, "active")
        XCTAssertEqual(reloadedShot?.captureKind, "retake")
        XCTAssertEqual(reloadedShot?.noteText, "Retaken flagged reason")
        XCTAssertEqual(reloadedShot?.priority, "High")
        XCTAssertEqual(reloadedIssue?.issueStatus, "active")
        XCTAssertEqual(reloadedIssue?.currentReason, "Retaken flagged reason")
        XCTAssertNil(reloadedIssue?.resolvedAt)
        XCTAssertEqual(reloaded.flaggedIssues.count, 1)
    }

    func testRemoteResolvedSnapshotMergeClearsStaleActiveObservationOnReload() throws {
        let fixture = try makeLocalStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.storageRoot) }

        let issueID = UUID()
        let shotID = UUID()
        let staleActiveObservation = Observation(
            id: issueID,
            propertyID: fixture.propertyID,
            sessionID: fixture.sessionID,
            createdAt: Date(timeIntervalSinceReferenceDate: 100),
            updatedAt: Date(timeIntervalSinceReferenceDate: 200),
            statement: "Stale active reason",
            status: .active,
            linkedShotID: shotID,
            updatedInSessionID: nil,
            resolvedInSessionID: nil,
            priority: "High",
            currentReason: "Stale active reason",
            note: "Stale active reason"
        )
        _ = try fixture.localStore.createObservation(staleActiveObservation)

        var metadata = try fixture.localStore.loadSessionMetadata(
            propertyID: fixture.propertyID,
            sessionID: fixture.sessionID
        )
        metadata.shots = [
            ShotMetadata(
                shotID: shotID,
                propertyID: fixture.propertyID,
                sessionID: fixture.sessionID,
                createdAt: Date(timeIntervalSinceReferenceDate: 110),
                capturedAtLocal: nil,
                updatedAt: Date(timeIntervalSinceReferenceDate: 120),
                building: "Building",
                elevation: "North",
                detailType: "Panel",
                angleIndex: 1,
                trade: "Electrical",
                priority: "Low",
                shotKey: "building|north|panel|1",
                isGuided: true,
                isFlagged: false,
                issueID: issueID,
                issueStatus: "resolved",
                captureKind: "resolved_capture",
                firstCaptureKind: "captured",
                noteText: "Resolved reason",
                noteCategory: nil,
                originalFilename: "resolved.jpg",
                originalRelativePath: "Originals/resolved.jpg",
                originalByteSize: 128,
                stampedFilename: nil,
                stampedRelativePath: nil,
                captureMode: nil,
                lens: nil,
                exifOrientation: nil,
                latitude: nil,
                longitude: nil,
                accuracyMeters: nil,
                imageWidth: nil,
                imageHeight: nil
            )
        ]
        metadata.issues = [
            IssueMetadata(
                issueID: issueID,
                issueStatus: "resolved",
                currentReason: "Resolved reason",
                firstSeenAt: Date(timeIntervalSinceReferenceDate: 100),
                lastSeenAt: Date(timeIntervalSinceReferenceDate: 120),
                resolvedAt: Date(timeIntervalSinceReferenceDate: 120),
                lastCaptureSessionId: fixture.sessionID,
                detailNote: "Resolved reason",
                shotKey: "building|north|panel|1"
            )
        ]

        try fixture.localStore.mergeRemoteFlaggedReferenceObservations(
            propertyID: fixture.propertyID,
            sessionID: fixture.sessionID,
            metadata: metadata
        )

        let reloadedObservation = try XCTUnwrap(
            fixture.localStore.fetchObservations(propertyID: fixture.propertyID)
                .first(where: { $0.id == issueID })
        )
        XCTAssertEqual(reloadedObservation.status, .resolved)
        XCTAssertEqual(reloadedObservation.resolvedInSessionID, fixture.sessionID)
        XCTAssertEqual(reloadedObservation.linkedShotID, shotID)
        XCTAssertEqual(reloadedObservation.shots.map(\.id), [shotID])
        XCTAssertEqual(reloadedObservation.currentReason, "Resolved reason")
        XCTAssertEqual(reloadedObservation.priority, "Low")
        XCTAssertEqual(reloadedObservation.updatedAt, Date(timeIntervalSinceReferenceDate: 200))
    }

    func testPendingReviewMetadataShotIsNotActiveFlaggedGuidedIssue() {
        let issueID = UUID()
        let shot = makeShot(
            updatedAt: Date(timeIntervalSinceReferenceDate: 120),
            originalRelativePath: "Originals/pending-review.jpg",
            isGuided: true,
            isFlagged: true,
            issueID: issueID,
            issueStatus: Observation.Status.pendingReview.issueStatusValue,
            captureKind: "resolved_capture"
        )

        XCTAssertFalse(LocalConflictRules.metadataShotRepresentsFlaggedGuidedIssue(shot))
        XCTAssertTrue(
            LocalConflictRules.metadataShotRepresentsFlaggedGuidedIssue(
                shot,
                includeResolved: true
            )
        )
    }
}
