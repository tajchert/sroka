import Foundation
import GRDB
import SrokaCore

// Read projections and their mapping to SrokaCore models (Android `entity/Rows.kt`).

/// Separator of the `group_concat` tag list (ASCII unit separator).
let tagSeparator: Character = "\u{1F}"

/// Lightweight list-row projection (first 200 characters of the excerpt, tags via group_concat).
public struct ItemSummaryRow: Sendable, Hashable, FetchableRecord {
    public var id: String
    public var title: String?
    public var url: String
    public var excerpt: String?
    public var readingMinutes: Int?
    public var status: ItemStatus
    public var isFavorite: Bool
    public var progress: Double
    public var parseStatus: ParseStatus
    public var savedAt: Int64
    public var contentId: String?
    public var fileContentId: String?
    public var fileState: ContentState?
    public var thumbPath: String?
    public var tags: [String]
    /// Type of the item's newest pending op other than `item.setProgress`, nil if none (R6).
    public var pendingType: String?
    public var kind: ItemKind
    public var fileSize: Int64?
    public var parseError: String?

    public init(row: Row) {
        id = row["id"]
        title = row["title"]
        url = row["url"]
        excerpt = row["excerpt"]
        readingMinutes = row["reading_minutes"]
        status = DbEnum.status(row["status"])
        isFavorite = row["is_favorite"]
        progress = row["progress"]
        parseStatus = DbEnum.parseStatus(row["parse_status"])
        savedAt = row["saved_at"]
        contentId = row["content_id"]
        fileContentId = row["file_content_id"]
        fileState = row["file_state"]
        thumbPath = row["thumb_path"]
        tags = splitTags(row["tags"])
        pendingType = row["pending_type"]
        kind = DbEnum.kind(row["kind"])
        fileSize = row["file_size"]
        parseError = row["parse_error"]
    }

    /// The list model. A relative `thumbPath` resolves against `thumbnailBase`.
    public func toSummary(thumbnailBase: URL? = nil) -> ItemSummary {
        let domain = displayDomain(url)
        let displayTitle: String
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            displayTitle = title
        } else {
            displayTitle = domain
        }
        return ItemSummary(
            id: id,
            displayTitle: displayTitle,
            domain: domain,
            excerpt: excerpt,
            readingMinutes: readingMinutes,
            status: status,
            isFavorite: isFavorite,
            progress: progress,
            parseStatus: parseStatus,
            offline: deriveOffline(contentId: contentId, fileContentId: fileContentId, fileState: fileState),
            thumbnailPath: thumbnailURL(thumbPath, base: thumbnailBase),
            tags: tags,
            savedAt: dateFromMillis(savedAt),
            pendingChange: pendingChange(ofOpType: pendingType),
            kind: kind,
            fileSize: fileSize,
            parseError: parseError
        )
    }
}

/// An item with its tags and offline state, for the reader and detail.
public struct ItemDetailRow: Sendable, Hashable, FetchableRecord {
    public var item: ItemRecord
    public var fileContentId: String?
    public var fileState: ContentState?
    public var thumbPath: String?
    public var tags: [String]

    public init(row: Row) {
        item = ItemRecord(row: row)
        fileContentId = row["file_content_id"]
        fileState = row["file_state"]
        thumbPath = row["thumb_path"]
        tags = splitTags(row["tags"])
    }

    /// The domain model. A relative `thumbPath` resolves against `thumbnailBase`.
    public func toItem(thumbnailBase: URL? = nil) -> Item {
        Item(
            id: item.id,
            url: item.url,
            canonicalUrl: item.canonicalUrl,
            title: item.title,
            excerpt: item.excerpt,
            siteName: item.siteName,
            author: item.author,
            lang: item.lang,
            leadImageKey: item.leadImageKey,
            wordCount: item.wordCount,
            readingMinutes: item.readingMinutes,
            contentId: item.contentId,
            contentPrivate: item.contentPrivate,
            parseStatus: item.parseStatus,
            parseError: item.parseError,
            status: item.status,
            isFavorite: item.isFavorite,
            progress: item.progress,
            progressAnchor: item.progressAnchor,
            savedAt: dateFromMillis(item.savedAt),
            archivedAt: item.archivedAt.map(dateFromMillis),
            lastReadAt: item.lastReadAt.map(dateFromMillis),
            source: item.source.map { ItemSource(wire: $0) },
            tags: tags,
            offline: deriveOffline(contentId: item.contentId, fileContentId: fileContentId, fileState: fileState),
            thumbnailPath: thumbnailURL(thumbPath, base: thumbnailBase),
            kind: item.kind,
            fileName: item.fileName,
            fileSize: item.fileSize
        )
    }
}

/// An item queued for download; `contentId` is the version to fetch.
public struct EligibleDownloadRow: Sendable, Hashable, FetchableRecord {
    public var itemId: String
    public var contentId: String

    public init(itemId: String, contentId: String) {
        self.itemId = itemId
        self.contentId = contentId
    }

    public init(row: Row) {
        itemId = row["item_id"]
        contentId = row["content_id"]
    }
}

/// Maps a `pending_ops.type` (wire op type) to the list flag (R6).
public func pendingChange(ofOpType type: String?) -> PendingChange? {
    switch type {
    case nil: nil
    case "item.add": .save
    case "item.tag": .tags
    case "item.setFavorite": .favorite
    default: .other
    }
}

/// Offline state per A4: no `contentId` on the item → `.none`; no file row, or a row for another
/// content id (stale) → `.availableRemote`; otherwise the row state.
public func deriveOffline(contentId: String?, fileContentId: String?, fileState: ContentState?) -> OfflineState {
    guard let contentId else { return .none }
    guard let fileState, fileContentId == contentId else { return .availableRemote }
    switch fileState {
    case .queued: return .queued
    case .downloading: return .downloading
    case .downloaded: return .downloaded
    case .failed: return .failed
    }
}

/// Epoch milliseconds → `Date`.
public func dateFromMillis(_ millis: Int64) -> Date {
    Date(timeIntervalSince1970: TimeInterval(millis) / 1000)
}

/// `Date` → epoch milliseconds (rounded down).
public func millis(of date: Date) -> Int64 {
    Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
}

func splitTags(_ joined: String?) -> [String] {
    guard let joined, !joined.isEmpty else { return [] }
    return joined.split(separator: tagSeparator, omittingEmptySubsequences: false).map(String.init)
}

private func thumbnailURL(_ path: String?, base: URL?) -> URL? {
    guard let path, !path.isEmpty else { return nil }
    if path.hasPrefix("/") { return URL(filePath: path) }
    guard let base else { return URL(filePath: path) }
    return base.appending(path: path)
}
