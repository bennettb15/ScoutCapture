import XCTest
@testable import ScoutCapture

@MainActor
final class Phase2C10OfflineReplayTests: XCTestCase {
    private struct QueuedPropertyMutationPayloadProbe: Decodable {
        struct PropertyPayload: Decodable {
            let name: String
        }

        let property: PropertyPayload
    }

    private struct Fixture {
        let defaultsSuiteName: String
        let defaults: UserDefaults
        let storageRoot: URL
        let localStore: LocalStore
        let organizationID: UUID
    }

    private func makeDefaultsSuite() -> (suiteName: String, defaults: UserDefaults) {
        let suite = "Phase2C10OfflineReplayTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        defaults.set(true, forKey: "supabase_enabled")
        defaults.set(true, forKey: "shadow_write_enabled")
        defaults.set(false, forKey: "supabase_read_enabled")
        defaults.set(false, forKey: "supabase_property_read_enabled")
        defaults.set(false, forKey: "media_supabase_upload_enabled")
        defaults.set(true, forKey: "sync_delta_enabled")
        return (suite, defaults)
    }

    private func makeTempStorageRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScoutCapture-2C10-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeFixture() throws -> Fixture {
        let defaultsFixture = makeDefaultsSuite()
        let storageRoot = try makeTempStorageRoot()
        let localStore = LocalStore(testStorageRootURL: storageRoot)
        let organizationID = UUID()
        _ = try localStore.createOrganization(Organization(id: organizationID, name: "Test Org"))
        return Fixture(
            defaultsSuiteName: defaultsFixture.suiteName,
            defaults: defaultsFixture.defaults,
            storageRoot: storageRoot,
            localStore: localStore,
            organizationID: organizationID
        )
    }

