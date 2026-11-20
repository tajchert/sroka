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

/// One pushed screen on a tab's stack. The router is the only owner of the stacks: the Tags tab asks for a tag's
/// item list (`tagItems`) through an intent, and a reader opened from that list goes on top of it, so back leads
/// to the list.
public enum AppRoute: Hashable, Sendable {
    /// One tag's articles, pushed from the Tags list.
    case tagItems(tag: String)
    case reader(itemId: String)

    /// The item of a reader route; `nil` for every other screen.
    public var readerItemId: String? {
        if case .reader(let itemId) = self { itemId } else { nil }
    }

    /// The tag of a tag item list route; `nil` for every other screen.
    public var tagItemsTag: String? {
        if case .tagItems(let tag) = self { tag } else { nil }
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
    /// shows the selected tab's tag item lists in the content column and its last reader as the detail column.
    public var paths: [AppTab: [AppRoute]] = [:]
    /// The sheet over the shell (Settings or the tag editor).
    public var sheet: AppSheet?
    /// Sign-in-again cover over the shell (the session expired; local data is kept).
    public var isSignInAgainPresented = false
    public private(set) var toast: RouterToast?
    /// `nil` until the first session value arrives, so the shell never flashes the wrong root.
    public private(set) var session: SessionState?
    /// A deep link that arrived while the shell was not available; opened as soon as it is.
    public private(set) var pendingItemId: String?
    /// Changes whenever the session moves to a different account, with or without a sign-out in between; the
    /// root keys its per-account screen models (search query, list state) by it.
    public private(set) var accountGeneration = 0

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
    /// find the previous one's tabs, readers or sheets. The session stream keeps only its newest value, so an
    /// account switch can arrive without the signed-out state in between: a different account resets too, while
    /// the same account signing in again keeps its place.
    public func sessionChanged(_ state: SessionState) {
        let wasShowingShell = showsShell
        let previousAccount = Self.account(of: session)
        session = state
        if let previousAccount, let account = Self.account(of: state), previousAccount != account {
            accountGeneration += 1
            reset()
        }
        switch state {
        case .signedOut:
            // Leaving an account: whoever signs in next (even the same email) starts on fresh screen models.
            if previousAccount != nil { accountGeneration += 1 }
            reset()
        case .signedIn:
            isSignInAgainPresented = false
            openPendingIfPossible()
        case .expired:
            if !wasShowingShell { openPendingIfPossible() }
        }
    }

    /// The account a session belongs to (emails compare case-insensitively); nil when signed out or unknown.
    private static func account(of state: SessionState?) -> String? {
        switch state {
        case .signedIn(let email), .expired(let email): email.lowercased()
        case .signedOut, nil: nil
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
    public subscript(path tab: AppTab) -> [AppRoute] {
        get { paths[tab] ?? [] }
        set { paths[tab] = newValue }
    }

    /// The path of one tab without its reader, for the regular-width content column (the reader is the detail
    /// column there). Popping a screen in the column also closes the reader that sat on top of it.
    public subscript(listPath tab: AppTab) -> [AppRoute] {
        get { (paths[tab] ?? []).filter { $0.readerItemId == nil } }
        set {
            let current = paths[tab] ?? []
            var next = newValue
            if let reader = current.last, reader.readerItemId != nil,
                newValue.count == current.count - 1
            {
                next.append(reader)
            }
            paths[tab] = next
        }
    }

    /// The reader on top of the selected tab, if any. Regular width shows it in the detail column.
    public var presentedReaderItemId: String? { paths[selectedTab]?.last?.readerItemId }

    /// The reader on top of `tab`.
    public func readerItemId(in tab: AppTab) -> String? { paths[tab]?.last?.readerItemId }

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

    /// Puts the reader on top of the tab's stack, replacing a reader that is already there.
    private func push(_ itemId: String, in tab: AppTab) {
        var path = paths[tab] ?? []
        if path.last?.readerItemId != nil { path.removeLast() }
        path.append(.reader(itemId: itemId))
        paths[tab] = path
    }

    /// Pushes one tag's item list on the Tags tab (a re-tap while one is on top replaces it). The reader opened
    /// from that list is pushed on top by `open(itemId:)`.
    public func openTagItems(_ tag: String) {
        guard !tag.isEmpty else { return }
        select(.tags)
        var path = paths[.tags] ?? []
        if path.last?.tagItemsTag != nil { path.removeLast() }
        path.append(.tagItems(tag: tag))
        paths[.tags] = path
    }

    /// The tag no longer exists (renamed or deleted, here or by a sync): its item list would only be empty, so
    /// it leaves every stack. A reader that sits on top of it stays; back then leads to the screen below.
    public func tagGone(_ tag: String) {
        for tab in AppTab.allCases {
            guard var path = paths[tab], path.contains(.tagItems(tag: tag)) else { continue }
            path.removeAll { $0 == .tagItems(tag: tag) }
            paths[tab] = path
        }
    }

    private func openPendingIfPossible() {
        guard let id = pendingItemId else { return }
        open(itemId: id)
    }

    /// Leaves the reader of `tab` (the back button, the reader's own close). Does nothing when the tab shows
    /// another screen on top.
    public func closeReader(in tab: AppTab? = nil) {
        let tab = tab ?? selectedTab
        guard var path = paths[tab], path.last?.readerItemId != nil else { return }
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
        if paths[selectedTab]?.last?.readerItemId == itemId { return selectedTab }
        return AppTab.allCases.first { paths[$0]?.last?.readerItemId == itemId }
    }

    /// Pops every reader showing `itemId`. A tab in `except` keeps its (about to be replaced) top entry.
    private func removeReaders(showing itemId: String, except: AppTab? = nil) {
        for tab in AppTab.allCases where tab != except {
            guard var path = paths[tab], path.contains(.reader(itemId: itemId)) else { continue }
            path.removeAll { $0 == .reader(itemId: itemId) }
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
