import GRDB
import SrokaCore

// Row types of the tables, one to one with Android's `entity/Entities.kt`. Times are epoch
// milliseconds (`Int64`), as on the wire and on Android. Enum columns hold the upper-case literals
// Android stores (`UNREAD`, `ARTICLE`, `QUEUED`, …); unknown values read back as the documented default.

/// One live item (DECISIONS A4). A server tombstone deletes the row.
public struct ItemRecord: Sendable, Hashable {
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
    public var contentId: String?
    public var contentPrivate: Bool
    public var parseStatus: ParseStatus
    public var parseError: String?
    public var status: ItemStatus
    public var isFavorite: Bool
    public var progress: Double
    public var progressAnchor: Int?
    public var savedAt: Int64
    public var archivedAt: Int64?
    public var lastReadAt: Int64?
    /// Wire `source` string (`share`, `web`, …), stored verbatim.
    public var source: String?
    /// Nil until the row was seen from the server (created locally, not yet pushed or pulled).
    public var serverSeq: Int64?
    /// Rowid of this item's `items_fts` row. Allocated by `ItemDao` on first insert; callers pass 0.
    public var ftsRowId: Int64
    /// 1 while a full resync is running and the row was not (yet) pulled again (A8.3).
    public var resyncMark: Int
    public var kind: ItemKind
    public var fileName: String?
    public var fileSize: Int64?

    public init(
        id: String,
        url: String,
        canonicalUrl: String,
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
        savedAt: Int64,
        archivedAt: Int64? = nil,
        lastReadAt: Int64? = nil,
        source: String? = nil,
        serverSeq: Int64? = nil,
        ftsRowId: Int64 = 0,
        resyncMark: Int = 0,
        kind: ItemKind = .article,
        fileName: String? = nil,
        fileSize: Int64? = nil
    ) {
        self.id = id
        self.url = url
        self.canonicalUrl = canonicalUrl
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
        self.serverSeq = serverSeq
        self.ftsRowId = ftsRowId
        self.resyncMark = resyncMark
        self.kind = kind
        self.fileName = fileName
        self.fileSize = fileSize
    }
}

extension ItemRecord: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "items"

    public init(row: Row) {
        self.init(
            id: row["id"],
            url: row["url"],
            canonicalUrl: row["canonical_url"],
            title: row["title"],
            excerpt: row["excerpt"],
            siteName: row["site_name"],
            author: row["author"],
            lang: row["lang"],
            leadImageKey: row["lead_image_key"],
            wordCount: row["word_count"],
            readingMinutes: row["reading_minutes"],
            contentId: row["content_id"],
            contentPrivate: row["content_private"],
            parseStatus: DbEnum.parseStatus(row["parse_status"]),
            parseError: row["parse_error"],
            status: DbEnum.status(row["status"]),
            isFavorite: row["is_favorite"],
            progress: row["progress"],
            progressAnchor: row["progress_anchor"],
            savedAt: row["saved_at"],
            archivedAt: row["archived_at"],
            lastReadAt: row["last_read_at"],
            source: row["source"],
            serverSeq: row["server_seq"],
            ftsRowId: row["fts_rowid"],
            resyncMark: row["resync_mark"],
            kind: DbEnum.kind(row["kind"]),
            fileName: row["file_name"],
            fileSize: row["file_size"]
        )
    }

    public func encode(to container: inout PersistenceContainer) {
        container["id"] = id
        container["url"] = url
        container["canonical_url"] = canonicalUrl
        container["title"] = title
        container["excerpt"] = excerpt
        container["site_name"] = siteName
        container["author"] = author
        container["lang"] = lang
        container["lead_image_key"] = leadImageKey
        container["word_count"] = wordCount
        container["reading_minutes"] = readingMinutes
        container["content_id"] = contentId
        container["content_private"] = contentPrivate
        container["parse_status"] = DbEnum.literal(parseStatus)
        container["parse_error"] = parseError
        container["status"] = DbEnum.literal(status)
        container["is_favorite"] = isFavorite
        container["progress"] = progress
        container["progress_anchor"] = progressAnchor
        container["saved_at"] = savedAt
        container["archived_at"] = archivedAt
        container["last_read_at"] = lastReadAt
        container["source"] = source
        container["server_seq"] = serverSeq
        container["fts_rowid"] = ftsRowId
        container["resync_mark"] = resyncMark
        container["kind"] = DbEnum.literal(kind)
        container["file_name"] = fileName
        container["file_size"] = fileSize
    }
}

/// Tag on an item. `nameKey` = `tagKey(name)` (case-insensitive identity).
public struct ItemTagRecord: Sendable, Hashable, Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "item_tags"

    public var itemId: String
    public var nameKey: String
    public var name: String

    public init(itemId: String, nameKey: String, name: String) {
        self.itemId = itemId
        self.nameKey = nameKey
        self.name = name
    }

    enum CodingKeys: String, CodingKey {
        case itemId = "item_id"
        case nameKey = "name_key"
        case name
    }
}