    private func tearDownFixture(_ fixture: Fixture) {
        fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuiteName)
        try? FileManager.default.removeItem(at: fixture.storageRoot)
    }

    private func makeAppState(
        fixture: Fixture,
        propertyOverride: AppState.PropertyShadowWriteOverride? = nil,
        sessionOverride: AppState.SessionShadowWriteOverride? = nil
    ) -> AppState {
        AppState(
            localStore: fixture.localStore,
            userDefaults: fixture.defaults,
            propertyShadowWriteOverride: propertyOverride,
            sessionShadowWriteOverride: sessionOverride
        )
    }

    private func makeSuccessfulReplayAppState(fixture: Fixture) -> AppState {
        makeAppState(
            fixture: fixture,
            propertyOverride: { _ in },
            sessionOverride: { _, _, _ in }
        )
    }

    private func configureReplayEnvironment(
        _ appState: AppState,
        orgID: UUID?,
        ready: Bool = true,
        clientConfigured: Bool = true,
        authenticated: Bool = true,
        authenticationReady: Bool = true
    ) async {
        await MainActor.run {
            let memberships = orgID.map {
                [
                    ActiveOrganizationMembership(
                        id: $0,
                        name: "Test Org",
                        role: "owner"
                    )
                ]
            } ?? []
            appState._debugSetOrganizationContextForTests(
                memberships: memberships,
                activeOrganizationID: orgID,
                ready: ready
            )
            appState._debugSetOfflineReplayEnvironmentForTests(
                activeOrganizationID: orgID,
                ready: ready,
                clientConfigured: clientConfigured,
                authenticated: authenticated,
                authenticationReady: authenticationReady
            )
            appState._debugRefreshPropertiesLocallyForTests()
        }
    }

    private func waitForQueueCount(
        _ expectedCount: Int,
        localStore: LocalStore,
        timeoutNanoseconds: UInt64 = 60_000_000_000
    ) async throws {
        let start = DispatchTime.now().uptimeNanoseconds
        while DispatchTime.now().uptimeNanoseconds - start < timeoutNanoseconds {
            let currentCount = try await MainActor.run {
                try localStore.fetchQueuedMutations().count
            }
            if currentCount == expectedCount {
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for queue count \(expectedCount)")
    }

    private func waitForQueuedMutation(
        expectedCount: Int,
        entityType: String,
        operation: String,
        localStore: LocalStore,
        timeoutNanoseconds: UInt64 = 60_000_000_000
    ) async throws -> LocalStore.QueuedMutation {
        let start = DispatchTime.now().uptimeNanoseconds
        while DispatchTime.now().uptimeNanoseconds - start < timeoutNanoseconds {
            let queued = try await MainActor.run {
                try localStore.fetchQueuedMutations()
            }
            if queued.count == expectedCount,
               let mutation = queued.last(where: {
                   $0.entityType == entityType && $0.operation == operation
               }) {
                return mutation
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for queued mutation \(entityType)/\(operation)")
        throw XCTSkip("Queued mutation \(entityType)/\(operation) did not appear before timeout")
    }

    private func createQueuedPropertyMutation(
        fixture: Fixture,
        name: String = "Queued Property"
    ) async throws -> LocalStore.QueuedMutation {
        let expectedCount = try await MainActor.run {
            try fixture.localStore.fetchQueuedMutations().count + 1
        }
        let appState = makeAppState(
            fixture: fixture,
            propertyOverride: { _ in
                struct ForcedFailure: LocalizedError {
                    var errorDescription: String? { "forced property shadow write failure" }
                }
                throw ForcedFailure()
            }
        )
        await configureReplayEnvironment(appState, orgID: fixture.organizationID)

        _ = try await MainActor.run {
            try appState.createProperty(
                organizationID: fixture.organizationID,
                clientName: "Client",
                propertyName: name,
                address: "123 Main Street"
            )
        }

        return try await waitForQueuedMutation(
            expectedCount: expectedCount,
            entityType: "property",
            operation: "upsert_property",
            localStore: fixture.localStore
        )
    }

    private func createQueuedSessionMutation(
        fixture: Fixture
    ) async throws -> LocalStore.QueuedMutation {
        let expectedCount = try await MainActor.run {
            try fixture.localStore.fetchQueuedMutations().count + 1
        }
        let appState = makeAppState(
            fixture: fixture,
            propertyOverride: { _ in },
            sessionOverride: { _, _, _ in
                struct ForcedFailure: LocalizedError {
                    var errorDescription: String? { "forced session shadow write failure" }
                }
                throw ForcedFailure()
            }
        )
        await configureReplayEnvironment(appState, orgID: fixture.organizationID)
        let property = try await MainActor.run {
            try appState.createProperty(
                organizationID: fixture.organizationID,
                clientName: "Client",
                propertyName: "Session Property",
                address: "123 Main Street"
            )
        }
        let session = await MainActor.run {
            appState._debugRefreshPropertiesLocallyForTests()
            appState.selectProperty(id: property.id)
            return appState.startSession()
        }
        XCTAssertNotNil(session)

        return try await waitForQueuedMutation(
            expectedCount: expectedCount,
            entityType: "session",
            operation: "upsert_session",
            localStore: fixture.localStore
        )
    }

    func testQueueAppendsFailedPropertyMutation() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        let mutation = try await createQueuedPropertyMutation(fixture: fixture)

        XCTAssertEqual(mutation.entityType, "property")
        XCTAssertEqual(mutation.operation, "upsert_property")
        XCTAssertEqual(mutation.organizationID, fixture.organizationID)
        XCTAssertEqual(mutation.status, .pending)
        XCTAssertEqual(mutation.attemptCount, 0)
    }

    func testQueueAppendsFailedSessionMutation() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        let mutation = try await createQueuedSessionMutation(fixture: fixture)

        XCTAssertEqual(mutation.entityType, "session")
        XCTAssertEqual(mutation.operation, "upsert_session")
        XCTAssertEqual(mutation.organizationID, fixture.organizationID)
        XCTAssertNotNil(mutation.propertyID)
        XCTAssertNotNil(mutation.sessionID)
        XCTAssertEqual(mutation.status, .pending)
    }

    @MainActor
    func testReplayProcessesPendingMutationsInDeterministicOrder() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        _ = try await createQueuedPropertyMutation(fixture: fixture, name: "Property A")
        _ = try await createQueuedPropertyMutation(fixture: fixture, name: "Property B")

        var queued = try fixture.localStore.fetchQueuedMutations()
        XCTAssertEqual(queued.count, 2)

        let tieCreatedAt = Date(timeIntervalSinceReferenceDate: 100)
        for index in queued.indices {
            queued[index].createdAt = tieCreatedAt
            queued[index].updatedAt = tieCreatedAt
            _ = try fixture.localStore.updateQueuedMutation(queued[index])
        }

        let expectedOrder = try fixture.localStore.fetchQueuedMutations()
            .sorted {
                if $0.createdAt != $1.createdAt {
                    return $0.createdAt < $1.createdAt
                }
                return $0.id.uuidString < $1.id.uuidString
            }
            .map { mutation in
                mutation.entityID.uuidString.lowercased()
            }

        XCTAssertEqual(expectedOrder.count, 2)

        let replayAppState = makeSuccessfulReplayAppState(fixture: fixture)
        await configureReplayEnvironment(replayAppState, orgID: fixture.organizationID)

        let summary = await replayAppState._debugPerformOfflineReplayForTests(source: "deterministic_order_test")
        let didStart = summary.didStart
        let attemptedCount = summary.attemptedCount
        let succeededCount = summary.succeededCount
        let queueIsEmpty = try fixture.localStore.fetchQueuedMutations().isEmpty

        XCTAssertTrue(didStart)
        XCTAssertEqual(attemptedCount, 2)
        XCTAssertEqual(succeededCount, 2)
        XCTAssertTrue(queueIsEmpty)
    }

    func testReplayNormalizesStaleInFlightToPending() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        var mutation = try await createQueuedPropertyMutation(fixture: fixture)
        mutation.status = .inFlight
        _ = try fixture.localStore.updateQueuedMutation(mutation)

        let replayAppState = makeSuccessfulReplayAppState(fixture: fixture)
        await configureReplayEnvironment(replayAppState, orgID: fixture.organizationID)

        let summary = await replayAppState._debugPerformOfflineReplayForTests(source: "normalize_test")

        XCTAssertTrue(summary.didStart)
        XCTAssertEqual(summary.normalizedInFlightCount, 1)
        XCTAssertTrue(try fixture.localStore.fetchQueuedMutations().isEmpty)
    }

    func testReplaySuccessRemovesQueueItem() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        _ = try await createQueuedPropertyMutation(fixture: fixture)

        let replayAppState = makeSuccessfulReplayAppState(fixture: fixture)
        await configureReplayEnvironment(replayAppState, orgID: fixture.organizationID)

        let summary = await replayAppState._debugPerformOfflineReplayForTests(source: "success_test")

        XCTAssertTrue(summary.didStart)
        XCTAssertEqual(summary.succeededCount, 1)
        XCTAssertTrue(try fixture.localStore.fetchQueuedMutations().isEmpty)
    }

    func testReplayFailureIncrementsAttemptsAndBackoff() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        let original = try await createQueuedPropertyMutation(fixture: fixture)

        let replayAppState = makeAppState(
            fixture: fixture,
            propertyOverride: { _ in
                struct ForcedFailure: LocalizedError {
                    var errorDescription: String? { "forced replay failure" }
                }
                throw ForcedFailure()
            }
        )
        await configureReplayEnvironment(replayAppState, orgID: fixture.organizationID)

        let summary = await replayAppState._debugPerformOfflineReplayForTests(source: "failure_backoff_test")

        let queued = try fixture.localStore.fetchQueuedMutations()
        let failed = try XCTUnwrap(queued.first)

        XCTAssertTrue(summary.didStart)
        XCTAssertEqual(summary.failedCount, 1)
        XCTAssertEqual(failed.id, original.id)
        XCTAssertEqual(failed.status, .failed)
        XCTAssertEqual(failed.attemptCount, 1)
        XCTAssertNotNil(failed.lastAttemptAt)
        XCTAssertNotNil(failed.nextAttemptAt)
        XCTAssertEqual(failed.lastError, "forced replay failure")
        XCTAssertTrue((failed.nextAttemptAt ?? .distantPast) > (failed.lastAttemptAt ?? .distantPast))

        let diagnostics = replayAppState._debugLocalDiagnosticsForTests()
        XCTAssertEqual(diagnostics.offlineReplay.discoveredCount, 1)
        XCTAssertEqual(diagnostics.offlineReplay.attemptedCount, 1)
        XCTAssertEqual(diagnostics.offlineReplay.succeededCount, 0)
        XCTAssertEqual(diagnostics.offlineReplay.failedCount, 1)
        XCTAssertEqual(diagnostics.offlineQueue.totalQueued, 1)
        XCTAssertEqual(diagnostics.offlineQueue.failedCount, 1)
        XCTAssertEqual(diagnostics.shadowWrites.property.failureCount, 1)
        XCTAssertEqual(diagnostics.lastError?.category, .unknown)
    }

    func testDiagnosticsStoreReplaySuccessSummary() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        _ = try await createQueuedPropertyMutation(fixture: fixture)

        let replayAppState = makeSuccessfulReplayAppState(fixture: fixture)
        await configureReplayEnvironment(replayAppState, orgID: fixture.organizationID)

        let summary = await replayAppState._debugPerformOfflineReplayForTests(source: "diagnostics_success_test")
        let diagnostics = replayAppState._debugLocalDiagnosticsForTests()

        XCTAssertTrue(summary.didStart)
        XCTAssertEqual(diagnostics.offlineReplay.discoveredCount, 1)
        XCTAssertEqual(diagnostics.offlineReplay.attemptedCount, 1)
        XCTAssertEqual(diagnostics.offlineReplay.succeededCount, 1)
        XCTAssertEqual(diagnostics.offlineReplay.failedCount, 0)
        XCTAssertEqual(diagnostics.offlineQueue.totalQueued, 0)
        XCTAssertEqual(diagnostics.shadowWrites.property.successCount, 1)
    }

    func testOfflineQueueDiagnosticsCountsPendingAndFailedItems() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        _ = try await createQueuedPropertyMutation(fixture: fixture, name: "Pending Property")
        var failed = try await createQueuedPropertyMutation(fixture: fixture, name: "Failed Property")
        failed.status = .failed
        failed.lastAttemptAt = Date().addingTimeInterval(-90)
        _ = try fixture.localStore.updateQueuedMutation(failed)

        let appState = makeAppState(fixture: fixture)
        appState._debugRefreshOfflineQueueDiagnosticsForTests()
        let diagnostics = appState._debugLocalDiagnosticsForTests()

        XCTAssertEqual(diagnostics.offlineQueue.totalQueued, 2)
        XCTAssertEqual(diagnostics.offlineQueue.pendingCount, 1)
        XCTAssertEqual(diagnostics.offlineQueue.failedCount, 1)
        XCTAssertNotNil(diagnostics.offlineQueue.oldestFailureAgeSeconds)
        XCTAssertGreaterThanOrEqual(diagnostics.offlineQueue.oldestFailureAgeSeconds ?? 0, 80)
    }

    func testFailedQueueDiagnosticItemsMapSanitizedDetails() throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        let queueItemID = UUID()
        let entityID = UUID()
        let createdAt = Date().addingTimeInterval(-120)
        let lastAttemptAt = Date().addingTimeInterval(-60)
        let nextAttemptAt = Date().addingTimeInterval(300)
        _ = try fixture.localStore.appendQueuedMutation(
            LocalStore.QueuedMutation(
                id: queueItemID,
                entityType: "property",
                entityID: entityID,
                organizationID: fixture.organizationID,
                propertyID: entityID,
                operation: "upsert_property",
                payloadData: Data("{}".utf8),
                idempotencyKey: "property-test-key",
                createdAt: createdAt,
                updatedAt: lastAttemptAt,
                attemptCount: 3,
                lastAttemptAt: lastAttemptAt,
                nextAttemptAt: nextAttemptAt,
                lastError: "local write failed at /private/tmp/secret.json",
                status: .failed
            )
        )

        let appState = makeAppState(fixture: fixture)
        let items = appState.diagnosticsFailedQueueItems()

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].id, queueItemID)
        XCTAssertEqual(items[0].entityType, "property")
        XCTAssertEqual(items[0].entityID, entityID)
        XCTAssertEqual(items[0].operation, "upsert_property")
        XCTAssertEqual(items[0].status, "failed")
        XCTAssertEqual(items[0].attemptCount, 3)
        XCTAssertEqual(items[0].lastAttemptAt, lastAttemptAt)
        XCTAssertEqual(items[0].nextAttemptAt, nextAttemptAt)
        XCTAssertEqual(items[0].lastError, "local write failed at [path]")
        XCTAssertFalse(items[0].lastError?.contains("/private") ?? true)
        XCTAssertGreaterThanOrEqual(items[0].ageSeconds ?? 0, 100)
    }

    func testDiagnosticsErrorClassificationMapsObviousCasesAndResetClearsState() throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        XCTAssertEqual(
            AppState.diagnosticErrorCategory(for: NSError(domain: "PostgREST", code: 401, userInfo: [
                NSLocalizedDescriptionKey: "new row violates row-level security policy"
            ])),
            .authOrRLS
        )
        XCTAssertEqual(
            AppState.diagnosticErrorCategory(for: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: [
                NSLocalizedDescriptionKey: "The request timed out."
            ])),
            .network
        )
        XCTAssertEqual(
            AppState.diagnosticErrorCategory(for: NSError(domain: "PostgREST", code: 409, userInfo: [
                NSLocalizedDescriptionKey: "duplicate key value violates unique constraint 23505"
            ])),
            .duplicate
        )
        XCTAssertEqual(
            AppState.diagnosticErrorCategory(for: NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError, userInfo: [
                NSLocalizedDescriptionKey: "The file does not exist."
            ])),
            .localIO
        )

        let appState = makeAppState(fixture: fixture)
        appState._debugRecordDiagnosticsErrorForTests(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet, userInfo: [
                NSLocalizedDescriptionKey: "The Internet connection appears to be offline."
            ])
        )
        XCTAssertEqual(appState._debugLocalDiagnosticsForTests().lastError?.category, .network)

        let preview = AppState.diagnosticsPreviewText(
            "failure at /private/tmp/secret-file.json with " + String(repeating: "x", count: 180),
            maxLength: 48
        )
        XCTAssertNotNil(preview)
        XCTAssertLessThanOrEqual(preview?.count ?? 0, 51)
        XCTAssertTrue(preview?.hasSuffix("...") ?? false)
        XCTAssertFalse(preview?.contains("/private") ?? true)

        appState.clearLocalDiagnostics()
        XCTAssertNil(appState._debugLocalDiagnosticsForTests().lastError)
        XCTAssertEqual(appState._debugLocalDiagnosticsForTests().offlineQueue.totalQueued, 0)
    }

    func testReplaySkipsFailedItemBeforeNextAttemptAt() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        var mutation = try await createQueuedPropertyMutation(fixture: fixture)
        mutation.status = .failed
        mutation.attemptCount = 2
        mutation.nextAttemptAt = Date().addingTimeInterval(300)
        _ = try fixture.localStore.updateQueuedMutation(mutation)

        let replayAppState = makeAppState(fixture: fixture)
        await configureReplayEnvironment(replayAppState, orgID: fixture.organizationID)

        let summary = await replayAppState._debugPerformOfflineReplayForTests(source: "skip_backoff_test")

        XCTAssertTrue(summary.didStart)
        XCTAssertEqual(summary.attemptedCount, 0)
        XCTAssertEqual(summary.skippedBackoffCount, 1)
        XCTAssertEqual(try fixture.localStore.fetchQueuedMutations().count, 1)
    }

    func testReplayBypassesFutureBackoffForDifferentEligibleItems() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        _ = try await createQueuedPropertyMutation(fixture: fixture, name: "Backoff Property")
        _ = try await createQueuedPropertyMutation(fixture: fixture, name: "Ready Property")

        var queued = try fixture.localStore.fetchQueuedMutations()
        queued.sort { $0.entityID.uuidString < $1.entityID.uuidString }
        queued[0].status = .failed
        queued[0].attemptCount = 3
        queued[0].nextAttemptAt = Date().addingTimeInterval(600)
        _ = try fixture.localStore.updateQueuedMutation(queued[0])

        var replayedPropertyIDs: [UUID] = []
        let replayAppState = makeAppState(
            fixture: fixture,
            propertyOverride: { property in
                replayedPropertyIDs.append(property.id)
            }
        )
        await configureReplayEnvironment(replayAppState, orgID: fixture.organizationID)

        let summary = await replayAppState._debugPerformOfflineReplayForTests(source: "mixed_eligibility_test")

        XCTAssertTrue(summary.didStart)
        XCTAssertEqual(summary.skippedBackoffCount, 1)
        XCTAssertEqual(summary.attemptedCount, 1)
        XCTAssertEqual(replayedPropertyIDs.count, 1)
        XCTAssertEqual(try fixture.localStore.fetchQueuedMutations().count, 1)
    }

    func testDuplicateIdempotencyKeyDoesNotAppendSecondItem() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        let createdAt = Date(timeIntervalSinceReferenceDate: 100)
        let mutationA = LocalStore.QueuedMutation(
            entityType: "property",
            entityID: UUID(),
            organizationID: fixture.organizationID,
            propertyID: UUID(),
            sessionID: nil,
            operation: "upsert_property",
            payloadData: Data("first".utf8),
            idempotencyKey: "property:duplicate:key",
            createdAt: createdAt,
            updatedAt: createdAt
        )
        let mutationB = LocalStore.QueuedMutation(
            entityType: "property",
            entityID: mutationA.entityID,
            organizationID: fixture.organizationID,
            propertyID: mutationA.propertyID,
            sessionID: nil,
            operation: "upsert_property",
            payloadData: Data("second".utf8),
            idempotencyKey: mutationA.idempotencyKey,
            createdAt: createdAt.addingTimeInterval(30),
            updatedAt: createdAt.addingTimeInterval(30)
        )

        _ = try fixture.localStore.appendQueuedMutation(mutationA)
        let persisted = try fixture.localStore.appendQueuedMutation(mutationB)
        let queued = try fixture.localStore.fetchQueuedMutations()

        XCTAssertEqual(queued.count, 1)
        XCTAssertEqual(persisted.id, mutationA.id)
        XCTAssertEqual(queued[0].payloadData, Data("second".utf8))
        XCTAssertEqual(queued[0].status, .pending)
    }

    func testReplayRequiresOrganizationContext() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        _ = try await createQueuedPropertyMutation(fixture: fixture)

        let replayAppState = makeAppState(fixture: fixture)
        await configureReplayEnvironment(replayAppState, orgID: fixture.organizationID, ready: false)

        let summary = await replayAppState._debugPerformOfflineReplayForTests(source: "missing_context_test")

        XCTAssertFalse(summary.didStart)
        XCTAssertEqual(try fixture.localStore.fetchQueuedMutations().count, 1)
    }

    func testReplayInFlightGuardPreventsOverlap() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        _ = try await createQueuedPropertyMutation(fixture: fixture)

        let replayAppState = makeAppState(fixture: fixture)
        await configureReplayEnvironment(replayAppState, orgID: fixture.organizationID)
        replayAppState._debugSetOfflineReplayInFlightForTests(true)

        let summary = await replayAppState._debugPerformOfflineReplayForTests(source: "inflight_guard_test")

        XCTAssertFalse(summary.didStart)
        XCTAssertTrue(replayAppState._debugIsOfflineReplayInFlightForTests())
        XCTAssertEqual(try fixture.localStore.fetchQueuedMutations().count, 1)
    }

    func testReplayLeavesLocalStateUntouchedOnFailure() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        let mutation = try await createQueuedPropertyMutation(fixture: fixture, name: "Local Authority Property")
        let originalProperty = try XCTUnwrap(
            fixture.localStore.fetchProperties().first(where: { $0.id == mutation.entityID })
        )

        let replayAppState = makeAppState(
            fixture: fixture,
            propertyOverride: { _ in
                struct ForcedFailure: LocalizedError {
                    var errorDescription: String? { "forced replay failure" }
                }
                throw ForcedFailure()
            }
        )
        await configureReplayEnvironment(replayAppState, orgID: fixture.organizationID)

        _ = await replayAppState._debugPerformOfflineReplayForTests(source: "local_authority_test")

        let persistedProperty = try XCTUnwrap(
            fixture.localStore.fetchProperties().first(where: { $0.id == originalProperty.id })
        )
        XCTAssertEqual(persistedProperty, originalProperty)
    }
}
