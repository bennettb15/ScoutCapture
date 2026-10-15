import SwiftUI
import Combine

// MARK: - Detail Types Model (persisted per mode)

final class DetailTypesModel: ObservableObject {
    static let shared = DetailTypesModel()

    private let userDefaults: UserDefaults

    struct DetailTypeItem: Identifiable, Codable, Equatable {
        var id: UUID = UUID()
        var name: String
    }

    @Published var residentialInteriorTypes: [DetailTypeItem] = []
    @Published var residentialExteriorTypes: [DetailTypeItem] = []
    @Published var commercialInteriorTypes: [DetailTypeItem] = []
    @Published var commercialExteriorTypes: [DetailTypeItem] = []

    @Published var selectedResidentialInterior: String = ""
    @Published var selectedResidentialExterior: String = ""
    @Published var selectedCommercialInterior: String = ""
    @Published var selectedCommercialExterior: String = ""

    private let residentialInteriorTypesKey = "scout.detailTypes.residential.interior.list.v1"
    private let residentialExteriorTypesKey = "scout.detailTypes.residential.exterior.list.v1"
    private let commercialInteriorTypesKey = "scout.detailTypes.commercial.interior.list.v1"
    private let commercialExteriorTypesKey = "scout.detailTypes.commercial.exterior.list.v1"

    private let selectedResidentialInteriorKey = "scout.detailTypes.residential.interior.selected.v1"
    private let selectedResidentialExteriorKey = "scout.detailTypes.residential.exterior.selected.v1"
    private let selectedCommercialInteriorKey = "scout.detailTypes.commercial.interior.selected.v1"
    private let selectedCommercialExteriorKey = "scout.detailTypes.commercial.exterior.selected.v1"

    private let legacyResidentialInteriorTypesKey = "scout.detailTypes.interior.list.v4"
    private let legacyResidentialExteriorTypesKey = "scout.detailTypes.exterior.list.v4"
    private let legacySelectedResidentialInteriorKey = "scout.detailTypes.interior.selected.v4"
    private let legacySelectedResidentialExteriorKey = "scout.detailTypes.exterior.selected.v4"

    private let legacyInteriorTypesKey = "scout.detailTypes.interior.list.v2"
    private let legacyExteriorTypesKey = "scout.detailTypes.exterior.list.v2"
    private let legacySelectedInteriorKey = "scout.detailTypes.interior.selected.v2"
    private let legacySelectedExteriorKey = "scout.detailTypes.exterior.selected.v2"

    private var pendingPersist: DispatchWorkItem?
    private let persistDebounceSeconds: Double = 0.22

    private let defaultResidentialInteriorTypes: [String] = [
        "Overview",
        "Entry / Foyer",
        "Living Room",
        "Sitting room",
        "Kitchen",
        "Guest kitchen",
        "Dining Area",
        "Primary Bedroom",
        "Primary bath",
        "Bedroom 2",
        "Bedroom 3",
        "Bedroom 4",
        "Bedroom 5",
        "Bathroom",
        "Half bath",
        "Guest bathroom",
        "Hallway",
        "Stairs",
        "Basement stairs",
        "Secondary stairs",
        "Laundry",
        "Garage",
        "Mechanical / HVAC",
        "Storage"
    ]

    private let defaultResidentialExteriorTypes: [String] = [
        "Overview",
        "Elevation",
        "Entry / Porch",
        "Window",
        "Roofline",
        "Cladding / Siding",
        "Driveway / Garage",
        "Backyard / Patio",
        "Landscaping",
        "Fence / Gate",
        "Utility / HVAC",
        "Pool / Outdoor Amenities",
        "Sidewalk",
        "Exterior Stairs / Ramp",
        "Downspout",
        "Chimney",
        "Foundation"
    ]

    private let defaultCommercialExteriorTypes: [String] = [
        "Overview",
        "Elevation",
        "Entry",
        "Storefront",
        "Loading Dock",
        "Parking Area",
        "Site Circulation",
        "Signage",
        "Window / Glazing",
        "Roofline",
        "Cladding / Facade",
        "Canopy / Awning",
        "Exterior Stairs / Ramp",
        "Trash / Service Area",
        "Fence / Gate",
        "Utility / HVAC",
        "Mechanical Equipment",
        "Landscape / Hardscape",
        "Downspout",
        "Foundation"
    ]

