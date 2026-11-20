import SrokaCore

/// Everything the stateless screen content can ask for. The container wires these to the view
/// model; previews and snapshots use `.none`.
struct LibraryActions {
    var itemTapped: (ItemSummary) -> Void = { _ in }
    var itemAppeared: (ItemSummary) -> Void = { _ in }
    var swiped: (SwipeEdge, ItemSummary) -> Void = { _, _ in }
    var archive: (ItemSummary) -> Void = { _ in }
    var favorite: (ItemSummary) -> Void = { _ in }
    var editTags: (ItemSummary) -> Void = { _ in }
    var shareLink: (ItemSummary) -> Void = { _ in }
    var openOriginal: (ItemSummary) -> Void = { _ in }
    var refreshArticle: (ItemSummary) -> Void = { _ in }
    var delete: (ItemSummary) -> Void = { _ in }
    var sortChosen: (LibrarySortOrder) -> Void = { _ in }
    var favoritesFilter: () -> Void = {}
    var underTenFilter: () -> Void = {}
    var tagChip: (String) -> Void = { _ in }
    var clearFilters: () -> Void = {}
    var refresh: () async -> Void = {}
    var avatarTapped: () -> Void = {}
    var addTapped: () -> Void = {}
    var signInTapped: () -> Void = {}
    var chromeStepTapped: () -> Void = {}
    var pasteStepTapped: () -> Void = {}
    var saveClipboard: ([String]) -> Void = { _ in }
    var dismissUploads: () -> Void = {}
    var swipeHintFinished: () -> Void = {}

    static var none: LibraryActions { LibraryActions() }
}
