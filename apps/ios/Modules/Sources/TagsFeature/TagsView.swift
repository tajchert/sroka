import SrokaCore
import SrokaDesign
import SwiftUI

/// What the Tags list asks for; the container maps these onto the view model.
struct TagsActions {
    var tagTapped: (TagCount) -> Void = { _ in }
    var rename: (String) -> Void = { _ in }
    var delete: (String) -> Void = { _ in }
    var avatarTapped: () -> Void = {}
}

/// The Tags tab: the stateless list plus rename sheet and delete confirmation.
///
/// Put it inside the tab's `NavigationStack`; `model.onIntent` asks the app root to push a tag's
/// items (`TagItemsView`), the reader, the tag editor and Settings.
public struct TagsView: View {
    @Bindable private var model: TagsViewModel

    public init(model: TagsViewModel) {
        self.model = model
    }

    public var body: some View {
        TagsScreenContent(tags: model.tags, avatarLetter: model.avatarLetter, actions: actions)
            .task { model.start() }
            .sheet(isPresented: $model.isRenaming) {
                TagRenameSheet(
                    text: $model.renameText,
                    isInvalid: model.isRenameInvalid,
                    onCancel: model.cancelRenameTapped,
                    onSave: { Task { await model.confirmRenameTapped() } }
                )
            }
            .alert(
                Text("Delete tag “\(model.tagPendingDeletion ?? "")”?", bundle: #bundle),
                isPresented: $model.isConfirmingDelete,
                presenting: model.tagPendingDeletion
            ) { tag in
                Button(role: .cancel) {
                    model.cancelDeleteTapped()
                } label: {
                    Text("Cancel", bundle: #bundle)
                }
                Button(role: .destructive) {
                    Task { await model.confirmDeleteTapped(tag) }
                } label: {
                    Text("Delete", bundle: #bundle)
                }
            } message: { _ in
                Text("It is removed from all articles. The articles stay in your library.", bundle: #bundle)
            }
            .sensoryFeedback(.warning, trigger: model.warningFeedbackCount)
    }

    private var actions: TagsActions {
        TagsActions(
            tagTapped: { model.tagTapped($0) },
            rename: { model.renameTapped($0) },
            delete: { model.deleteTapped($0) },
            avatarTapped: { model.avatarTapped() }
        )
    }
}

/// Tag list without any view model: title, avatar button and the rows or the empty state.
/// The owner provides the `NavigationStack`.
struct TagsScreenContent: View {
    let tags: [TagCount]?
    let avatarLetter: String
    let actions: TagsActions

    var body: some View {
        Group {
            if let tags {
                if tags.isEmpty {
                    TagsEmptyView()
                } else {
                    TagsList(tags: tags, actions: actions)
                }
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SrokaColor.background)
        .navigationTitle(Text("Tags", bundle: #bundle))
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                TagsAvatarButton(letter: avatarLetter, action: actions.avatarTapped)
            }
        }
    }
}

/// Leading toolbar button with the account's first letter; opens Settings.
struct TagsAvatarButton: View {
    let letter: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(letter)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(SrokaColor.onTertiaryContainer)
                .frame(width: 32, height: 32)
                .background(SrokaColor.tertiaryContainer, in: .circle)
        }
        .accessibilityLabel(Text("Settings", bundle: #bundle))
    }
}

struct TagsList: View {
    let tags: [TagCount]
    let actions: TagsActions

    var body: some View {
        List(tags) { tag in
            TagRow(tag: tag, actions: actions)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}

/// One tag: icon, name and the number of articles; tap opens them. Rename and Delete sit in the
/// swipe actions, the context menu and VoiceOver actions.
struct TagRow: View {
    let tag: TagCount
    let actions: TagsActions

    var body: some View {
        Button {
            actions.tagTapped(tag)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "tag")
                    .font(.body)
                    .foregroundStyle(SrokaColor.onPrimaryContainer)
                    .frame(width: 38, height: 38)
                    .background(SrokaColor.primaryContainer, in: .circle)
                    .accessibilityHidden(true)
                Text(verbatim: tag.name)
                    .font(.body)
                    .foregroundStyle(SrokaColor.onSurface)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Text(verbatim: tag.count.formatted())
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(SrokaColor.onSurfaceVariant)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(SrokaColor.outline)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(SrokaColor.background)
        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
        .alignmentGuide(.listRowSeparatorLeading) { _ in 72 }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                actions.delete(tag.name)
            } label: {
                Label(String(localized: "Delete", bundle: #bundle), systemImage: "trash")
            }
            Button {
                actions.rename(tag.name)
            } label: {
                Label(String(localized: "Rename", bundle: #bundle), systemImage: "pencil")
            }
            .tint(SrokaColor.primary)
        }
        .contextMenu {
            Button {
                actions.rename(tag.name)
            } label: {
                Label(String(localized: "Rename", bundle: #bundle), systemImage: "pencil")
            }
            Divider()
            Button(role: .destructive) {
                actions.delete(tag.name)
            } label: {
                Label(String(localized: "Delete", bundle: #bundle), systemImage: "trash")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: tag.name))
        .accessibilityValue(Text(verbatim: tag.count.formatted()))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text("Rename", bundle: #bundle)) { actions.rename(tag.name) }
        .accessibilityAction(named: Text("Delete", bundle: #bundle)) { actions.delete(tag.name) }
    }
}

/// "No tags yet".
struct TagsEmptyView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "tag")
                .font(.largeTitle)
                .foregroundStyle(SrokaColor.onSurfaceVariant)
                .accessibilityHidden(true)
            Text("No tags yet", bundle: #bundle)
                .font(.brandHeading(.title3))
                .foregroundStyle(SrokaColor.onSurface)
            Text("Add tags from an article’s menu to organize your library", bundle: #bundle)
                .font(.subheadline)
                .foregroundStyle(SrokaColor.onSurfaceVariant)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
        .padding(.top, 56)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .combine)
    }
}

/// Rename sheet: one field, the invalid-name error, Cancel and Save.
struct TagRenameSheet: View {
    @Binding var text: String
    let isInvalid: Bool
    let onCancel: () -> Void
    let onSave: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ZStack {
                Text("Rename tag", bundle: #bundle)
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
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                TextField(text: $text) {
                    Text("Tag name", bundle: #bundle)
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($isFocused)
                .onSubmit(onSave)
                .padding(12)
                .frame(minHeight: 48)
                .background(SrokaColor.surfaceContainer, in: .rect(cornerRadius: SrokaMetrics.mediumRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: SrokaMetrics.mediumRadius, style: .continuous)
                        .strokeBorder(
                            isInvalid ? SrokaColor.error : (isFocused ? SrokaColor.primary : SrokaColor.outlineVariant),
                            lineWidth: isFocused || isInvalid ? 2 : 1)
                }
                if isInvalid {
                    Text("Tag name can’t be empty or longer than 64 characters", bundle: #bundle)
                        .font(.footnote)
                        .foregroundStyle(SrokaColor.error)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .task { isFocused = true }
        .presentationDetents([.height(220), .medium])
        .presentationDragIndicator(.visible)
    }
}