    private let defaultCommercialInteriorTypes: [String] = [
        "Overview",
        "Lobby / Reception",
        "Corridor",
        "Stairs",
        "Elevator",
        "Office",
        "Conference Room",
        "Open Workspace",
        "Break Room / Kitchenette",
        "Restroom",
        "Storage",
        "Electrical Room",
        "Mechanical Room",
        "IT / Server Room",
        "Janitorial / Service Room",
        "Retail Floor",
        "Suite Entry",
        "Leasing / Amenity Area"
    ]

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        load()
        normalizeDefaultsIfNeeded()
        addNewResidentialInteriorPresetsIfNeeded()
        persistAll()
    }

    private func addNewResidentialInteriorPresetsIfNeeded() {
        let migrationKey = "scout.detailTypes.residential.interior.additions.2026-10-09"
        if !userDefaults.bool(forKey: migrationKey) {
            let additions = ["Sitting room", "Guest kitchen", "Primary bath", "Half bath", "Guest bathroom", "Basement stairs", "Secondary stairs"]
            for name in additions where !residentialInteriorTypes.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                residentialInteriorTypes.append(DetailTypeItem(name: name))
            }
            userDefaults.set(true, forKey: migrationKey)
        }

        let orderKey = "scout.detailTypes.residential.interior.additions.order.2026-10-09"
        guard !userDefaults.bool(forKey: orderKey) else { return }
        let placements = [
            ("Sitting room", "Living Room"),
            ("Guest kitchen", "Kitchen"),
            ("Primary bath", "Primary Bedroom"),
            ("Half bath", "Bathroom"),
            ("Guest bathroom", "Half bath"),
            ("Basement stairs", "Stairs"),
            ("Secondary stairs", "Basement stairs")
        ]
        for (name, anchor) in placements {
            guard let index = residentialInteriorTypes.firstIndex(where: { $0.name == name }),
                  let anchorIndex = residentialInteriorTypes.firstIndex(where: { $0.name == anchor }) else { continue }
            let item = residentialInteriorTypes.remove(at: index)
            residentialInteriorTypes.insert(item, at: min(anchorIndex + (index < anchorIndex ? 0 : 1), residentialInteriorTypes.count))
        }
        userDefaults.set(true, forKey: orderKey)
    }

    func types(for mode: ContentView.LocationMode, profile: CaptureProfile) -> [DetailTypeItem] {
        switch (profile, mode) {
        case (.residential, .interior): residentialInteriorTypes
        case (.residential, .exterior): residentialExteriorTypes
        case (.commercial, .interior): commercialInteriorTypes
        case (.commercial, .exterior): commercialExteriorTypes
        }
    }

    func selected(for mode: ContentView.LocationMode, profile: CaptureProfile) -> String {
        switch (profile, mode) {
        case (.residential, .interior): selectedResidentialInterior
        case (.residential, .exterior): selectedResidentialExterior
        case (.commercial, .interior): selectedCommercialInterior
        case (.commercial, .exterior): selectedCommercialExterior
        }
    }

    func setSelected(_ value: String, for mode: ContentView.LocationMode, profile: CaptureProfile) {
        switch (profile, mode) {
        case (.residential, .interior): selectedResidentialInterior = value
        case (.residential, .exterior): selectedResidentialExterior = value
        case (.commercial, .interior): selectedCommercialInterior = value
        case (.commercial, .exterior): selectedCommercialExterior = value
        }
        persistSelected()
    }

    func resetSelectionsToOverview(for profile: CaptureProfile) {
        let interiorOverview = types(for: .interior, profile: profile).first { $0.name == "Overview" }?.name
            ?? types(for: .interior, profile: profile).first?.name
            ?? ""
        let exteriorOverview = types(for: .exterior, profile: profile).first { $0.name == "Overview" }?.name
            ?? types(for: .exterior, profile: profile).first?.name
            ?? ""
        setSelected(interiorOverview, for: ContentView.LocationMode.interior, profile: profile)
        setSelected(exteriorOverview, for: ContentView.LocationMode.exterior, profile: profile)
    }

    @discardableResult
    func insertBlankItem(for mode: ContentView.LocationMode, profile: CaptureProfile) -> UUID {
        let newItem = DetailTypeItem(name: "")
        switch (profile, mode) {
        case (.residential, .interior): residentialInteriorTypes.append(newItem)
        case (.residential, .exterior): residentialExteriorTypes.append(newItem)
        case (.commercial, .interior): commercialInteriorTypes.append(newItem)
        case (.commercial, .exterior): commercialExteriorTypes.append(newItem)
        }
        persistAll()
        return newItem.id
    }

    func updateItem(_ value: String, id: UUID, for mode: ContentView.LocationMode, profile: CaptureProfile) {
        let cleaned = value.trimmingCharacters(in: .newlines)

        switch (profile, mode) {
        case (.residential, .interior):
            guard let idx = residentialInteriorTypes.firstIndex(where: { $0.id == id }) else { return }
            residentialInteriorTypes[idx].name = cleaned
        case (.residential, .exterior):
            guard let idx = residentialExteriorTypes.firstIndex(where: { $0.id == id }) else { return }
            residentialExteriorTypes[idx].name = cleaned
        case (.commercial, .interior):
            guard let idx = commercialInteriorTypes.firstIndex(where: { $0.id == id }) else { return }
            commercialInteriorTypes[idx].name = cleaned
        case (.commercial, .exterior):
            guard let idx = commercialExteriorTypes.firstIndex(where: { $0.id == id }) else { return }
            commercialExteriorTypes[idx].name = cleaned
        }

        normalizeDefaultsIfNeeded()
        persistAll()
    }

    func delete(at offsets: IndexSet, for mode: ContentView.LocationMode, profile: CaptureProfile) {
        switch (profile, mode) {
        case (.residential, .interior):
            let deleting = offsets.compactMap { residentialInteriorTypes.indices.contains($0) ? residentialInteriorTypes[$0].name : nil }
            residentialInteriorTypes.remove(atOffsets: offsets)
            if deleting.contains(selectedResidentialInterior) { selectedResidentialInterior = residentialInteriorTypes.first?.name ?? "" }
        case (.residential, .exterior):
            let deleting = offsets.compactMap { residentialExteriorTypes.indices.contains($0) ? residentialExteriorTypes[$0].name : nil }
            residentialExteriorTypes.remove(atOffsets: offsets)
            if deleting.contains(selectedResidentialExterior) { selectedResidentialExterior = residentialExteriorTypes.first?.name ?? "" }
        case (.commercial, .interior):
            let deleting = offsets.compactMap { commercialInteriorTypes.indices.contains($0) ? commercialInteriorTypes[$0].name : nil }
            commercialInteriorTypes.remove(atOffsets: offsets)
            if deleting.contains(selectedCommercialInterior) { selectedCommercialInterior = commercialInteriorTypes.first?.name ?? "" }
        case (.commercial, .exterior):
            let deleting = offsets.compactMap { commercialExteriorTypes.indices.contains($0) ? commercialExteriorTypes[$0].name : nil }
            commercialExteriorTypes.remove(atOffsets: offsets)
            if deleting.contains(selectedCommercialExterior) { selectedCommercialExterior = commercialExteriorTypes.first?.name ?? "" }
        }
        normalizeDefaultsIfNeeded()
        persistAll()
    }

    func move(from source: IndexSet, to destination: Int, for mode: ContentView.LocationMode, profile: CaptureProfile) {
        switch (profile, mode) {
        case (.residential, .interior): residentialInteriorTypes.move(fromOffsets: source, toOffset: destination)
        case (.residential, .exterior): residentialExteriorTypes.move(fromOffsets: source, toOffset: destination)
        case (.commercial, .interior): commercialInteriorTypes.move(fromOffsets: source, toOffset: destination)
        case (.commercial, .exterior): commercialExteriorTypes.move(fromOffsets: source, toOffset: destination)
        }
        schedulePersist()
    }

    private func schedulePersist() {
        pendingPersist?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.normalizeDefaultsIfNeeded()
            self.persistAll()
        }
        pendingPersist = work
        DispatchQueue.main.asyncAfter(deadline: .now() + persistDebounceSeconds, execute: work)
    }

    private func load() {
        residentialInteriorTypes = loadItems(
            key: residentialInteriorTypesKey,
            legacyKeys: [legacyResidentialInteriorTypesKey, legacyInteriorTypesKey]
        )
        residentialExteriorTypes = loadItems(
            key: residentialExteriorTypesKey,
            legacyKeys: [legacyResidentialExteriorTypesKey, legacyExteriorTypesKey]
        )
        commercialInteriorTypes = loadItems(key: commercialInteriorTypesKey, legacyKeys: [])
        commercialExteriorTypes = loadItems(key: commercialExteriorTypesKey, legacyKeys: [])

        selectedResidentialInterior = userDefaults.string(forKey: selectedResidentialInteriorKey)
            ?? userDefaults.string(forKey: legacySelectedResidentialInteriorKey)
            ?? userDefaults.string(forKey: legacySelectedInteriorKey)
            ?? ""

        selectedResidentialExterior = userDefaults.string(forKey: selectedResidentialExteriorKey)
            ?? userDefaults.string(forKey: legacySelectedResidentialExteriorKey)
            ?? userDefaults.string(forKey: legacySelectedExteriorKey)
            ?? ""

        selectedCommercialInterior = userDefaults.string(forKey: selectedCommercialInteriorKey)
            ?? ""

        selectedCommercialExterior = userDefaults.string(forKey: selectedCommercialExteriorKey)
            ?? ""
    }

    private func persistAll() {
        saveItems(residentialInteriorTypes, key: residentialInteriorTypesKey)
        saveItems(residentialExteriorTypes, key: residentialExteriorTypesKey)
        saveItems(commercialInteriorTypes, key: commercialInteriorTypesKey)
        saveItems(commercialExteriorTypes, key: commercialExteriorTypesKey)
        persistSelected()
    }

    private func persistSelected() {
        userDefaults.set(selectedResidentialInterior, forKey: selectedResidentialInteriorKey)
        userDefaults.set(selectedResidentialExterior, forKey: selectedResidentialExteriorKey)
        userDefaults.set(selectedCommercialInterior, forKey: selectedCommercialInteriorKey)
        userDefaults.set(selectedCommercialExterior, forKey: selectedCommercialExteriorKey)
    }

    private func normalizeDefaultsIfNeeded() {
        if residentialInteriorTypes.isEmpty { residentialInteriorTypes = defaultResidentialInteriorTypes.map { DetailTypeItem(name: $0) } }
        if residentialExteriorTypes.isEmpty { residentialExteriorTypes = defaultResidentialExteriorTypes.map { DetailTypeItem(name: $0) } }
        if commercialInteriorTypes.isEmpty { commercialInteriorTypes = defaultCommercialInteriorTypes.map { DetailTypeItem(name: $0) } }
        if commercialExteriorTypes.isEmpty { commercialExteriorTypes = defaultCommercialExteriorTypes.map { DetailTypeItem(name: $0) } }

        if selectedResidentialInterior.isEmpty { selectedResidentialInterior = firstNonEmpty(from: residentialInteriorTypes) ?? (residentialInteriorTypes.first?.name ?? "") }
        if selectedResidentialExterior.isEmpty { selectedResidentialExterior = firstNonEmpty(from: residentialExteriorTypes) ?? (residentialExteriorTypes.first?.name ?? "") }
        if selectedCommercialInterior.isEmpty { selectedCommercialInterior = firstNonEmpty(from: commercialInteriorTypes) ?? (commercialInteriorTypes.first?.name ?? "") }
        if selectedCommercialExterior.isEmpty { selectedCommercialExterior = firstNonEmpty(from: commercialExteriorTypes) ?? (commercialExteriorTypes.first?.name ?? "") }

        if !residentialInteriorTypes.contains(where: { $0.name == selectedResidentialInterior }) { selectedResidentialInterior = firstNonEmpty(from: residentialInteriorTypes) ?? (residentialInteriorTypes.first?.name ?? "") }
        if !residentialExteriorTypes.contains(where: { $0.name == selectedResidentialExterior }) { selectedResidentialExterior = firstNonEmpty(from: residentialExteriorTypes) ?? (residentialExteriorTypes.first?.name ?? "") }
        if !commercialInteriorTypes.contains(where: { $0.name == selectedCommercialInterior }) { selectedCommercialInterior = firstNonEmpty(from: commercialInteriorTypes) ?? (commercialInteriorTypes.first?.name ?? "") }
        if !commercialExteriorTypes.contains(where: { $0.name == selectedCommercialExterior }) { selectedCommercialExterior = firstNonEmpty(from: commercialExteriorTypes) ?? (commercialExteriorTypes.first?.name ?? "") }
    }

    private func firstNonEmpty(from list: [DetailTypeItem]) -> String? {
        list.first(where: { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?.name
    }

    private func loadItems(key: String, legacyKeys: [String]) -> [DetailTypeItem] {
        if let data = userDefaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([DetailTypeItem].self, from: data) {
            return decoded
        }

        for legacyKey in legacyKeys {
            if let legacyData = userDefaults.data(forKey: legacyKey),
               let decodedItems = try? JSONDecoder().decode([DetailTypeItem].self, from: legacyData) {
                return decodedItems
            }

            if let legacyData = userDefaults.data(forKey: legacyKey),
               let decodedStrings = try? JSONDecoder().decode([String].self, from: legacyData) {
                return decodedStrings.map { DetailTypeItem(name: $0) }
            }
        }

        return []
    }

    private func saveItems(_ items: [DetailTypeItem], key: String) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        userDefaults.set(data, forKey: key)
    }
}

