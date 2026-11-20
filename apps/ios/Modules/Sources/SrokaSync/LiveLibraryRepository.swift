import Foundation
import GRDB
import SrokaCore
import SrokaDatabase

/// The user's library, local-first (DECISIONS A7). Android: `LibraryRepositoryImpl`.
public struct LiveLibraryRepository: LibraryRepository {
    private let database: AppDatabase
    private let writer: OpWriter
    private let syncController: any SyncController
    private let hooks: any SyncContentHooks
    private let thumbnailBase: URL?

    /// - Parameter thumbnailBase: directory that relative thumbnail paths resolve against (stream H).
    public init(
        database: AppDatabase,
        writer: OpWriter,
        syncController: any SyncController,
        hooks: any SyncContentHooks = NoContentHooks(),
        thumbnailBase: URL? = nil
    ) {
        self.database = database
        self.writer = writer
        self.syncController = syncController
        self.hooks = hooks
        self.thumbnailBase = thumbnailBase
    }

    // MARK: Reads

    public func observeItems(_ query: ItemQuery, limit: Int) -> AsyncStream<ItemPage> {
        let base = thumbnailBase
        return observe { db in
            let rows = try ItemDao.summaryRows(db, query: query, limit: limit + 1)
            return ItemPage(
                items: rows.prefix(limit).map { $0.toSummary(thumbnailBase: base) }, hasMore: rows.count > limit)
        }
    }

    public func observeSearch(_ query: String, scope: SearchScope, limit: Int) -> AsyncStream<SearchPage> {
        AsyncStream.observing { [database] in database.observeSearch(query, scope: scope, limit: limit) }
    }

    public func observeSearchCount(_ query: String, scope: SearchScope) -> AsyncStream<Int> {
        AsyncStream.observing { [database] in database.observeSearchCount(query, scope: scope) }
    }

    public func observeContinueReading(limit: Int) -> AsyncStream<[ItemSummary]> {
        let base = thumbnailBase
        return observe { db in try ItemDao.continueReading(db, limit: limit).map { $0.toSummary(thumbnailBase: base) } }
    }

    public func observeItem(id: String) -> AsyncStream<Item?> {
        let base = thumbnailBase
        return observe { db in try ItemDao.detail(db, id: id)?.toItem(thumbnailBase: base) }
    }

    public func observeNextUnread(excludeId: String?) -> AsyncStream<ItemSummary?> {
        let base = thumbnailBase
        return observe { db in try ItemDao.nextUnread(db, excludeId: excludeId)?.toSummary(thumbnailBase: base) }
    }

    public func observeNextReadable(excludeId: String?) -> AsyncStream<ItemSummary?> {
        let base = thumbnailBase
        return observe { db in try ItemDao.nextReadable(db, excludeId: excludeId)?.toSummary(thumbnailBase: base) }
    }

    public func observeCounts() -> AsyncStream<LibraryCounts> {
        AsyncStream.observing { [database] in database.observeCounts() }
    }

    private func observe<T: Sendable & Equatable>(_ value: @escaping @Sendable (Database) throws -> T) -> AsyncStream<T>
    {
        AsyncStream.observing { [database] in database.observe(value) }
    }

    // MARK: Writes

    public func save(url: String, title: String?, tags: [String], source: SaveSource) async -> SaveResult {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.utf16.count > Limits.maxUrlLength { return .invalidUrl }
        guard let canonical = UrlNormalizer.normalize(trimmed) else { return .invalidUrl }
        let title = Limits.clampTitle(title)
        let tags = normalizeTags(tags)
        let itemSource = ItemSource(wire: source.wire)
        do {
            let (_, result) = try await writer.write { db, context -> (ops: [WireOp], value: SaveResult) in
                let existing = try ItemDao.item(db, canonicalUrl: canonical)
                let id = existing?.id ?? context.newId()
                let add = WireOp.Add(
                    opId: context.newId(),
                    itemId: id,
                    at: context.at,
                    url: trimmed,
                    title: title,
                    tags: tags,
                    source: itemSource,
                    savedAt: context.at,
                    onDuplicate: .readd
                )
                return ([.add(add)], .saved(itemId: id, alreadySaved: existing != nil))
            }
            syncController.requestSync()
            return result
        } catch {
            syncLog.error("save failed: \(String(describing: type(of: error)), privacy: .public)")
            return .invalidUrl
        }
    }

    public func setStatus(id: String, status: ItemStatus) async {
        await write { _, context in
            [.setStatus(.init(opId: context.newId(), itemId: id, at: context.at, status: status))]
        }
    }

    public func setFavorite(id: String, favorite: Bool) async {
        await write { _, context in
            [.setFavorite(.init(opId: context.newId(), itemId: id, at: context.at, value: favorite))]
        }
    }

    public func setProgress(id: String, progress: Double, anchor: Int?) async {
        let clamped = progress.isNaN ? 0 : min(1, max(0, progress))
        await write { _, context in
            [.setProgress(.init(opId: context.newId(), itemId: id, at: context.at, progress: clamped, anchor: anchor))]
        }
    }

    public func setTitle(id: String, title: String?) async {
        let title = Limits.clampTitle(title)
        await write { _, context in [.setTitle(.init(opId: context.newId(), itemId: id, at: context.at, title: title))]
        }
    }

    public func setTags(id: String, names: [String]) async {
        let desired = normalizeTags(names)
        await write { db, context in
            guard try ItemDao.item(db, id: id) != nil else { return [] }
            let current = try ItemDao.tagNames(db, itemId: id)
            let currentKeys = Set(current.map(tagKey))
            let desiredKeys = Set(desired.map(tagKey))
            let removed = current.filter { !desiredKeys.contains(tagKey($0)) }.map { name in
                WireOp.tag(.init(opId: context.newId(), itemId: id, at: context.at, tag: name, present: false))
            }
            let added = desired.filter { !currentKeys.contains(tagKey($0)) }.map { name in
                WireOp.tag(.init(opId: context.newId(), itemId: id, at: context.at, tag: name, present: true))
            }
            return removed + added
        }
    }

    public func delete(id: String) async {
        do {
            let deleted = try await writer.write { _, context in
                [WireOp.delete(.init(opId: context.newId(), itemId: id, at: context.at))]
            }
            if deleted {
                if isValidItemId(id) { await hooks.deleteItemFiles(itemIds: [id]) }
                syncController.requestSync()
            }
        } catch {
            syncLog.error("delete failed: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    public func refresh(id: String) async {
        await write { _, context in [.refresh(.init(opId: context.newId(), itemId: id, at: context.at))] }
    }

    private func write(_ build: @escaping @Sendable (Database, OpContext) throws -> [WireOp]) async {
        do {
            if try await writer.write(build) { syncController.requestSync() }
        } catch {
            syncLog.error("library write failed: \(String(describing: type(of: error)), privacy: .public)")
        }
    }
}

/// Normalised, valid (1–64 UTF-16 units), de-duplicated by tag key, at most `Limits.maxTagsPerItem`.
/// Android `normalizeTags`.
func normalizeTags(_ names: [String]) -> [String] {
    var keys = Set<String>()
    var out: [String] = []
    for name in names.map(normalizeTagName) {
        guard !name.isEmpty, name.utf16.count <= Limits.maxTagLength, keys.insert(tagKey(name)).inserted else {
            continue
        }
        out.append(name)
        if out.count == Limits.maxTagsPerItem { break }
    }
    return out
}
