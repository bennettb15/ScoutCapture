import SwiftUI

struct AddPropertyView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var clientName: String = ""
    @State private var propertyName: String = ""
    @State private var address: String = ""

    private var canSave: Bool {
        !propertyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Form {
            Section("Client") {
                TextField("Client name", text: $clientName)
            }

            Section("Property") {
                TextField("Property name", text: $propertyName)
                TextField("Address", text: $address)
            }
        }
        .navigationTitle("Add Property")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    let created = appState.createProperty(
                        clientName: clientName,
                        propertyName: propertyName,
                        address: address
                    )

                    if let created {
                        appState.selectProperty(id: created.id)
                        dismiss()
                    }
                }
                .disabled(!canSave)
            }
        }
    }
}