private extension CameraChromeLocationMode {
    var detailTypesLocationMode: ContentView.LocationMode {
        switch self {
        case .interior: .interior
        case .exterior: .exterior
        }
    }
}

extension DetailTypesModel {
    func items(for mode: CameraChromeLocationMode, profile: CaptureProfile) -> [DetailTypeItem] {
        types(for: mode.detailTypesLocationMode, profile: profile)
    }

    func names(for mode: CameraChromeLocationMode, profile: CaptureProfile) -> [String] {
        items(for: mode, profile: profile)
            .map(\.name)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    func resetFastLaneSelectionsToOverview(for profile: CaptureProfile) {
        let interiorNames = names(for: .interior, profile: profile)
        let exteriorNames = names(for: .exterior, profile: profile)
        let interiorOverview = interiorNames.first { $0.caseInsensitiveCompare("Overview") == .orderedSame }
            ?? interiorNames.first ?? ""
        let exteriorOverview = exteriorNames.first { $0.caseInsensitiveCompare("Overview") == .orderedSame }
            ?? exteriorNames.first ?? ""
        setSelected(interiorOverview, for: ContentView.LocationMode.interior, profile: profile)
        setSelected(exteriorOverview, for: ContentView.LocationMode.exterior, profile: profile)
    }

    func setSelected(_ value: String, for mode: CameraChromeLocationMode, profile: CaptureProfile) {
        setSelected(value, for: mode.detailTypesLocationMode, profile: profile)
    }

    @discardableResult
    func insertBlankItem(for mode: CameraChromeLocationMode, profile: CaptureProfile) -> UUID {
        insertBlankItem(for: mode.detailTypesLocationMode, profile: profile)
    }

    func updateItem(_ value: String, id: UUID, for mode: CameraChromeLocationMode, profile: CaptureProfile) {
        updateItem(value, id: id, for: mode.detailTypesLocationMode, profile: profile)
    }

    func delete(at offsets: IndexSet, for mode: CameraChromeLocationMode, profile: CaptureProfile) {
        delete(at: offsets, for: mode.detailTypesLocationMode, profile: profile)
    }

    func move(from source: IndexSet, to destination: Int, for mode: CameraChromeLocationMode, profile: CaptureProfile) {
        move(from: source, to: destination, for: mode.detailTypesLocationMode, profile: profile)
    }
}
