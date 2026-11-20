import Foundation
import Observation
import SrokaCore

/// Top-level destinations. Selection lives in the router, above the compact/regular layout branch, so
/// rotating, folding or resizing never loses it.
public enum AppTab: String, Hashable, CaseIterable, Sendable, Identifiable {
    case myList
    case archive
    case tags
    case search

    public var id: Self { self }
}

/// One pushed screen on a tab's stack. Only the reader is pushed by the app root; the Tags tab pushes a tag's
/// item list itself (`TagsView`).
public struct ReaderRoute: Hashable, Sendable {
    public let itemId: String

    public init(itemId: String) {
        self.itemId = itemId
    }
}

/// Partial-height sheets the root presents over whatever is on screen. One at a time.
public enum AppSheet: Hashable, Identifiable, Sendable {
    case settings
    /// The tag editor for one item, from a library row, a tag's item list or the reader.
    case tagEditor(itemId: String)

    public var id: Self { self }
}

/// A short message with at most one action, shown as a glass capsule above the tab bar.
public struct RouterToast: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// The reader archived this item; the action moves it back to My List.
        case archived(itemId: String)
    }

    public let id: Int
    public let kind: Kind
}

/// The state of the app root's navigation: selected tab, one stack path per tab, presented sheets, the
/// sign-in-again cover and the toast. Pure value logic with no UI, so tests cover it without a view.
///
/// The router is owned above the layout branch (compact `TabView` or regular `NavigationSplitView`), and both
/// layouts read the same state. `open(itemId:)` is the entry point for deep links and notifications: it works
/// whether or not the shell is on screen, because a request that arrives while signed out (or before the
/// session is known) is held and applied when the shell appears.
@Observable @MainActor
public final class AppRouter {
    public var selectedTab: AppTab = .myList
    /// The stack path of each tab. Compact width binds these to the tab's `NavigationStack`; regular width
    /// shows the selected tab's last reader as the detail column.
    public var paths: [AppTab: [ReaderRoute]] = [:]
    /// The sheet over the shell (Settings or the tag editor).
    public var sheet: AppSheet?
    /// Sign-in-again cover over the shell (the session expired; local data is kept).
    public var isSignInAgainPresented = false
    public private(set) var toast: RouterToast?
    /// `nil` until the first session value arrives, so the shell never flashes the wrong root.
    public private(set) var session: SessionState?
    /// A deep link that arrived while the shell was not available; opened as soon as it is.
    public private(set) var pendingItemId: String?

    private var nextToastId = 0

    public init(session: SessionState? = nil) {
        self.session = session
    }

    // MARK: Session

    /// Signed-in and expired sessions both show the shell (an expired session keeps its local data).
    public var showsShell: Bool {
        switch session {
        case .signedIn, .expired: true
        case .signedOut, nil: false
        }
    }

    public var showsAuth: Bool { session == .signedOut }

    /// Follows the session. Signing out resets every piece of navigation state; the next account must not
    /// find the previous one's tabs, readers or sheets.
    public func sessionChanged(_ state: SessionState) {
        let wasShowingShell = showsShell
        session = state
        switch state {
        case .signedOut:
            reset()
        case .signedIn:
            isSignInAgainPresented = false
            openPendingIfPossible()
        case .expired:
            if !wasShowingShell { openPendingIfPossible() }
        }
    }

    /// Everything back to a fresh launch (sign-out, account deletion, server switch). A held deep link stays,
    /// so it opens for whoever signs in next.
    public func reset() {
        selectedTab = .myList
        paths = [:]
        sheet = nil
        isSignInAgainPresented = false
        toast = nil
    }

    // MARK: Opening items

    /// The path of one tab, for `NavigationStack(path: $router[path: tab])`.
    public subscript(path tab: AppTab) -> [ReaderRoute] {
        get { paths[tab] ?? [] }
        set { paths[tab] = newValue }
    }

    /// The reader on top of the selected tab, if any. Regular width shows it in the detail column.
    public var presentedReaderItemId: String? { paths[selectedTab]?.last?.itemId }

    /// The reader on top of `tab`.
    public func readerItemId(in tab: AppTab) -> String? { paths[tab]?.last?.itemId }

