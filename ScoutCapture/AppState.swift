import Foundation
import Combine

final class AppState: ObservableObject {
    @Published var properties: [Property] = []
    @Published private(set) var isLoading: Bool = true

    @Published var selectedPropertyID: UUID? {
        didSet {
            persistSelectedPropertyID()
        }
    }

    @Published var currentSession: Session?

    var selectedProperty: Property? {
        guard let selectedPropertyID else { return nil }
        return properties.first { $0.id == selectedPropertyID }
    }

    private let localStore: LocalStore
    private let userDefaults: UserDefaults
    private let selectedPropertyDefaultsKey = "scoutcapture.selectedPropertyID"
    private var didLoad = false

    init(
        localStore: LocalStore = LocalStore(),
        userDefaults: UserDefaults = .standard
    ) {
        self.localStore = localStore
        self.userDefaults = userDefaults

        if let rawID = userDefaults.string(forKey: selectedPropertyDefaultsKey) {
            self.selectedPropertyID = UUID(uuidString: rawID)
        } else {
            self.selectedPropertyID = nil
        }

        self.currentSession = nil
    }

    func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        refreshProperties()
    }

    func refreshProperties() {
        isLoading = true
        do {
            properties = try localStore.fetchProperties()

            if let selectedPropertyID, properties.contains(where: { $0.id == selectedPropertyID }) == false {
                self.selectedPropertyID = nil
            }
        } catch {
            properties = []
        }
        isLoading = false
    }

    @discardableResult
    func createProperty(
        clientName: String,
        propertyName: String,
        address: String
    ) -> Property? {
        let cleanedClientName = clientName.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedName = propertyName.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleanedName.isEmpty else { return nil }

        do {
            let property = Property(
                id: UUID(),
                clientName: cleanedClientName.isEmpty ? nil : cleanedClientName,
                name: cleanedName,
                address: cleanedAddress.isEmpty ? nil : cleanedAddress
            )
            let created = try localStore.createProperty(property)
            properties.append(created)
            if selectedPropertyID == nil {
                selectedPropertyID = created.id
            }
            return created
        } catch {
            return nil
        }
    }

    func selectProperty(id: UUID) {
        selectedPropertyID = id
    }

    @discardableResult
    func startSession() -> Session? {
        guard let selectedPropertyID else { return nil }
        if let currentSession, currentSession.endedAt == nil {
            return currentSession
        }

        let session = Session(propertyID: selectedPropertyID, startedAt: Date(), endedAt: nil)
        currentSession = session
        return session
    }

    func finishSession() {
        guard var session = currentSession, session.endedAt == nil else { return }
        session.endedAt = Date()
        currentSession = session
    }

    private func persistSelectedPropertyID() {
        if let selectedPropertyID {
            userDefaults.set(selectedPropertyID.uuidString, forKey: selectedPropertyDefaultsKey)
        } else {
            userDefaults.removeObject(forKey: selectedPropertyDefaultsKey)
        }
    }
}
