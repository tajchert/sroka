import Foundation

/// A saved article as the app sees it (DECISIONS A3). Mirrors the wire `Item`
/// (`packages/shared/src/model.ts`) plus local state: `offline` and `thumbnailPath`.
/// The wire-only fields `leadImageUrl` and `seq` live in the network/database layers.
public struct Item: Sendable, Hashable, Identifiable {
    public var id: String
    public var url: String
    public var canonicalUrl: String
    public var title: String?
    public var excerpt: String?
    public var siteName: String?
    public var author: String?
    public var lang: String?
    public var leadImageKey: String?
    public var wordCount: Int?
    public var readingMinutes: Int?
    /// Non-nil once the server has a readable content package.
    public var contentId: String?
    public var contentPrivate: Bool
    public var parseStatus: ParseStatus
    /// Short server reason such as `http_404`; only meaningful when `parseStatus == .failed`
    /// (or `paywalled` on a partial copy). Show it through `Vocabulary.failureReason`.
    public var parseError: String?
    public var status: ItemStatus
    public var isFavorite: Bool
    /// Reading progress 0...1.
    public var progress: Double
    /// Index of the first visible block element (`Limits.progressAnchorSelector`).
    public var progressAnchor: Int?
    public var savedAt: Date
    public var archivedAt: Date?
    public var lastReadAt: Date?
    public var source: ItemSource?
    /// Tag names, sorted case-insensitively.
    public var tags: [String]
    public var offline: OfflineState
    /// Local thumbnail file, or nil.
    public var thumbnailPath: URL?
    /// Newest un-pushed local change (R6); only filled by list projections.
    public var pendingChange: PendingChange?
    public var kind: ItemKind
    /// Original file name of a PDF item.
    public var fileName: String?
    /// Size in bytes of the original PDF file.
    public var fileSize: Int64?

    public init(
        id: String,
        url: String,
        canonicalUrl: String? = nil,
        title: String? = nil,
        excerpt: String? = nil,
        siteName: String? = nil,
        author: String? = nil,
        lang: String? = nil,
        leadImageKey: String? = nil,
        wordCount: Int? = nil,
        readingMinutes: Int? = nil,
        contentId: String? = nil,
        contentPrivate: Bool = false,
        parseStatus: ParseStatus = .pending,
        parseError: String? = nil,
        status: ItemStatus = .unread,
        isFavorite: Bool = false,
        progress: Double = 0,
        progressAnchor: Int? = nil,
        savedAt: Date,
        archivedAt: Date? = nil,
        lastReadAt: Date? = nil,
        source: ItemSource? = nil,
        tags: [String] = [],
        offline: OfflineState = .none,
        thumbnailPath: URL? = nil,
        pendingChange: PendingChange? = nil,
        kind: ItemKind = .article,
        fileName: String? = nil,
        fileSize: Int64? = nil
    ) {
        self.id = id
        self.url = url
        self.canonicalUrl = canonicalUrl ?? url
        self.title = title
        self.excerpt = excerpt
        self.siteName = siteName
        self.author = author
        self.lang = lang
        self.leadImageKey = leadImageKey
        self.wordCount = wordCount
        self.readingMinutes = readingMinutes
        self.contentId = contentId
        self.contentPrivate = contentPrivate
        self.parseStatus = parseStatus
        self.parseError = parseError
        self.status = status
        self.isFavorite = isFavorite
        self.progress = progress
        self.progressAnchor = progressAnchor
        self.savedAt = savedAt
        self.archivedAt = archivedAt
        self.lastReadAt = lastReadAt
        self.source = source
        self.tags = tags
        self.offline = offline
        self.thumbnailPath = thumbnailPath
        self.pendingChange = pendingChange
        self.kind = kind
        self.fileName = fileName
        self.fileSize = fileSize
    }

    /// Host without a leading `www.`, for display.
    public var domain: String { displayDomain(url) }

    /// Title for display: the item title or, if absent or blank, the `domain`.
    public var displayTitle: String {
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return title }
        return domain
    }

    /// List-row projection of this item.
    public var summary: ItemSummary {
        ItemSummary(
            id: id,
            displayTitle: displayTitle,
            domain: domain,
            excerpt: excerpt,
            readingMinutes: readingMinutes,
            status: status,
            isFavorite: isFavorite,
            progress: progress,
            parseStatus: parseStatus,
            offline: offline,
            thumbnailPath: thumbnailPath,
            tags: tags,
            savedAt: savedAt,
            pendingChange: pendingChange,
            kind: kind,
            fileSize: fileSize,
            parseError: parseError
        )
    }
}

/// Lightweight list-row projection of `Item` (DECISIONS A3/A4).
public struct ItemSummary: Sendable, Hashable, Identifiable {
    public var id: String
    public var displayTitle: String
    public var domain: String
    public var excerpt: String?
    public var readingMinutes: Int?
    public var status: ItemStatus
    public var isFavorite: Bool
    public var progress: Double
    public var parseStatus: ParseStatus
    public var offline: OfflineState
    public var thumbnailPath: URL?
    public var tags: [String]
    public var savedAt: Date
    /// Newest un-pushed local change to this item, ignoring reading progress (R6).
    public var pendingChange: PendingChange?
    public var kind: ItemKind
    public var fileSize: Int64?
    /// Server parse error code (`paywalled`, `bot_wall`, …), nil if none.
    public var parseError: String?

    public init(
        id: String,
        displayTitle: String,
        domain: String,
        excerpt: String? = nil,
        readingMinutes: Int? = nil,
        status: ItemStatus = .unread,
        isFavorite: Bool = false,
        progress: Double = 0,
        parseStatus: ParseStatus = .ok,
        offline: OfflineState = .none,
        thumbnailPath: URL? = nil,
        tags: [String] = [],
        savedAt: Date,
        pendingChange: PendingChange? = nil,
        kind: ItemKind = .article,
        fileSize: Int64? = nil,
        parseError: String? = nil
    ) {
        self.id = id
        self.displayTitle = displayTitle
        self.domain = domain
        self.excerpt = excerpt
        self.readingMinutes = readingMinutes
        self.status = status
        self.isFavorite = isFavorite
        self.progress = progress
        self.parseStatus = parseStatus
        self.offline = offline
        self.thumbnailPath = thumbnailPath
        self.tags = tags
        self.savedAt = savedAt
        self.pendingChange = pendingChange
        self.kind = kind
        self.fileSize = fileSize
        self.parseError = parseError
    }
}

/// Hostname of `url` without a leading `www.`; empty if `url` has no parsable host.
public func displayDomain(_ url: String) -> String {
    guard let host = UrlNormalizer.hostOf(url) else { return "" }
    return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
}

/// Item ids become file names and reader URLs: `^[A-Za-z0-9_-]{1,64}$`.
public func isValidItemId(_ id: String) -> Bool {
    guard (1...64).contains(id.utf8.count) else { return false }
    return id.utf8.allSatisfy { byte in
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
            || byte == 0x5F || byte == 0x2D
    }
}
