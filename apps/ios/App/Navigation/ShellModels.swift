import AppNavigation
import LibraryFeature
import SearchFeature
import SettingsFeature
import TagsFeature

/// The shell's long-lived view models, owned above the compact/regular layout branch so a fold, rotation or
/// Split View change never reloads a list or loses a typed query.
@MainActor
final class ShellModels {
    let intents: ShellIntents
    let myList: LibraryViewModel
    let archive: LibraryViewModel
    let tags: TagsViewModel
    let search: SearchViewModel
    let consent = ConsentPromptViewModel()

    init(router: AppRouter) {
        let intents = ShellIntents(router: router)
        self.intents = intents
        myList = LibraryViewModel(scope: .myList) { intents.handle($0) }
        archive = LibraryViewModel(scope: .archive) { intents.handle($0) }
        tags = TagsViewModel { intents.handle($0) }
        search = SearchViewModel { intents.handle($0) }
    }
}
