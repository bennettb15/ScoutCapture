import Foundation
@testable import ScoutCapture

struct InMemoryPropertyListRepository: PropertyListRepository {
    let records: [PropertyListRecord]

    func fetchProperties(organizationID: UUID) async throws -> [PropertyListRecord] {
        records.filter { $0.orgID == organizationID }
    }
}
