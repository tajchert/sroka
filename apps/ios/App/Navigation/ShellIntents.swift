import AppNavigation
import AuthFeature
import Foundation
import LibraryFeature
import ReaderFeature
import SearchFeature
import SettingsFeature
import TagsFeature
import UIKit

/// Maps every feature's navigation intent onto the router. Features never import each other, so this is the one
/// place that knows which intent opens which destination. Each switch is exhaustive: a new intent case is a
/// compile error here, never a silent no-op.
@MainActor
final class ShellIntents {
    let router: AppRouter
    private let openURL: (URL) -> Void

    init(router: AppRouter, openURL: @escaping (URL) -> Void = { UIApplication.shared.open($0) }) {
        self.router = router
        self.openURL = openURL
    }

    func handle(_ intent: LibraryIntent) {
        switch intent {
        case .openItem(let id): router.open(itemId: id)
        case .editTags(let id): router.presentTagEditor(itemId: id)
        case .openSettings: router.presentSettings()
        case .signInAgain: router.presentSignInAgain()
        case .openURL(let url): openURL(url)
        }
    }

    func handle(_ intent: TagsIntent) {
        switch intent {
        case .openItem(let id): router.open(itemId: id)
        case .editTags(let id): router.presentTagEditor(itemId: id)
        case .openSettings: router.presentSettings()
        case .openURL(let url): openURL(url)
        }
    }

    func handle(_ intent: SearchIntent) {
        switch intent {
        case .openItem(let id): router.open(itemId: id)
        }
    }

    /// `tab` is the tab whose stack holds the reader that sent the intent.
    func handle(_ intent: ReaderIntent, in tab: AppTab) {
        switch intent {
        case .close: router.closeReader(in: tab)
        case .editTags(let itemId): router.presentTagEditor(itemId: itemId)
        case .openItem(let id): router.openNext(itemId: id, in: tab)
        case .archived(let itemId): router.readerArchived(itemId: itemId)
        case .archivedAndOpenNext(let archivedId, let nextId):
            router.readerArchivedAndOpenNext(archivedId: archivedId, nextId: nextId)
        case .deleted(let itemId): router.itemDeleted(itemId)
        }
    }

    func handle(_ intent: SettingsIntent) {
        switch intent {
        case .dismissed:
            router.dismissSheet()
        case .signedOut:
            // The session stream says the same a moment later; resetting now keeps the sheet from lingering.
            router.sessionChanged(.signedOut)
        }
    }

    func handle(_ intent: AuthIntent) {
        switch intent {
        case .signedIn:
            // Plain sign-in flips the root through the session; "sign in again" is a cover over the shell.
            router.signInAgainFinished()
        }
    }
}
