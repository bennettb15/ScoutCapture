import XCTest
@testable import ScoutCapture

final class Phase2C11LocalConflictRulesTests: XCTestCase {
    private func makeShot(
        shotID: UUID = UUID(),
        updatedAt: Date,
        originalRelativePath: String
    ) -> ShotMetadata {
        ShotMetadata(
            shotID: shotID,
            propertyID: UUID(),
            sessionID: UUID(),
            createdAt: Date(timeIntervalSinceReferenceDate: 10),
            capturedAtLocal: nil,
            updatedAt: updatedAt,
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
        isCompleted: Bool = false
    ) -> GuidedShot {
        GuidedShot(
            id: id,
            title: title,
            shot: nil,
            isCompleted: isCompleted
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
}
