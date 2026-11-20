// Enum-like wire and preference values. Each type decodes from its wire/stored string with
// `init(wire:)`, which falls back to a documented default for unknown or missing values so a newer
// server or an old preference never breaks decoding. Android: core/model/Enums.kt.

/// Wire `status` (api.md §4.1). Unknown → `.unread`.
public enum ItemStatus: String, Sendable, Hashable, CaseIterable, Codable {
    case unread
    case archived

    public init(wire: String?) { self = wire.flatMap(Self.init(rawValue:)) ?? .unread }
}

/// Wire `kind`. Unknown → `.article`.
public enum ItemKind: String, Sendable, Hashable, CaseIterable, Codable {
    case article
    case pdf

    public init(wire: String?) { self = wire.flatMap(Self.init(rawValue:)) ?? .article }
}

/// Wire `parseStatus` (api.md §4.1). Unknown → `.pending`.
public enum ParseStatus: String, Sendable, Hashable, CaseIterable, Codable {
    case pending
    case ok
    case partial
    case failed

    public init(wire: String?) { self = wire.flatMap(Self.init(rawValue:)) ?? .pending }

    /// Opens as readable text in the reader.
    public var isReadable: Bool { self == .ok || self == .partial }
}

/// Wire `source` (where an item was saved from). Unknown → `.unknown`.
public enum ItemSource: String, Sendable, Hashable, CaseIterable, Codable {
    case share
    case extensionSource = "extension"
    case web
    case `import`
    case email
    case api
    case unknown

    public init(wire: String?) { self = wire.flatMap(Self.init(rawValue:)) ?? .unknown }
}

/// Local availability of an item's article package (DECISIONS A4/A9).
public enum OfflineState: String, Sendable, Hashable, CaseIterable {
    /// The server has no content for this item yet.
    case none
    /// Content exists on the server but is not downloaded (or the local copy is stale).
    case availableRemote
    case queued
    case downloading
    case downloaded
    case failed
}

/// Top-level library lists. Tags is a separate destination (see `ItemQuery.tag`).
public enum LibraryTab: String, Sendable, Hashable, CaseIterable {
    case myList
    case archive
    case favorites
}

/// Preference `sort_order`. Unknown → `.newest`.
public enum LibrarySortOrder: String, Sendable, Hashable, CaseIterable, Codable {
    case newest
    case oldest
    case shortest
    case longest

    public init(wire: String?) { self = wire.flatMap(Self.init(rawValue:)) ?? .newest }
}

/// Preference `download_policy`: when article packages download automatically (A9). Unknown → `.wifiOnly`.
public enum DownloadPolicy: String, Sendable, Hashable, CaseIterable, Codable {
    case wifiOnly = "wifi_only"
    case anyNetwork = "any_network"
    case manual

    public init(wire: String?) { self = wire.flatMap(Self.init(rawValue:)) ?? .wifiOnly }
}

/// Preference `theme_mode`. Unknown → `.system`.
public enum ThemeMode: String, Sendable, Hashable, CaseIterable, Codable {
    case system
    case light
    case dark

    public init(wire: String?) { self = wire.flatMap(Self.init(rawValue:)) ?? .system }
}

/// Preference `reader_theme`. Unknown → `.auto`.
public enum ReaderTheme: String, Sendable, Hashable, CaseIterable, Codable {
    case auto
    case light
    case sepia
    case dark

    public init(wire: String?) { self = wire.flatMap(Self.init(rawValue:)) ?? .auto }
}

/// Preference `reader_font`; `.sans` is the original look. Unknown → `.sans`.
public enum ReaderFont: String, Sendable, Hashable, CaseIterable, Codable {
    case sans
    case serif

    public init(wire: String?) { self = wire.flatMap(Self.init(rawValue:)) ?? .sans }
}

/// Preference `reader_line_spacing`; `.normal` is the original look. Unknown → `.normal`.
public enum ReaderLineSpacing: String, Sendable, Hashable, CaseIterable, Codable {
    case tight
    case normal
    case loose

    public init(wire: String?) { self = wire.flatMap(Self.init(rawValue:)) ?? .normal }
}

/// What swiping a library row does. `.archive` toggles Archive / My List; `.tags` opens the tag editor;
/// `.none` disables the direction. Unknown → `.none`.
public enum SwipeAction: String, Sendable, Hashable, CaseIterable, Codable {
    case archive
    case favorite
    case tags
    case none

    public init(wire: String?) { self = wire.flatMap(Self.init(rawValue:)) ?? .none }
}

/// Kind of local change waiting in `pending_ops` (R6).
public enum PendingChange: String, Sendable, Hashable, CaseIterable {
    case save
    case tags
    case favorite
    case other
}
