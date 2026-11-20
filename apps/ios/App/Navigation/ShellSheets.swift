import AppNavigation
import AuthFeature
import SettingsFeature
import SwiftUI
import TagsFeature

/// Settings and the tag editor, presented over the shell. The sheet's view model is created once per
/// presentation (`@State` in the host), never on every body evaluation.
struct ShellSheetContent: View {
    let sheet: AppSheet
    let router: AppRouter
    let intents: ShellIntents

    var body: some View {
        switch sheet {
        case .settings:
            SettingsHost(intents: intents)
        case .tagEditor(let itemId):
            TagEditorHost(itemId: itemId, router: router)
        }
    }
}

private struct SettingsHost: View {
    @State private var model: SettingsViewModel

    init(intents: ShellIntents) {
        _model = State(initialValue: SettingsViewModel { intents.handle($0) })
    }

    var body: some View {
        SettingsView(model: model)
            .presentationDetents([.large])
    }
}

private struct TagEditorHost: View {
    @State private var model: TagEditorViewModel

    init(itemId: String, router: AppRouter) {
        _model = State(initialValue: TagEditorViewModel(itemId: itemId) { router.dismissSheet() })
    }

    var body: some View {
        TagEditorSheet(model: model)
    }
}

/// Sign-in for the signed-out root and, as a cover, for an expired session ("sign in again").
struct AuthRoot: View {
    @State private var model: AuthViewModel

    init(intents: ShellIntents) {
        _model = State(initialValue: AuthViewModel { intents.handle($0) })
    }

    var body: some View {
        AuthView(model: model)
    }
}
