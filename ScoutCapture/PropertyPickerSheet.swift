import SwiftUI

struct PropertyPickerSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if appState.properties.isEmpty {
                    ContentUnavailableView(
                        "No Properties",
                        systemImage: "house",
                        description: Text("Add a property to continue.")
                    )
                } else {
                    List(appState.properties) { property in
                        Button {
                            appState.selectProperty(id: property.id)
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(property.name)
                                        .foregroundStyle(.primary)

                                    if let clientName = property.clientName, !clientName.isEmpty {
                                        Text(clientName)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                    if let address = property.address, !address.isEmpty {
                                        Text(address)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                Spacer()

                                if appState.selectedPropertyID == property.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Select Property")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink("Add Property") {
                        AddPropertyView()
                            .environmentObject(appState)
                    }
                }
                #else
                ToolbarItem(placement: .automatic) {
                    NavigationLink("Add Property") {
                        AddPropertyView()
                            .environmentObject(appState)
                    }
                }
                #endif
            }
        }
    }
}