/// Server tag row from pull (keeps empty tags and their ids).
public struct TagRecord: Sendable, Hashable, Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "tags"

    public var id: String
    public var name: String
    public var nameKey: String

    public init(id: String, name: String, nameKey: String) {
        self.id = id
        self.name = name
        self.nameKey = nameKey
    }

    /// A row whose key is derived from `name`.
    public init(id: String, name: String) {
        self.init(id: id, name: name, nameKey: tagKey(name))
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case nameKey = "name_key"
    }
}

/// Un-pushed local change; `payload` is the exact wire JSON of the op (A7), canonically encoded by
/// the sync layer.
public struct PendingOpRecord: Sendable, Hashable, Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "pending_ops"

    /// Assigned on insert; pass 0 (or nil) when enqueuing.
    public var localSeq: Int64?
    public var opId: String
    /// Nil for tag-level ops (`tag.rename`, `tag.delete`).
    public var itemId: String?
    /// Wire op type, e.g. `item.setStatus`.
    public var type: String
    public var payload: String
    public var createdAt: Int64
    public var attempts: Int
    public var lastError: String?

    public init(
        localSeq: Int64? = nil,
        opId: String,
        itemId: String?,
        type: String,
        payload: String,
        createdAt: Int64,
        attempts: Int = 0,
        lastError: String? = nil
    ) {
        self.localSeq = localSeq
        self.opId = opId
        self.itemId = itemId
        self.type = type
        self.payload = payload
        self.createdAt = createdAt
        self.attempts = attempts
        self.lastError = lastError
    }

    enum CodingKeys: String, CodingKey {
        case localSeq = "local_seq"
        case opId = "op_id"
        case itemId = "item_id"
        case type
        case payload
        case createdAt = "created_at"
        case attempts
        case lastError = "last_error"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        localSeq = inserted.rowID
    }
}

/// The single `sync_state` row (id = 1). A missing row reads as the defaults.
public struct SyncStateRecord: Sendable, Hashable, Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "sync_state"

    public var id: Int
    public var cursor: Int64
    public var lastSuccessAt: Int64?
    public var lastError: String?
    public var fullResync: Bool

    public init(cursor: Int64 = 0, lastSuccessAt: Int64? = nil, lastError: String? = nil, fullResync: Bool = false) {
        self.id = 1
        self.cursor = cursor
        self.lastSuccessAt = lastSuccessAt
        self.lastError = lastError
        self.fullResync = fullResync
    }

    enum CodingKeys: String, CodingKey {
        case id
        case cursor
        case lastSuccessAt = "last_success_at"
        case lastError = "last_error"
        case fullResync = "full_resync"
    }
}

/// State of an item's downloaded package row (A9).
public enum ContentState: String, Sendable, Hashable, CaseIterable, Codable, DatabaseValueConvertible {
    case queued = "QUEUED"
    case downloading = "DOWNLOADING"
    case downloaded = "DOWNLOADED"
    case failed = "FAILED"
}

/// Downloaded-package bookkeeping; files live in the App Group container (A4/A9).
public struct ContentFileRecord: Sendable, Hashable, Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "content_files"

    public var itemId: String
    /// The content version this row describes; a different `items.content_id` makes it stale.
    public var contentId: String
    public var state: ContentState
    public var bytes: Int64
    public var attempts: Int
    public var error: String?
    public var downloadedAt: Int64?
    /// Path of the local thumbnail file, as the content layer stored it.
    public var thumbPath: String?
    /// Failed thumbnail fetches (capped so a broken image is not retried forever).
    public var thumbAttempts: Int

    public init(
        itemId: String,
        contentId: String,
        state: ContentState,
        bytes: Int64 = 0,
        attempts: Int = 0,
        error: String? = nil,
        downloadedAt: Int64? = nil,
        thumbPath: String? = nil,
        thumbAttempts: Int = 0
    ) {
        self.itemId = itemId
        self.contentId = contentId
        self.state = state
        self.bytes = bytes
        self.attempts = attempts
        self.error = error
        self.downloadedAt = downloadedAt
        self.thumbPath = thumbPath
        self.thumbAttempts = thumbAttempts
    }

    enum CodingKeys: String, CodingKey {
        case itemId = "item_id"
        case contentId = "content_id"
        case state
        case bytes
        case attempts
        case error
        case downloadedAt = "downloaded_at"
        case thumbPath = "thumb_path"
        case thumbAttempts = "thumb_attempts"
    }
}

/// Stored literals of the SrokaCore enums (upper case, as Android's Room converters write them).
enum DbEnum {
    static func literal(_ value: ItemStatus) -> String { value.rawValue.uppercased() }
    static func literal(_ value: ParseStatus) -> String { value.rawValue.uppercased() }
    static func literal(_ value: ItemKind) -> String { value.rawValue.uppercased() }

    static func status(_ stored: String?) -> ItemStatus { ItemStatus(wire: stored?.lowercased()) }
    static func parseStatus(_ stored: String?) -> ParseStatus { ParseStatus(wire: stored?.lowercased()) }
    static func kind(_ stored: String?) -> ItemKind { ItemKind(wire: stored?.lowercased()) }
}
