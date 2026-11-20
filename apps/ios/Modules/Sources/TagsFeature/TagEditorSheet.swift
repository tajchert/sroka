import SrokaCore
import SrokaDesign
import SwiftUI

/// The tag editor for one item, as sheet content: "Tags" title, a token field with the item's
/// tags (tap × to remove), recent suggestions and "Create x" as chips, Cancel and Save.
///
/// The app root presents it for the library, the reader and the share extension:
///
/// ```swift
/// .sheet(item: $editorItem) { item in
///     TagEditorSheet(model: TagEditorViewModel(itemId: item.id) { editorItem = nil })
/// }
/// ```
/// It sets its own detents (medium, large) and drag indicator.
public struct TagEditorSheet: View {
    @Bindable private var model: TagEditorViewModel
    @FocusState private var isFieldFocused: Bool

    public init(model: TagEditorViewModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            TagEditorHeader(
                canSave: model.canSave,
                onCancel: { Task { await model.cancelTapped() } },
                onSave: { Task { await model.saveTapped() } }
            )
            ScrollView {
                TagEditorBody(model: model, isFieldFocused: $isFieldFocused)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(Color.clear)
        .task { model.start() }
        .task(id: model.isLoaded) {
            if model.isLoaded && !model.itemIsGone { isFieldFocused = true }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

/// Title row: Cancel, "Tags", Save.
struct TagEditorHeader: View {
    let canSave: Bool
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        ZStack {
            Text("Tags", bundle: #bundle)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            HStack {
                Button(action: onCancel) {
                    Text("Cancel", bundle: #bundle).frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(SrokaColor.primary)
                Spacer()
                Button(action: onSave) {
                    Text("Save", bundle: #bundle).font(.body.weight(.semibold)).padding(.horizontal, 6)
                }
                .saveControl()
                .disabled(!canSave)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }
}

/// The token field and the suggestion chips.
struct TagEditorBody: View {
    @Bindable var model: TagEditorViewModel
    var isFieldFocused: FocusState<Bool>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TagTokenField(
                tags: model.tags,
                draft: $model.draft,
                isEnabled: !model.isAtLimit,
                isFieldFocused: isFieldFocused,
                onRemove: { model.removeTapped($0) },
                onSubmit: { model.addDraftTapped() }
            )
            if !model.suggestionChips.isEmpty {
                FlowLayout(spacing: 8, lineSpacing: 0) {
                    ForEach(model.suggestionChips) { chip in
                        SuggestionChip(chip: chip) { model.suggestionTapped(chip.name) }
                    }
                }
            }
        }
    }
}

/// Outlined field holding one removable token per tag and the text cursor.
struct TagTokenField: View {
    let tags: [String]
    @Binding var draft: String
    let isEnabled: Bool
    var isFieldFocused: FocusState<Bool>.Binding
    let onRemove: (String) -> Void
    let onSubmit: () -> Void

    var body: some View {
        FlowLayout(spacing: 8, lineSpacing: 8) {
            ForEach(tags, id: \.self) { tag in
                TagToken(name: tag) { onRemove(tag) }
            }
            TextField(text: $draft) {
                Text("Add a tag", bundle: #bundle)
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.done)
            .focused(isFieldFocused)
            .onSubmit(onSubmit)
            .disabled(!isEnabled)
            .frame(minWidth: 120, minHeight: 32)
            .accessibilityIdentifier("tagEditor.field")
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .background(SrokaColor.surfaceContainer, in: .rect(cornerRadius: SrokaMetrics.mediumRadius))
        .overlay {
            RoundedRectangle(cornerRadius: SrokaMetrics.mediumRadius, style: .continuous)
                .strokeBorder(
                    isFieldFocused.wrappedValue ? SrokaColor.primary : SrokaColor.outlineVariant,
                    lineWidth: isFieldFocused.wrappedValue ? 2 : 1)
        }
        .contentShape(Rectangle())
        .onTapGesture { isFieldFocused.wrappedValue = true }
    }
}

/// One tag in the field: name and a remove button.
struct TagToken: View {
    let name: String
    let onRemove: () -> Void

    var body: some View {
        Button(action: onRemove) {
            HStack(spacing: 6) {
                Text(name).font(.chip)
                Image(systemName: "xmark").font(.caption2.weight(.bold))
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .foregroundStyle(SrokaColor.onPrimaryContainer)
            .background(SrokaColor.primaryContainer, in: .capsule)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Remove tag \(name)", bundle: #bundle))
    }
}

/// A suggestion under the field: an existing tag or "Create “x”".
struct SuggestionChip: View {
    let chip: TagSuggestionChip
    let action: () -> Void

    var body: some View {
        switch chip {
        case .create(let name):
            FilterChip(
                Text("Create “\(name)”", bundle: #bundle), systemImage: "plus", isSelected: false, action: action)
        case .existing(let name):
            FilterChip(Text(verbatim: name), isSelected: false, action: action)
        }
    }
}
