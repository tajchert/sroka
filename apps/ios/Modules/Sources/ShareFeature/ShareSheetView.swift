import SrokaCore
import SrokaDesign
import SwiftUI

/// What the app root's tag editor receives. The editor lives in another feature, so the host passes it
/// as a view builder; the editor reports its result through `save` (writes the tags and closes the
/// editor) or `cancel`.
public struct ShareTagEditorContext {
    public let request: ShareTagEditorRequest
    public let save: @MainActor ([String]) async -> Void
    public let cancel: @MainActor () -> Void
}

/// The save sheet of the share extension. Host it in a partial-height sheet over the sharing app.
/// Any touch stops the 4 s auto-dismiss.
public struct ShareSheetView<TagEditor: View>: View {
    @Bindable private var model: ShareViewModel
    private let tagEditor: (ShareTagEditorContext) -> TagEditor

    public init(
        model: ShareViewModel,
        @ViewBuilder tagEditor: @escaping (ShareTagEditorContext) -> TagEditor
    ) {
        self.model = model
        self.tagEditor = tagEditor
    }

    public var body: some View {
        ShareSheetContent(state: model.state, actions: actions)
            .simultaneousGesture(
                DragGesture(minimumDistance: 0).onChanged { _ in model.sheetTouched() }
            )
            .sheet(item: $model.tagEditor) { request in
                tagEditor(
                    ShareTagEditorContext(
                        request: request,
                        save: { names in await model.tagsSaved(itemId: request.itemId, names: names) },
                        cancel: { model.tagEditor = nil }
                    ))
            }
            .sensoryFeedback(.success, trigger: model.state.phase.isSaved)
    }

    private var actions: ShareSheetActions {
        ShareSheetActions(
            tags: { model.tagsButtonTapped() },
            favorite: { Task { await model.favoriteButtonTapped() } },
            open: { Task { await model.openButtonTapped() } },
            close: { Task { await model.closeButtonTapped() } },
            signIn: { Task { await model.signInButtonTapped() } },
            touch: { model.sheetTouched() }
        )
    }
}

extension ShareSheetState.Phase {
    fileprivate var isSaved: Bool {
        if case .saved(_, false) = self { true } else { false }
    }
}
