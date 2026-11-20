/// One set of user-facing words shared with web, extension and Android (`packages/shared/src/vocab.ts`,
/// copied exactly). Short labels go in chips / accessibility labels; `*Title` strings are the reader's
/// full-page titles.
public enum Vocabulary {
    public static let pending = "Preparing…"
    public static let pendingTitle = "Preparing article"
    public static let failed = "Couldn't save the text"
    public static let failedTitle = "Couldn't save the text"
    public static let partial = "Partial copy"
    public static let partialTitle = "Partial copy"
    public static let paywalled = "Preview only"
    public static let paywalledTitle = "Preview only"
    public static let downloading = "Downloading"
    public static let notDownloaded = "Not on this device"
    public static let unsynced = "Waiting to sync"
    public static let read = "Read"
    public static let save = "Save"
    public static let saved = "Saved"
    public static let favorites = "Favorites"
    public static let favorite = "Favorite"
    public static let sendCode = "Send code"

    private enum Reason {
        static let blocked = "The site blocks Sroka."
        static let paywalled = "It's for subscribers only."
        static let gone = "The page is gone."
        static let noResponse = "The site didn't respond."
        static let tooLarge = "The page is too large."
        static let notArticle = "It isn't an article."
    }

    private static let exact: [String: String] = [
        "bot_wall": Reason.blocked,
        "render_bot_wall": Reason.blocked,
        "paywalled": Reason.paywalled,
        "http_404": Reason.gone,
        "http_410": Reason.gone,
        "timeout": Reason.noResponse,
        "network": Reason.noResponse,
        "too_many_redirects": Reason.noResponse,
        "bad_redirect": Reason.noResponse,
        "too_large": Reason.tooLarge,
        "render_too_large": Reason.tooLarge,
        "pdf_too_large": Reason.tooLarge,
        "not_html": Reason.notArticle,
    ]

    /// Plain-language reason for an item's `parseError` code (never show the raw code). nil when there
    /// is no code or no sentence for it; callers then show only the title.
    public static func failureReason(_ parseError: String?) -> String? {
        guard let parseError, !parseError.isEmpty else { return nil }
        if let reason = exact[parseError] { return reason }
        if parseError.hasPrefix("http_") { return Reason.noResponse }
        return nil
    }
}
