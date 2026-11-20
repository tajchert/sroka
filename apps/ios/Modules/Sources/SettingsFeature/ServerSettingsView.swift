import SrokaDesign
import SwiftUI

/// Custom server entry pushed from Settings (Android `ServerDialog`).
struct ServerSettingsView: View {
    @State var model: ServerSettingsViewModel

    init(model: ServerSettingsViewModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                TextField(text: $model.text) {
                    Text("Server URL", bundle: #bundle)
                }
                .textContentType(.URL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("settings.serverField")
            } header: {
                Text("Server URL", bundle: #bundle)
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    if model.isInvalid {
                        Text("Enter a valid https:// address.", bundle: #bundle)
                            .foregroundStyle(SrokaColor.error)
                            .accessibilityIdentifier("settings.serverError")
                    }
                    Text(
                        "Only change this if you run your own Sroka server. Leave empty to use the default.",
                        bundle: #bundle
                    )
                    if model.isSwitching {
                        Text(
                            "Changing the server signs you out and removes all local data from this device. Unsynced changes are lost.",
                            bundle: #bundle
                        )
                        .foregroundStyle(SrokaColor.error)
                    }
                }
            }
            .listRowBackground(SrokaColor.surfaceLowest)
        }
        .scrollContentBackground(.hidden)
        .background(SrokaColor.background)
        .tint(SrokaColor.brand)
        .navigationTitle(Text("Server", bundle: #bundle))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    Task { await model.saveTapped() }
                } label: {
                    if model.isSwitching {
                        Text("Sign out and switch", bundle: #bundle)
                    } else {
                        Text("Save", bundle: #bundle)
                    }
                }
                .disabled(model.isSaving)
                .accessibilityIdentifier("settings.serverSave")
            }
        }
    }
}