    /// Opens an item in the reader on the selected tab. Replaces a reader that is already on top (one reader at
    /// a time, as "Up next" does) and closes sheets. Invalid ids are ignored. Without a shell the request is
    /// held until sign-in.
    public func open(itemId: String) {
        guard isValidItemId(itemId) else { return }
        guard showsShell else {
            pendingItemId = itemId
            return
        }
        pendingItemId = nil
        sheet = nil
        push(itemId, in: selectedTab)
    }

    /// "Up next": replaces the reader that is open in `tab` with another item.
    public func openNext(itemId: String, in tab: AppTab? = nil) {
        guard isValidItemId(itemId) else { return }
        push(itemId, in: tab ?? selectedTab)
    }

    private func push(_ itemId: String, in tab: AppTab) {
        var path = paths[tab] ?? []
        if path.last != nil {
            path[path.count - 1] = ReaderRoute(itemId: itemId)
        } else {
            path.append(ReaderRoute(itemId: itemId))
        }
        paths[tab] = path
    }

    private func openPendingIfPossible() {
        guard let id = pendingItemId else { return }
        open(itemId: id)
    }

    /// Leaves the reader of `tab` (the back button, the reader's own close).
    public func closeReader(in tab: AppTab? = nil) {
        let tab = tab ?? selectedTab
        guard var path = paths[tab], !path.isEmpty else { return }
        path.removeLast()
        paths[tab] = path
    }

    // MARK: Reader outcomes

    /// The reader archived its item: leave it and offer undo.
    public func readerArchived(itemId: String) {
        removeReaders(showing: itemId)
        showToast(.archived(itemId: itemId))
    }

    /// "Archive & next": the next item takes the archived item's place, and undo is offered.
    public func readerArchivedAndOpenNext(archivedId: String, nextId: String) {
        guard isValidItemId(nextId) else {
            readerArchived(itemId: archivedId)
            return
        }
        let target = tabShowingReader(archivedId) ?? selectedTab
        removeReaders(showing: archivedId, except: target)
        push(nextId, in: target)
        showToast(.archived(itemId: archivedId))
    }

    /// The item is gone (the reader deleted it, or a sync did): no reader may keep showing it, and an undo
    /// toast for it would revive nothing.
    public func itemDeleted(_ itemId: String) {
        removeReaders(showing: itemId)
        if toast?.kind == .archived(itemId: itemId) { toast = nil }
        if sheet == .tagEditor(itemId: itemId) { sheet = nil }
    }

    private func tabShowingReader(_ itemId: String) -> AppTab? {
        if paths[selectedTab]?.last?.itemId == itemId { return selectedTab }
        return AppTab.allCases.first { paths[$0]?.last?.itemId == itemId }
    }

    /// Pops every reader showing `itemId`. A tab in `except` keeps its (about to be replaced) top entry.
    private func removeReaders(showing itemId: String, except: AppTab? = nil) {
        for tab in AppTab.allCases where tab != except {
            guard var path = paths[tab], path.contains(where: { $0.itemId == itemId }) else { continue }
            path.removeAll { $0.itemId == itemId }
            paths[tab] = path
        }
    }

    // MARK: Tabs

    public func select(_ tab: AppTab) {
        selectedTab = tab
    }

    /// Re-tapping the selected tab pops it to its root.
    public func popToRoot(_ tab: AppTab? = nil) {
        paths[tab ?? selectedTab] = []
    }

    // MARK: Sheets

    public func presentSettings() { sheet = .settings }

    public func presentTagEditor(itemId: String) {
        guard isValidItemId(itemId) else { return }
        sheet = .tagEditor(itemId: itemId)
    }

    public func dismissSheet() { sheet = nil }

    public func presentSignInAgain() {
        guard showsShell else { return }
        isSignInAgainPresented = true
    }

    public func signInAgainFinished() { isSignInAgainPresented = false }

    // MARK: Toast

    private func showToast(_ kind: RouterToast.Kind) {
        nextToastId += 1
        toast = RouterToast(id: nextToastId, kind: kind)
    }

    /// Dismisses the toast with this id (a newer toast is left alone).
    public func dismissToast(id: Int) {
        if toast?.id == id { toast = nil }
    }
}
