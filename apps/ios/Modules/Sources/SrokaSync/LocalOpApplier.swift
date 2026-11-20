import GRDB
import SrokaCore
import SrokaDatabase

/// Applies the local effect of a `WireOp` to the database (DECISIONS A7). Used both for user writes
/// and to rebase un-pushed ops on top of freshly pulled rows (A8.2), so the two always agree.
/// Callers run it inside a write transaction. Android: `ops/LocalOpApplier.kt`.
public enum LocalOpApplier {
    /// Returns false when the target item does not exist locally (nothing changed), or when an
    /// `item.add` for a new item carries a URL that does not normalise.
    @discardableResult
    public static func apply(_ db: Database, _ op: WireOp) throws -> Bool {
        switch op {
        case .add(let op):
            return try applyAdd(db, op)
        case .setStatus(let op):
            return try ifExists(db, op.itemId) {
                try ItemDao.setStatus(
                    db, id: op.itemId, status: op.status, archivedAt: op.status == .archived ? op.at : nil)
            }
        case .setFavorite(let op):
            return try ifExists(db, op.itemId) { try ItemDao.setFavorite(db, id: op.itemId, favorite: op.value) }
        case .setProgress(let op):
            return try ifExists(db, op.itemId) {
                let progress = op.progress.isNaN ? 0 : min(1, max(0, op.progress))
                try ItemDao.setProgress(db, id: op.itemId, progress: progress, anchor: op.anchor, readAt: op.at)
            }
        case .setTitle(let op):
            return try ifExists(db, op.itemId) {
                try ItemDao.setTitle(db, id: op.itemId, title: Limits.clampTitle(op.title))
            }
        case .tag(let op):
            return try ifExists(db, op.itemId) {
                let current = try ItemDao.tagNames(db, itemId: op.itemId)
                let key = tagKey(op.tag)
                let next: [String]
                if op.present {
                    let present = current.contains { tagKey($0) == key }
                    next = present || current.count >= Limits.maxTagsPerItem ? current : current + [op.tag]
                } else {
                    next = current.filter { tagKey($0) != key }
                }
                if next != current { try ItemDao.replaceTags(db, itemId: op.itemId, names: next) }
            }
        case .delete(let op):
            return try ifExists(db, op.itemId) { try ItemDao.delete(db, id: op.itemId) }
        case .refresh(let op):
            return try ifExists(db, op.itemId) { try ItemDao.setParseStatus(db, id: op.itemId, parseStatus: .pending) }
        case .tagRename(let op):
            try ItemDao.renameTag(db, fromKey: tagKey(op.from), toName: op.to)
            return true
        case .tagDelete(let op):
            try ItemDao.deleteTag(db, nameKey: tagKey(op.tag))
            return true
        }
    }

    /// New item, or a re-add of an existing one (api.md §8.2 "readd"): back to unread, archive date
    /// cleared, the later `savedAt`, the existing title kept, tags united.
    private static func applyAdd(_ db: Database, _ op: WireOp.Add) throws -> Bool {
        let savedAt = op.savedAt ?? op.at
        if var existing = try ItemDao.item(db, id: op.itemId) {
            let tags = unionTags(try ItemDao.tagNames(db, itemId: op.itemId), op.tags)
            existing.status = .unread
            existing.archivedAt = nil
            existing.savedAt = max(existing.savedAt, savedAt)
            existing.title = existing.title ?? Limits.clampTitle(op.title)
            try ItemDao.upsert(db, existing, tags: tags)
        } else {
            guard let canonical = UrlNormalizer.normalize(op.url) else { return false }
            let item = ItemRecord(
                id: op.itemId,
                url: op.url,
                canonicalUrl: canonical,
                title: Limits.clampTitle(op.title),
                parseStatus: .pending,
                status: .unread,
                savedAt: savedAt,
                source: op.source.flatMap { $0 == .unknown ? nil : $0.rawValue }
            )
            try ItemDao.upsert(db, item, tags: unionTags([], op.tags))
        }
        return true
    }

    private static func ifExists(_ db: Database, _ itemId: String, _ body: () throws -> Void) throws -> Bool {
        guard try ItemDao.item(db, id: itemId) != nil else { return false }
        try body()
        return true
    }
}

/// `current` plus the `added` tags not already present (by tag key), capped at `Limits.maxTagsPerItem`;
/// blank names are skipped.
func unionTags(_ current: [String], _ added: [String]) -> [String] {
    var keys = Set(current.map(tagKey))
    var out = current
    for name in added {
        if out.count >= Limits.maxTagsPerItem { break }
        if !name.allSatisfy(\.isWhitespace), keys.insert(tagKey(name)).inserted { out.append(name) }
    }
    return out
}
