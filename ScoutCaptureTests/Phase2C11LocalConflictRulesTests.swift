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
}
