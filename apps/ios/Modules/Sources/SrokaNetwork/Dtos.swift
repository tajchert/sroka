import Foundation
import SrokaCore

// Wire DTOs (api.md §4–§7, §12). Decoding is tolerant by design: unknown keys are ignored, enum-like fields stay
// strings (use the `…Value` accessors for the typed view with the documented fallback), and optional or defaulted
// fields fall back when absent, null or of an unexpected type. Required keys (ids, cursors) still throw.

extension KeyedDecodingContainer {
    /// Value for `key`, or `fallback` when the key is absent, null or has an unexpected type.
    fileprivate func lenient<T: Decodable>(_ type: T.Type, _ key: Key, or fallback: T) -> T {
        ((try? decodeIfPresent(type, forKey: key)) ?? nil) ?? fallback
    }

    fileprivate func lenientOptional<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        ((try? decodeIfPresent(type, forKey: key)) ?? nil)
    }
}

/// api.md §4.1.
public struct ItemDto: Decodable, Sendable, Equatable {
    public var id: String
    public var url: String
    public var canonicalUrl: String?
    public var title: String?
    public var excerpt: String?
    public var siteName: String?
    public var author: String?
    public var lang: String?
    public var leadImageUrl: String?
    public var leadImageKey: String?
    public var wordCount: Int?
    public var readingMinutes: Int?
    public var contentId: String?
    public var contentPrivate: Bool
    public var parseStatus: String
    public var parseError: String?
    public var status: String
    public var isFavorite: Bool
    public var progress: Double
    public var progressAnchor: Int?
    public var savedAt: Int64
    public var archivedAt: Int64?
    public var lastReadAt: Int64?
    public var source: String?
    public var tags: [String]
    public var seq: Int64
    /// `article` (default, also when absent) or `pdf`.
    public var kind: String
    public var fileName: String?
    public var fileSize: Int64?

    public var statusValue: ItemStatus { ItemStatus(wire: status) }
    public var parseStatusValue: ParseStatus { ParseStatus(wire: parseStatus) }
    public var kindValue: ItemKind { ItemKind(wire: kind) }
    public var sourceValue: ItemSource { ItemSource(wire: source) }

    private enum CodingKeys: String, CodingKey {
        case id, url, canonicalUrl, title, excerpt, siteName, author, lang, leadImageUrl, leadImageKey, wordCount
        case readingMinutes, contentId, contentPrivate, parseStatus, parseError, status, isFavorite, progress
        case progressAnchor, savedAt, archivedAt, lastReadAt, source, tags, seq, kind, fileName, fileSize
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        url = try c.decode(String.self, forKey: .url)
        canonicalUrl = c.lenientOptional(String.self, .canonicalUrl)
        title = c.lenientOptional(String.self, .title)
        excerpt = c.lenientOptional(String.self, .excerpt)
        siteName = c.lenientOptional(String.self, .siteName)
        author = c.lenientOptional(String.self, .author)
        lang = c.lenientOptional(String.self, .lang)
        leadImageUrl = c.lenientOptional(String.self, .leadImageUrl)
        leadImageKey = c.lenientOptional(String.self, .leadImageKey)
        wordCount = c.lenientOptional(Int.self, .wordCount)
        readingMinutes = c.lenientOptional(Int.self, .readingMinutes)
        contentId = c.lenientOptional(String.self, .contentId)
        contentPrivate = c.lenient(Bool.self, .contentPrivate, or: false)
        parseStatus = c.lenient(String.self, .parseStatus, or: "pending")
        parseError = c.lenientOptional(String.self, .parseError)
        status = c.lenient(String.self, .status, or: "unread")
        isFavorite = c.lenient(Bool.self, .isFavorite, or: false)
        progress = c.lenient(Double.self, .progress, or: 0)
        progressAnchor = c.lenientOptional(Int.self, .progressAnchor)
        savedAt = c.lenient(Int64.self, .savedAt, or: 0)
        archivedAt = c.lenientOptional(Int64.self, .archivedAt)
        lastReadAt = c.lenientOptional(Int64.self, .lastReadAt)
        source = c.lenientOptional(String.self, .source)
        tags = c.lenient([String].self, .tags, or: [])
        seq = c.lenient(Int64.self, .seq, or: 0)
        kind = c.lenient(String.self, .kind, or: "article")
        fileName = c.lenientOptional(String.self, .fileName)
        fileSize = c.lenientOptional(Int64.self, .fileSize)
    }
}

/// api.md §4.2 (`count` only in `/v1/tags`).
public struct TagDto: Decodable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var count: Int?
    public var seq: Int64

    private enum CodingKeys: String, CodingKey { case id, name, count, seq }

    public init(id: String, name: String, count: Int? = nil, seq: Int64 = 0) {
        self.id = id
        self.name = name
        self.count = count
        self.seq = seq
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        count = c.lenientOptional(Int.self, .count)
        seq = c.lenient(Int64.self, .seq, or: 0)
    }
}

