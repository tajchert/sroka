import SrokaDesign
import SwiftUI

/// "Add link or PDF": URL field, system paste button (no clipboard permission prompt) and PDF
/// picker. Stateless: the container owns the text and the file importer.
struct AddLinkSheet: View {
    @Binding var text: String
    let isInvalid: Bool
    let onCancel: () -> Void
    let onSave: () -> Void
    let onPaste: ([String]) -> Void
    let onChoosePdf: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                TextField(text: $text) {
                    Text("Link", bundle: #bundle)
                }
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($isFocused)
                .onSubmit(onSave)
                .padding(.horizontal, 14)
                .frame(minHeight: 46)
                .background(SrokaColor.surfaceContainer, in: .rect(cornerRadius: 14, style: .continuous))
                if isInvalid {
                    Text("Enter a valid web address", bundle: #bundle)
                        .font(.footnote)
                        .foregroundStyle(SrokaColor.error)
                }
                HStack(spacing: 8) {
                    PasteLinkButton(onPaste: onPaste)
                    Button(action: onChoosePdf) {
                        Label {
                            Text("Choose PDF file", bundle: #bundle)
                        } icon: {
                            Image(systemName: "doc.richtext")
                        }
                        .frame(minHeight: 36)
                    }
                    .glassControl()
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .background(SrokaColor.surfaceLow)
            .navigationTitle(Text("Add link or PDF", bundle: #bundle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel, action: onCancel) { Text("Cancel", bundle: #bundle) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: onSave) { Text("Save", bundle: #bundle) }
                        .toolbarSaveStyle()
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .task { isFocused = true }
    }
}
