import Foundation
import SrokaCore

/// What the save sheet renders. Produced by `ShareViewModel`; the stateless content view and the
/// snapshot tests consume it directly.
public struct ShareSheetState: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// Working; a progress line.
        case saving
        /// Link saved (or re-added when `alreadySaved`).
        case saved(itemId: String, alreadySaved: Bool)
        /// The share holds no web link.
        case noLink
        case needsSignIn
        /// The database was written by a newer app version: "Open Sroka to finish updating".
        case needsApp
        /// The extension could not start its storage for another reason.
        case error
        case pdf(PdfPhase)
    }

    /// The PDF variant, like Android's `PdfShareState`.
    public enum PdfPhase: Equatable, Sendable {
        case working
        /// `count` files were accepted and upload in the background.
        case queued(count: Int)
        /// The server answered and at least one file was already in the library.
        case duplicate
        /// The server answered; all files are new.
        case added(count: Int)
        /// Every file was rejected (or failed); the reason is a plain sentence, never a code.
        case failed(PdfUploadError)
        case noFile
    }

    /// The thin line along the bottom of the sheet that counts the auto-dismiss down.
    public enum Countdown: Equatable, Sendable {
        case hidden
        /// Runs from full to empty over `seconds`; `run` changes whenever the timer restarts.
        case running(seconds: Double, run: Int)
        /// A fixed fraction left (previews and snapshots).
        case frozen(Double)
    }

    public var phase: Phase
    /// The saved item, live (favorite, tags, parse state and progress).
    public var item: Item?
    public var countdown: Countdown

    public init(phase: Phase = .saving, item: Item? = nil, countdown: Countdown = .hidden) {
        self.phase = phase
        self.item = item
        self.countdown = countdown
    }
}

/// Everything the injected tag editor needs. The editor lives in another feature, so the app root
/// supplies it as a view builder; saving goes through `save`, which writes to the library.
public struct ShareTagEditorRequest: Identifiable, Equatable, Sendable {
    public var itemId: String
    public var initialTags: [String]
    /// Recently used tag names, newest first.
    public var suggestions: [String]
    public var id: String { itemId }

    public init(itemId: String, initialTags: [String], suggestions: [String]) {
        self.itemId = itemId
        self.initialTags = initialTags
        self.suggestions = suggestions
    }
}

/// Requests the extension host fulfils.
public enum ShareIntent: Equatable, Sendable {
    /// The sheet is done: complete the extension request.
    case dismiss
    /// Open the app at this URL (`sroka://item/{id}`, or the bare scheme for sign-in), then complete.
    case openURL(URL)
}

/// Whether the extension could start its storage.
public enum ShareStartup: Equatable, Sendable {
    case ready
    /// The shared database needs the app to migrate it first.
    case needsApp
    /// Opening the shared storage failed for another reason.
    case unavailable
}
