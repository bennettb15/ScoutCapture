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
        XCTAssertNotNil(
            reloadedIssue,
            "Expected issue \(issueID.uuidString), got \(reloaded.issues.map { $0.issueID.uuidString })"
        )
        XCTAssertEqual(reloadedIssue?.issueStatus, "active")
        XCTAssertNil(reloadedIssue?.resolvedAt)
        XCTAssertNil(reloadedIssue?.resolvedAtLocal)
        XCTAssertEqual(reloaded.flaggedIssues.count, 1)
    }
}
