import XCTest
@testable import ScoutCapture

final class PropertyListRepositoryTests: XCTestCase {
    @MainActor
    func testSupabaseRowDecodingStaysInsideAdapter() throws {
        let propertyID = UUID()
        let organizationID = UUID()
        let json = """
        {
          "id": "\(propertyID.uuidString)",
          "org_id": "\(organizationID.uuidString)",
          "folder_id": "folder-a",
          "capture_profile": "interior",
          "client_name": "Client",
          "client_email": null,
          "client_phone": null,
          "name": "Test property",
          "address_line1": "123 Main St",
          "city": "New York",
          "state": "NY",
          "postal_code": "10001",
          "baseline_session_id": null,
          "is_archived": false,
          "deleted_at": null,
          "created_at": "2023-11-14T22:13:20Z",
          "updated_at": "2023-11-14T22:13:20Z",
          "updated_by": null,
          "revision": 7
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let row = try decoder.decode(SupabasePropertyRow.self, from: Data(json.utf8))
        let record = row.propertyListRecord
        XCTAssertEqual(record.id, propertyID)
        XCTAssertEqual(record.orgID, organizationID)
        XCTAssertEqual(record.folderID, "folder-a")
        XCTAssertEqual(record.captureProfile, "interior")
        XCTAssertEqual(record.revision, 7)
    }

    @MainActor
    func testInjectedRepositoryServesPropertyListWithoutSupabaseClient() async throws {
        let organizationID = UUID()
        let otherOrganizationID = UUID()
        let propertyID = UUID()
        let updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let record = PropertyListRecord(
            id: propertyID,
            orgID: organizationID,
            folderID: nil,
            captureProfile: "interior",
            clientName: "Client",
            clientEmail: nil,
            clientPhone: nil,
            name: "Test property",
            addressLine1: "123 Main St",
            city: "New York",
            state: "NY",
            postalCode: "10001",
            baselineSessionID: nil,
            isArchived: false,
            deletedAt: nil,
            createdAt: updatedAt,
            updatedAt: updatedAt,
            updatedBy: nil,
            revision: 1
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PropertyListRepositoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "PropertyListRepositoryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let appState = AppState(
            localStore: LocalStore(testStorageRootURL: root),
            userDefaults: defaults,
            environment: [:],
            propertyListRepository: InMemoryPropertyListRepository(records: [record]),
            disableCloudBackupForTests: true
        )
        defer { appState.shutdown() }

        let fetched = try await appState._debugFetchRemotePropertyListForTests(organizationID: organizationID)
        XCTAssertEqual(fetched.map(\.id), [propertyID])
        XCTAssertEqual(fetched.first?.captureProfile, "interior")
        let other = try await appState._debugFetchRemotePropertyListForTests(organizationID: otherOrganizationID)
        XCTAssertTrue(other.isEmpty)
    }
}
