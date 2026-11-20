/// Contract limits shared by server and clients (`packages/shared/src/limits.ts`, api.md "Limits").
public enum Limits {
    /// Max ops in one POST /v1/sync/push.
    public static let maxOpsPerPush = 500
    /// GET /v1/sync/pull page size.
    public static let defaultPullLimit = 500
    public static let maxPullLimit = 1000
    /// GET /v1/items page size.
    public static let defaultListLimit = 30
    public static let maxListLimit = 100
    public static let maxUrlLength = 4096
    public static let maxTitleLength = 1000
    public static let maxTagLength = 64
    public static let maxTagsPerItem = 100
    public static let maxSearchLength = 200
    /// Rendered HTML sent with POST /v1/items (UTF-8 bytes).
    public static let maxHtmlBytes = 5 * 1024 * 1024
    /// Max request body for POST /v1/items (JSON incl. html).
    public static let maxSaveBodyBytes = 6 * 1024 * 1024
    /// POST /v1/items/pdf body (one PDF file).
    public static let maxPdfBytes: Int64 = 50 * 1024 * 1024
    /// Sum of fileSize over a user's live PDF items; beyond it → 409 storage_full.
    public static let maxPdfStorageBytes: Int64 = 2 * 1024 * 1024 * 1024
    /// PUT /v1/items/:id/thumbnail body.
    public static let maxThumbnailBytes = 512 * 1024
    /// Uploaded file name length (characters).
    public static let maxFileNameLength = 255
    /// Import upload size.
    public static let maxImportBytes: Int64 = 20 * 1024 * 1024
    public static let maxImportItems = 50_000
    /// Server clamps op `at` values further than this into the future.
    public static let maxClockSkewMs: Int64 = 5 * 60 * 1000
    /// Tombstones kept this long; older cursors get 410 resync_required.
    public static let tombstoneTtlMs: Int64 = 180 * 24 * 60 * 60 * 1000
    /// applied_ops idempotency records kept this long.
    public static let appliedOpsTtlMs: Int64 = 30 * 24 * 60 * 60 * 1000
    /// Signed content URL lifetime (seconds).
    public static let contentUrlTtlSec = 24 * 60 * 60

    /// `progressAnchor` counts elements matching this selector (must match web and Android exactly).
    public static let progressAnchorSelector = "p,h1,h2,h3,h4,h5,h6,li,blockquote,pre,figure"

    // MARK: Client-side (Android parity)

    /// Most items the "Continue reading" strip shows.
    public static let continueReadingLimit = 10
    /// Rows added to an observed list window per page (`ItemPage`).
    public static let listPageSize = 50
    /// Recent tags offered as suggestions in the tag editor.
    public static let recentTagsLimit = 10

    /// Reading-time estimate used by the parser: 230 wpm, min 1 minute for non-empty text.
    public static func readingMinutes(wordCount: Int) -> Int {
        wordCount <= 0 ? 0 : max(1, Int((Double(wordCount) / 230).rounded()))
    }

    /// Title as stored and sent: trimmed, at most `maxTitleLength` UTF-16 units (never splitting a
    /// surrogate pair), nil when empty.
    public static func clampTitle(_ title: String?) -> String? {
        guard var units = title.map({ Array($0.trimmingCharactersInWhitespace().utf16) }) else { return nil }
        if units.count > maxTitleLength {
            var end = maxTitleLength
            if UTF16.isLeadSurrogate(units[end - 1]) { end -= 1 }
            units = Array(units[0..<end])
        }
        let result = String(decoding: units, as: UTF16.self).trimmingCharactersInWhitespace()
        return result.isEmpty ? nil : result
    }
}

extension String {
    fileprivate func trimmingCharactersInWhitespace() -> String {
        var scalars = Substring(self).unicodeScalars
        while let first = scalars.first, first.properties.isWhitespace { scalars.removeFirst() }
        while let last = scalars.last, last.properties.isWhitespace { scalars.removeLast() }
        return String(scalars)
    }
}