public struct DeletedDto: Decodable, Sendable, Equatable {
    public var items: [String]
    public var tags: [String]

    private enum CodingKeys: String, CodingKey { case items, tags }

    public init(items: [String] = [], tags: [String] = []) {
        self.items = items
        self.tags = tags
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = c.lenient([String].self, .items, or: [])
        tags = c.lenient([String].self, .tags, or: [])
    }
}

/// api.md §7.2.
public struct PullResponseDto: Decodable, Sendable, Equatable {
    public var cursor: Int64
    public var hasMore: Bool
    public var items: [ItemDto]
    public var tags: [TagDto]
    public var deleted: DeletedDto

    private enum CodingKeys: String, CodingKey { case cursor, hasMore, items, tags, deleted }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cursor = try c.decode(Int64.self, forKey: .cursor)
        hasMore = c.lenient(Bool.self, .hasMore, or: false)
        items = try c.decodeIfPresent([ItemDto].self, forKey: .items) ?? []
        tags = try c.decodeIfPresent([TagDto].self, forKey: .tags) ?? []
        deleted = c.lenient(DeletedDto.self, .deleted, or: DeletedDto())
    }
}

public struct RejectedOpDto: Decodable, Sendable, Equatable {
    public var opId: String
    /// Server reason string; unknown values are possible.
    public var reason: String

    private enum CodingKeys: String, CodingKey { case opId, reason }

    public init(opId: String, reason: String) {
        self.opId = opId
        self.reason = reason
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        opId = c.lenient(String.self, .opId, or: "")
        reason = c.lenient(String.self, .reason, or: "")
    }
}

/// api.md §7.1. `aliases` maps a client item id to the existing server item id.
public struct PushResponseDto: Decodable, Sendable, Equatable {
    public var applied: [String]
    public var rejected: [RejectedOpDto]
    public var aliases: [String: String]
    public var cursor: Int64

    private enum CodingKeys: String, CodingKey { case applied, rejected, aliases, cursor }

    public init(
        applied: [String] = [], rejected: [RejectedOpDto] = [], aliases: [String: String] = [:], cursor: Int64 = 0
    ) {
        self.applied = applied
        self.rejected = rejected
        self.aliases = aliases
        self.cursor = cursor
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        applied = c.lenient([String].self, .applied, or: [])
        rejected = c.lenient([RejectedOpDto].self, .rejected, or: [])
        aliases = c.lenient([String: String].self, .aliases, or: [:])
        cursor = c.lenient(Int64.self, .cursor, or: 0)
    }
}

/// api.md §5.7. URLs live 24 h and need no auth header.
public struct ContentUrlsDto: Decodable, Sendable, Equatable {
    public var articleUrl: String
    public var baseUrl: String
    public var packageUrl: String
    public var expiresAt: Int64
    /// Signed `…/document.pdf` URL for `kind: "pdf"` items.
    public var documentUrl: String?

    private enum CodingKeys: String, CodingKey { case articleUrl, baseUrl, packageUrl, expiresAt, documentUrl }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        articleUrl = try c.decode(String.self, forKey: .articleUrl)
        baseUrl = try c.decode(String.self, forKey: .baseUrl)
        packageUrl = try c.decode(String.self, forKey: .packageUrl)
        expiresAt = c.lenient(Int64.self, .expiresAt, or: 0)
        documentUrl = c.lenientOptional(String.self, .documentUrl)
    }
}

/// `POST /v1/items/pdf` answer (`202`): the item (new or the existing duplicate) and whether it was created.
public struct PdfUploadResponseDto: Decodable, Sendable, Equatable {
    public var item: ItemDto
    public var created: Bool

    private enum CodingKeys: String, CodingKey { case item, created }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        item = try c.decode(ItemDto.self, forKey: .item)
        created = c.lenient(Bool.self, .created, or: true)
    }
}

struct ItemEnvelope: Decodable {
    var item: ItemDto
}

public struct MeUserDto: Decodable, Sendable, Equatable {
    public var id: String
    public var email: String
    public var name: String?
    public var emailVerified: Bool
    public var createdAt: Int64?

    private enum CodingKeys: String, CodingKey { case id, email, name, emailVerified, createdAt }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        email = try c.decode(String.self, forKey: .email)
        name = c.lenientOptional(String.self, .name)
        emailVerified = c.lenient(Bool.self, .emailVerified, or: false)
        createdAt = c.lenientOptional(Int64.self, .createdAt)
    }
}

public struct MeStatsDto: Decodable, Sendable, Equatable {
    public var unread: Int
    public var archived: Int
    public var favorites: Int
    public var tags: Int

    private enum CodingKeys: String, CodingKey { case unread, archived, favorites, tags }

