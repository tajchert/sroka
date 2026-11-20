import Foundation
import SrokaCore

/// Why an article's package is not on the device (drives the "Not saved for offline reading" copy).
enum NotDownloadedReason: Sendable, Hashable {
    case offline
    case signIn
    case error
}

/// The raw article document handed to the web view; the view wraps it with theme and restore point.
struct ReaderDocument: Sendable, Equatable {
    var html: String
    var itemId: String
    /// `ContentStore.articlesDirectory()`: the scheme handler serves `articlesDirectory/{itemId}/…`.
    var articlesDirectory: URL
}

/// What the reader screen shows. Mirrors Android's `ReaderUiState`.
enum ReaderState: Sendable, Equatable {
    case loading
    case ready(ReaderDocument)
    /// A PDF item whose document is on disk; shown by the native viewer.
    case pdfReady(URL)
    case downloading
    case notDownloaded(NotDownloadedReason)
    /// The server has not finished parsing.
    case parsePending
    /// `error` is the server's short reason code; show it only through `Vocabulary.failureReason`.
    case parseFailed(error: String?)
    /// The item no longer exists (deleted here or by sync).
    case missing
    /// The web view's content process was terminated by the system.
    case rendererGone
}

/// One-shot notices, shown as a glass toast above the bottom bar.
enum ReaderToast: Sendable, Equatable {
    case refreshed
    case refreshedPartial
    case refreshFailed
    /// The article opened part-way through; offers "Start over". `percent` is 0...100.
    case resumed(percent: Int)
}

/// What the reader asks the app root to do. Other features own those screens, so the reader never
/// presents them itself (BRIEF: cross-feature presentation goes through the app root).
public enum ReaderIntent: Sendable, Equatable {
    /// Leave the reader (pop to the list).
    case close
    /// Show the tag editor for this item.
    case editTags(itemId: String)
    /// Replace the reader with another item ("Up next").
    case openItem(String)
    /// This item was archived: pop, and offer undo.
    case archived(itemId: String)
    /// "Archive & next": this item was archived; open `nextId` in its place and offer undo.
    case archivedAndOpenNext(archivedId: String, nextId: String)
    /// This item was deleted: pop.
    case deleted(itemId: String)
}

/// The reading position shown to the user (and used to restore a recreated web view).
struct RestorePoint: Sendable, Equatable {
    var anchor: Int?
    var progress: Double
}
