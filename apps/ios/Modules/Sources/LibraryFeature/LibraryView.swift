import SrokaCore
import SrokaDesign
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// My List or Archive: the stateless content plus everything that needs the view model: toast,
/// add sheet, file importer, delete confirmation, share sheet and drops.
///
/// Put it inside the tab's `NavigationStack`; `model.onIntent` asks the app root to open the
/// reader, the tag editor, Settings and sign-in.
public struct LibraryView: View {
    @Bindable private var model: LibraryViewModel
    @State private var clipboardHasLink = false
    @Environment(\.scenePhase) private var scenePhase

    public init(model: LibraryViewModel) {
        self.model = model
    }

    public var body: some View {
        LibraryScreenContent(
            state: model.state,
            actions: actions,
            clipboardHasLink: clipboardHasLink,
            scrollToTopCount: model.scrollToTopCount
        )
        .overlay(alignment: .bottom) { toastOverlay }
        .overlay { dropOverlay }
        .animation(.snappy, value: model.toast?.id)
        .task {
            model.start()
            refreshClipboard()
        }
        .onChange(of: scenePhase) { refreshClipboard() }
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in
            refreshClipboard()
        }
        .onChange(of: model.toast?.id) {
            if let toast = model.toast {
                AccessibilityNotification.Announcement(String(localized: toast.message)).post()
            }
        }
        .sensoryFeedback(.success, trigger: model.successFeedbackCount)
        .sensoryFeedback(.warning, trigger: model.warningFeedbackCount)
        .sheet(isPresented: $model.isAddSheetPresented) { addSheet }
        .sheet(item: $model.shareRequest) { request in
            ShareSheet(url: request.url).presentationDetents([.medium, .large])
        }
        .alert(
            Text("Delete article?", bundle: #bundle),
            isPresented: $model.isConfirmingDelete
        ) {
            Button(role: .cancel) {
                model.cancelDeleteTapped()
            } label: {
                Text("Cancel", bundle: #bundle)
            }
            Button(role: .destructive) {
                Task { await model.confirmDeleteTapped() }
            } label: {
                Text("Delete", bundle: #bundle)
            }
        } message: {
            Text("It will be removed from this device and your account.", bundle: #bundle)
        }
        .dropDestination(for: URL.self) { urls, _ in
            Task { await model.linksDropped(urls) }
            return !urls.isEmpty
        } isTargeted: {
            model.isDropTargeted = $0
        }
        .dropDestination(for: String.self) { strings, _ in
            Task { await model.textDropped(strings) }
            return !strings.isEmpty
        }
    }

    private var addSheet: some View {
        AddLinkSheet(
            text: $model.addLinkText,
            isInvalid: model.isAddLinkInvalid,
            onCancel: model.cancelAddTapped,
            onSave: { Task { await model.saveLinkTapped() } },
            onPaste: model.pasted,
            onChoosePdf: model.choosePdfTapped
        )
        .fileImporter(
            isPresented: $model.isFileImporterPresented,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: true
        ) { result in
            Task { await model.pdfFilesPicked(result) }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder private var toastOverlay: some View {
        if let toast = model.toast {
            GlassToast(
                Text(toast.message),
                actionTitle: toast.action.map { Text($0.title) },
                action: toast.action == nil ? nil : { Task { await model.toastActionTapped() } }
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    @ViewBuilder private var dropOverlay: some View {
        if model.isDropTargeted {
            RoundedRectangle(cornerRadius: SrokaMetrics.largeRadius, style: .continuous)
                .strokeBorder(SrokaColor.primary, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .background(
                    SrokaColor.surfaceContainer.opacity(0.85), in: .rect(cornerRadius: SrokaMetrics.largeRadius)
                )
                .overlay { Text("Drop to save", bundle: #bundle).font(.headline).foregroundStyle(SrokaColor.primary) }
                .padding(16)
                .allowsHitTesting(false)
        }
    }

    private func refreshClipboard() {
        clipboardHasLink = UIPasteboard.general.hasURLs
    }

    private var actions: LibraryActions {
        LibraryActions(
            itemTapped: { model.itemTapped($0) },
            itemAppeared: { model.itemAppeared($0) },
            swiped: { edge, item in Task { await model.swiped(edge, item: item) } },
            archive: { item in Task { await model.archiveTapped(item) } },
            favorite: { item in Task { await model.favoriteTapped(item) } },
            editTags: { model.editTagsTapped($0) },
            shareLink: { item in Task { await model.shareLinkTapped(item) } },
            openOriginal: { item in Task { await model.openOriginalTapped(item) } },
            refreshArticle: { item in Task { await model.refreshArticleTapped(item) } },
            delete: { model.deleteTapped($0) },
            sortChosen: { order in Task { await model.sortChosen(order) } },
            favoritesFilter: { model.favoritesFilterTapped() },
            underTenFilter: { model.underTenFilterTapped() },
            tagChip: { model.tagChipTapped($0) },
            clearFilters: { model.clearFiltersTapped() },
            refresh: { await model.refresh() },
            avatarTapped: { model.avatarTapped() },
            addTapped: { model.addButtonTapped() },
            signInTapped: { model.signInTapped() },
            chromeStepTapped: { model.chromeStepTapped() },
            pasteStepTapped: { model.pasteLinkStepTapped() },
            saveClipboard: { strings in Task { await model.saveClipboardLinkTapped(strings) } },
            dismissUploads: { model.dismissUploadCardTapped() },
            swipeHintFinished: { Task { await model.swipeHintFinished() } }
        )
    }
}