    public init(unread: Int = 0, archived: Int = 0, favorites: Int = 0, tags: Int = 0) {
        self.unread = unread
        self.archived = archived
        self.favorites = favorites
        self.tags = tags
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        unread = c.lenient(Int.self, .unread, or: 0)
        archived = c.lenient(Int.self, .archived, or: 0)
        favorites = c.lenient(Int.self, .favorites, or: 0)
        tags = c.lenient(Int.self, .tags, or: 0)
    }
}

/// Client types that have made an authenticated request for this user. Missing on older servers: all false.
public struct MeClientsDto: Decodable, Sendable, Equatable {
    public var chromeExtension: Bool
    public var android: Bool
    public var ios: Bool

    private enum CodingKeys: String, CodingKey {
        case chromeExtension = "extension"
        case android, ios
    }

    public init(chromeExtension: Bool = false, android: Bool = false, ios: Bool = false) {
        self.chromeExtension = chromeExtension
        self.android = android
        self.ios = ios
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        chromeExtension = c.lenient(Bool.self, .chromeExtension, or: false)
        android = c.lenient(Bool.self, .android, or: false)
        ios = c.lenient(Bool.self, .ios, or: false)
    }
}

public struct MeDto: Decodable, Sendable, Equatable {
    public var user: MeUserDto
    public var stats: MeStatsDto
    public var clients: MeClientsDto

    private enum CodingKeys: String, CodingKey { case user, stats, clients }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        user = try c.decode(MeUserDto.self, forKey: .user)
        stats = c.lenient(MeStatsDto.self, .stats, or: MeStatsDto())
        clients = c.lenient(MeClientsDto.self, .clients, or: MeClientsDto())
    }
}

public struct MinVersionsDto: Decodable, Sendable, Equatable {
    public var android: Int?
    /// Minimum iOS build (`CFBundleVersion`) the server still supports; below it the app shows "Update Sroka".
    public var ios: Int?

    private enum CodingKeys: String, CodingKey { case android, ios }

    public init(android: Int? = nil, ios: Int? = nil) {
        self.android = android
        self.ios = ios
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        android = c.lenientOptional(Int.self, .android)
        ios = c.lenientOptional(Int.self, .ios)
    }
}

public struct ConfigLimitsDto: Decodable, Sendable, Equatable {
    public var maxOpsPerPush: Int

    private enum CodingKeys: String, CodingKey { case maxOpsPerPush }

    public init(maxOpsPerPush: Int = Limits.maxOpsPerPush) { self.maxOpsPerPush = maxOpsPerPush }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        maxOpsPerPush = c.lenient(Int.self, .maxOpsPerPush, or: Limits.maxOpsPerPush)
    }
}

/// api.md §12; only what the client uses.
public struct ConfigDto: Decodable, Sendable, Equatable {
    public var appOrigin: String?
    public var minVersions: MinVersionsDto
    public var limits: ConfigLimitsDto

    private enum CodingKeys: String, CodingKey { case appOrigin, minVersions, limits }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appOrigin = c.lenientOptional(String.self, .appOrigin)
        minVersions = c.lenient(MinVersionsDto.self, .minVersions, or: MinVersionsDto())
        limits = c.lenient(ConfigLimitsDto.self, .limits, or: ConfigLimitsDto())
    }
}

/// api.md §4.3.
public struct JobDto: Decodable, Sendable, Equatable {
    public var id: String
    public var kind: String?
    public var status: String
    public var format: String?
    public var total: Int?
    public var done: Int
    public var skipped: Int
    public var error: String?
    public var createdAt: Int64
    public var updatedAt: Int64

    private enum CodingKeys: String, CodingKey {
        case id, kind, status, format, total, done, skipped, error, createdAt, updatedAt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = c.lenientOptional(String.self, .kind)
        status = c.lenient(String.self, .status, or: "running")
        format = c.lenientOptional(String.self, .format)
        total = c.lenientOptional(Int.self, .total)
        done = c.lenient(Int.self, .done, or: 0)
        skipped = c.lenient(Int.self, .skipped, or: 0)
        error = c.lenientOptional(String.self, .error)
        createdAt = c.lenient(Int64.self, .createdAt, or: 0)
        updatedAt = c.lenient(Int64.self, .updatedAt, or: 0)
    }

    /// The domain job. An unknown status counts as still running; an unknown or missing format uses `fallbackFormat`
    /// (the format the client asked for).
    public func importJob(fallbackFormat: ImportFormat) -> ImportJob {
        ImportJob(
            id: id,
            status: JobStatus(wire: status),
            format: ImportFormat(wire: format) ?? fallbackFormat,
            total: total,
            done: done,
            skipped: skipped,
            error: error,
            createdAt: Date(timeIntervalSince1970: Double(createdAt) / 1000),
            updatedAt: Date(timeIntervalSince1970: Double(updatedAt) / 1000)
        )
    }
}

struct JobEnvelope: Decodable {
    var job: JobDto
}
