import Foundation

/// A sync op exactly as sent in `POST /v1/sync/push` (api.md §7.1, `packages/shared/src/ops.ts`). The ten op types
/// are the cases of this enum. `payload` is the canonical JSON that is stored in `pending_ops.payload` and sent
/// verbatim: one fixed encoder configuration (sorted keys, no escaped slashes, nil fields omitted), so the same op
/// always encodes to the same bytes. Never edit a payload string; to change an op's `itemId` or `opId` (aliases,
/// re-keying) use `WireOp.rewrite(payload:itemId:opId:)`, which decodes, modifies and re-encodes.
public enum WireOp: Sendable, Hashable {
    case add(Add)
    case setStatus(SetStatus)
    case setFavorite(SetFavorite)
    case setProgress(SetProgress)
    case tag(Tag)
    case setTitle(SetTitle)
    case delete(Delete)
    case refresh(Refresh)
    case tagRename(TagRename)
    case tagDelete(TagDelete)

    /// Wire `type` values.
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case add = "item.add"
        case setStatus = "item.setStatus"
        case setFavorite = "item.setFavorite"
        case setProgress = "item.setProgress"
        case tag = "item.tag"
        case setTitle = "item.setTitle"
        case delete = "item.delete"
        case refresh = "item.refresh"
        case tagRename = "tag.rename"
        case tagDelete = "tag.delete"
    }

    /// What `item.add` does when the canonical URL already exists as a live item.
    public enum OnDuplicate: String, Sendable, Hashable {
        /// Pocket semantics (default): back to unread, fresh `savedAt`, union tags.
        case readd
        /// Imports: only union tags; status and `savedAt` untouched.
        case merge
    }

    /// `item.add`. `tags` are sent as given (already normalised by the caller); `title` is clamped to
    /// `Limits.maxTitleLength` on encode. `savedAt`, `status` and `isFavorite` apply only when a new item is created.
    public struct Add: Sendable, Hashable {
        public var opId: String
        public var itemId: String
        public var at: Int64
        public var url: String
        public var title: String?
        public var tags: [String]
        public var source: ItemSource?
        public var savedAt: Int64?
        public var status: ItemStatus?
        public var isFavorite: Bool?
        public var onDuplicate: OnDuplicate?

        public init(
            opId: String,
            itemId: String,
            at: Int64,
            url: String,
            title: String? = nil,
            tags: [String] = [],
            source: ItemSource? = nil,
            savedAt: Int64? = nil,
            status: ItemStatus? = nil,
            isFavorite: Bool? = nil,
            onDuplicate: OnDuplicate? = nil
        ) {
            self.opId = opId
            self.itemId = itemId
            self.at = at
            self.url = url
            self.title = title
            self.tags = tags
            self.source = source
            self.savedAt = savedAt
            self.status = status
            self.isFavorite = isFavorite
            self.onDuplicate = onDuplicate
        }
    }

    public struct SetStatus: Sendable, Hashable {
        public var opId: String
        public var itemId: String
        public var at: Int64
        public var status: ItemStatus

        public init(opId: String, itemId: String, at: Int64, status: ItemStatus) {
            self.opId = opId
            self.itemId = itemId
            self.at = at
            self.status = status
        }
    }

    public struct SetFavorite: Sendable, Hashable {
        public var opId: String
        public var itemId: String
        public var at: Int64
        public var value: Bool

        public init(opId: String, itemId: String, at: Int64, value: Bool) {
            self.opId = opId
            self.itemId = itemId
            self.at = at
            self.value = value
        }
    }

    /// `item.setProgress`; `progress` is clamped to 0...1 (NaN becomes 0) because the server rejects other values.
    public struct SetProgress: Sendable, Hashable {
        public var opId: String
        public var itemId: String
        public var at: Int64
        public var progress: Double
        public var anchor: Int?

        public init(opId: String, itemId: String, at: Int64, progress: Double, anchor: Int? = nil) {
            self.opId = opId
            self.itemId = itemId
            self.at = at
            self.progress = Self.clamp(progress)
            self.anchor = anchor.map { max(0, $0) }
        }

        /// 0...1; NaN becomes 0. Also applied when encoding, since the fields are mutable.
        static func clamp(_ progress: Double) -> Double { progress.isNaN ? 0 : min(1, max(0, progress)) }
    }

    public struct Tag: Sendable, Hashable {
        public var opId: String
        public var itemId: String
        public var at: Int64
        public var tag: String
        public var present: Bool

        public init(opId: String, itemId: String, at: Int64, tag: String, present: Bool) {
            self.opId = opId
            self.itemId = itemId
            self.at = at
            self.tag = tag
            self.present = present
        }
    }

    /// `item.setTitle`; a nil title clears the user title and is sent as `""` (api.md §8.3).
    public struct SetTitle: Sendable, Hashable {
        public var opId: String
        public var itemId: String
        public var at: Int64
        public var title: String?

        public init(opId: String, itemId: String, at: Int64, title: String?) {
            self.opId = opId
            self.itemId = itemId
            self.at = at
            self.title = title
        }
    }

    public struct Delete: Sendable, Hashable {
        public var opId: String
        public var itemId: String
        public var at: Int64

        public init(opId: String, itemId: String, at: Int64) {
            self.opId = opId
            self.itemId = itemId
            self.at = at
        }
    }

    public struct Refresh: Sendable, Hashable {
        public var opId: String
        public var itemId: String
        public var at: Int64

        public init(opId: String, itemId: String, at: Int64) {
            self.opId = opId
            self.itemId = itemId
            self.at = at
        }
    }

    public struct TagRename: Sendable, Hashable {
        public var opId: String
        public var at: Int64
        public var from: String
        public var to: String

        public init(opId: String, at: Int64, from: String, to: String) {
            self.opId = opId
            self.at = at
            self.from = from
            self.to = to
        }
    }

    public struct TagDelete: Sendable, Hashable {
        public var opId: String
        public var at: Int64
        public var tag: String

        public init(opId: String, at: Int64, tag: String) {
            self.opId = opId
            self.at = at
            self.tag = tag
        }
    }

    // MARK: Common head

    public var kind: Kind {
        switch self {
        case .add: .add
        case .setStatus: .setStatus
        case .setFavorite: .setFavorite
        case .setProgress: .setProgress
        case .tag: .tag
        case .setTitle: .setTitle
        case .delete: .delete
        case .refresh: .refresh
        case .tagRename: .tagRename
        case .tagDelete: .tagDelete
        }
    }

    public var opId: String {
        switch self {
        case .add(let op): op.opId
        case .setStatus(let op): op.opId
        case .setFavorite(let op): op.opId
        case .setProgress(let op): op.opId
        case .tag(let op): op.opId
        case .setTitle(let op): op.opId
        case .delete(let op): op.opId
        case .refresh(let op): op.opId
        case .tagRename(let op): op.opId
        case .tagDelete(let op): op.opId
        }
    }

    public var at: Int64 {
        switch self {
        case .add(let op): op.at
        case .setStatus(let op): op.at
        case .setFavorite(let op): op.at
        case .setProgress(let op): op.at
        case .tag(let op): op.at
        case .setTitle(let op): op.at
        case .delete(let op): op.at
        case .refresh(let op): op.at
        case .tagRename(let op): op.at
        case .tagDelete(let op): op.at
        }
    }

    /// Target item, or nil for tag-level ops (`tag.rename`, `tag.delete`).
    public var itemId: String? {
        switch self {
        case .add(let op): op.itemId
        case .setStatus(let op): op.itemId
        case .setFavorite(let op): op.itemId
        case .setProgress(let op): op.itemId
        case .tag(let op): op.itemId
        case .setTitle(let op): op.itemId
        case .delete(let op): op.itemId
        case .refresh(let op): op.itemId
        case .tagRename, .tagDelete: nil
        }
    }

    /// The same op targeting `itemId` and/or carrying `opId`; tag-level ops ignore `itemId`.
    public func rewriting(itemId: String? = nil, opId: String? = nil) -> WireOp {
        var copy = self
        switch copy {
        case .add(var op):
            if let itemId { op.itemId = itemId }
            if let opId { op.opId = opId }
            copy = .add(op)
        case .setStatus(var op):
            if let itemId { op.itemId = itemId }
            if let opId { op.opId = opId }
            copy = .setStatus(op)
        case .setFavorite(var op):
            if let itemId { op.itemId = itemId }
            if let opId { op.opId = opId }
            copy = .setFavorite(op)
        case .setProgress(var op):
            if let itemId { op.itemId = itemId }
            if let opId { op.opId = opId }
            copy = .setProgress(op)
        case .tag(var op):
            if let itemId { op.itemId = itemId }
            if let opId { op.opId = opId }
            copy = .tag(op)
        case .setTitle(var op):
            if let itemId { op.itemId = itemId }
            if let opId { op.opId = opId }
            copy = .setTitle(op)
        case .delete(var op):
            if let itemId { op.itemId = itemId }
            if let opId { op.opId = opId }
            copy = .delete(op)
        case .refresh(var op):
            if let itemId { op.itemId = itemId }
            if let opId { op.opId = opId }
            copy = .refresh(op)
        case .tagRename(var op):
            if let opId { op.opId = opId }
            copy = .tagRename(op)
        case .tagDelete(var op):
            if let opId { op.opId = opId }
            copy = .tagDelete(op)
        }
        return copy
    }

    // MARK: Canonical JSON

    /// Canonical compact JSON of this op, as stored in `pending_ops.payload` and sent to the server.
    public var payload: String {
        // Encoding a flat struct of strings, numbers and booleans cannot fail.
        String(decoding: (try? Self.encoder.encode(Wire(self))) ?? Data(), as: UTF8.self)
    }

    /// Parses a stored payload; nil for unknown or corrupt ops (unknown keys are ignored).
    public static func parse(payload: String) -> WireOp? {
        guard let wire = try? decoder.decode(Wire.self, from: Data(payload.utf8)) else { return nil }
        return wire.op
    }

    /// Decode-modify-encode: the payload of the same op with a new `itemId` and/or `opId`. Nil when `payload` is not
    /// a valid op. Never rewrite ids with string replacement inside a payload.
    public static func rewrite(payload: String, itemId: String? = nil, opId: String? = nil) -> String? {
        parse(payload: payload)?.rewriting(itemId: itemId, opId: opId).payload
    }

    /// Title as zod sees it: JavaScript `trim()`, at most `Limits.maxTitleLength` UTF-16 units (never splitting a
    /// surrogate pair), nil when empty. Not `Limits.clampTitle`, whose Unicode whitespace set differs from JS.
    static func clampTitle(_ title: String?) -> String? {
        guard let title else { return nil }
        var units = Array(jsTrim(title).utf16)
        if units.count > Limits.maxTitleLength {
            var end = Limits.maxTitleLength
            if UTF16.isLeadSurrogate(units[end - 1]) { end -= 1 }
            units = Array(units[0..<end])
        }
        let result = jsTrim(String(decoding: units, as: UTF16.self))
        return result.isEmpty ? nil : result
    }

    /// The fixed encoder configuration: sorted keys, compact, slashes unescaped. Nil fields are omitted by `Wire`.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static let decoder = JSONDecoder()

    /// Flat wire shape of every op type; absent fields stay nil and are not encoded.
    private struct Wire: Codable {
        var opId: String
        var type: String
        var at: Int64
        var itemId: String?
        var url: String?
        var title: String?
        var tags: [String]?
        var source: String?
        var savedAt: Int64?
        var status: String?
        var isFavorite: Bool?
        var onDuplicate: String?
        var value: Bool?
        var progress: Double?
        var anchor: Int?
        var tag: String?
        var present: Bool?
        var from: String?
        var to: String?

        init(opId: String, type: Kind, at: Int64, itemId: String? = nil) {
            self.opId = opId
            self.type = type.rawValue
            self.at = at
            self.itemId = itemId
        }

        init(_ op: WireOp) {
            switch op {
            case .add(let op):
                self.init(opId: op.opId, type: .add, at: op.at, itemId: op.itemId)
                url = op.url
                title = WireOp.clampTitle(op.title)
                tags = op.tags
                source = op.source.flatMap { $0 == .unknown ? nil : $0.rawValue }
                savedAt = op.savedAt
                status = op.status?.rawValue
                isFavorite = op.isFavorite
                onDuplicate = op.onDuplicate?.rawValue
            case .setStatus(let op):
                self.init(opId: op.opId, type: .setStatus, at: op.at, itemId: op.itemId)
                status = op.status.rawValue
            case .setFavorite(let op):
                self.init(opId: op.opId, type: .setFavorite, at: op.at, itemId: op.itemId)
                value = op.value
            case .setProgress(let op):
                self.init(opId: op.opId, type: .setProgress, at: op.at, itemId: op.itemId)
                progress = SetProgress.clamp(op.progress)
                anchor = op.anchor.map { max(0, $0) }
            case .tag(let op):
                self.init(opId: op.opId, type: .tag, at: op.at, itemId: op.itemId)
                tag = op.tag
                present = op.present
            case .setTitle(let op):
                self.init(opId: op.opId, type: .setTitle, at: op.at, itemId: op.itemId)
                title = WireOp.clampTitle(op.title) ?? ""
            case .delete(let op):
                self.init(opId: op.opId, type: .delete, at: op.at, itemId: op.itemId)
            case .refresh(let op):
                self.init(opId: op.opId, type: .refresh, at: op.at, itemId: op.itemId)
            case .tagRename(let op):
                self.init(opId: op.opId, type: .tagRename, at: op.at)
                from = op.from
                to = op.to
            case .tagDelete(let op):
                self.init(opId: op.opId, type: .tagDelete, at: op.at)
                tag = op.tag
            }
        }

        /// The typed op, or nil if the type is unknown or a required field is missing.
        var op: WireOp? {
            guard let kind = Kind(rawValue: type) else { return nil }
            switch kind {
            case .add:
                guard let itemId, let url else { return nil }
                return .add(
                    Add(
                        opId: opId, itemId: itemId, at: at, url: url, title: title, tags: tags ?? [],
                        source: source.flatMap(ItemSource.init(rawValue:)), savedAt: savedAt,
                        status: status.flatMap(ItemStatus.init(rawValue:)), isFavorite: isFavorite,
                        onDuplicate: onDuplicate.flatMap(OnDuplicate.init(rawValue:))
                    )
                )
            case .setStatus:
                guard let itemId, let status = status.flatMap(ItemStatus.init(rawValue:)) else { return nil }
                return .setStatus(SetStatus(opId: opId, itemId: itemId, at: at, status: status))
            case .setFavorite:
                guard let itemId, let value else { return nil }
                return .setFavorite(SetFavorite(opId: opId, itemId: itemId, at: at, value: value))
            case .setProgress:
                guard let itemId, let progress else { return nil }
                return .setProgress(SetProgress(opId: opId, itemId: itemId, at: at, progress: progress, anchor: anchor))
            case .tag:
                guard let itemId, let tag, let present else { return nil }
                return .tag(Tag(opId: opId, itemId: itemId, at: at, tag: tag, present: present))
            case .setTitle:
                guard let itemId else { return nil }
                return .setTitle(
                    SetTitle(opId: opId, itemId: itemId, at: at, title: title.flatMap { $0.isEmpty ? nil : $0 }))
            case .delete:
                guard let itemId else { return nil }
                return .delete(Delete(opId: opId, itemId: itemId, at: at))
            case .refresh:
                guard let itemId else { return nil }
                return .refresh(Refresh(opId: opId, itemId: itemId, at: at))
            case .tagRename:
                guard let from, let to else { return nil }
                return .tagRename(TagRename(opId: opId, at: at, from: from, to: to))
            case .tagDelete:
                guard let tag else { return nil }
                return .tagDelete(TagDelete(opId: opId, at: at, tag: tag))
            }
        }
    }
}
