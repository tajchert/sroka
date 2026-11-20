import Foundation
import GRDB
import SrokaCore
import Testing

@testable import SrokaDatabase

struct PendingOpTests {
    let database: AppDatabase

    init() throws {
        database = try makeDatabase()
    }

    @Test func `Enqueue coalesces older ops of the same item and type for the four coalescing types`() throws {
        try database.run { db in
            for type in ["item.setProgress", "item.setStatus", "item.setFavorite", "item.setTitle", "item.tag"] {
                try PendingOpDao.enqueue(db, op("\(type)-1", item: "a", type: type))
                try PendingOpDao.enqueue(db, op("\(type)-2", item: "a", type: type))
            }
            try PendingOpDao.enqueue(db, op("other-item", item: "b", type: "item.setStatus"))
            try PendingOpDao.enqueue(db, op("rename-1", item: nil, type: "tag.rename"))
            try PendingOpDao.enqueue(db, op("rename-2", item: nil, type: "tag.rename"))
        }
        let ids = try database.writer.read { db in try PendingOpDao.all(db).map(\.opId) }
        #expect(
            ids == [
                "item.setProgress-2", "item.setStatus-2", "item.setFavorite-2", "item.setTitle-2", "item.tag-1",
                "item.tag-2", "other-item", "rename-1", "rename-2",
            ])
    }

    @Test func `Enqueue returns increasing sequence numbers and ignores a duplicate op id`() throws {
        try database.run { db in
            let first = try PendingOpDao.enqueue(db, op("x", item: "a", type: "item.add"))
            let second = try PendingOpDao.enqueue(db, op("y", item: "a", type: "item.tag"))
            let duplicate = try PendingOpDao.enqueue(db, op("x", item: "a", type: "item.add", payload: "{\"v\":2}"))
            #expect(first != nil)
            #expect(second! > first!)
            #expect(duplicate == nil)
            #expect(try PendingOpDao.count(db) == 2)
            #expect(try PendingOpDao.forItem(db, "a").first?.payload == "{}")
        }
    }

    @Test func `Re-enqueueing a queued coalescing op keeps its sequence and attempts`() throws {
        try database.run { db in
            let seq = try PendingOpDao.enqueue(db, op("s1", item: "a", type: "item.setStatus"))
            try PendingOpDao.markAttempted(db, opIds: ["s1"], error: "http_500")
            #expect(try PendingOpDao.enqueue(db, op("s1", item: "a", type: "item.setStatus")) == nil)
            let kept = try #require(try PendingOpDao.forItem(db, "a").first)
            #expect(kept.localSeq == seq)
            #expect(kept.attempts == 1)
        }
    }

    @Test func `Reads, attempts, deletes and retargeting`() throws {
        try database.run { db in
            try PendingOpDao.enqueue(db, op("1", item: "a", type: "item.add", payload: "{\"itemId\":\"a\"}"))
            try PendingOpDao.enqueue(db, op("2", item: nil, type: "tag.delete"))
            try PendingOpDao.enqueue(db, op("3", item: "b", type: "item.add"))
            try PendingOpDao.enqueue(db, op("4", item: "a", type: "item.tag", payload: "{\"itemId\":\"a\"}"))

            #expect(try PendingOpDao.batch(db, limit: 2).map(\.opId) == ["1", "2"])
            #expect(try PendingOpDao.forItems(db, ["a", "b"]).map(\.opId) == ["1", "3", "4"])
            #expect(try PendingOpDao.forItemsOrGlobal(db, ["a"]).map(\.opId) == ["1", "2", "4"])
            #expect(try PendingOpDao.globalOps(db).map(\.opId) == ["2"])

            try PendingOpDao.markAttempted(db, opIds: ["1", "3"], error: "http_500")
            let one = try #require(try PendingOpDao.forItem(db, "a").first)
            #expect(one.attempts == 1)
            #expect(one.lastError == "http_500")

            try PendingOpDao.retargetItem(db, from: "a", to: "z") { op in
                op.payload.isEmpty ? "" : "{\"itemId\":\"z\"}"
            }
            #expect(try PendingOpDao.forItem(db, "a").isEmpty)
            #expect(try PendingOpDao.forItem(db, "z").map(\.payload) == ["{\"itemId\":\"z\"}", "{\"itemId\":\"z\"}"])

            try PendingOpDao.replaceOpId(db, from: "3", to: "3b", payload: "{\"opId\":\"3b\"}")
            #expect(try PendingOpDao.forItem(db, "b").map(\.opId) == ["3b"])

            try PendingOpDao.delete(db, opIds: ["1", "2"])
            #expect(try PendingOpDao.all(db).map(\.opId) == ["3b", "4"])
            try PendingOpDao.deleteAll(db)
            #expect(try PendingOpDao.count(db) == 0)
        }
    }

    @Test func `Sync state defaults and updates`() throws {
        try database.run { db in
            #expect(try SyncStateDao.get(db) == SyncStateRecord())
            try SyncStateDao.update(db) { $0.cursor = 7 }
            try SyncStateDao.update(db) {
                $0.fullResync = true
                $0.lastError = "http_503"
            }
            #expect(try SyncStateDao.get(db) == SyncStateRecord(cursor: 7, lastError: "http_503", fullResync: true))
            #expect(try SyncStateRecord.fetchCount(db) == 1)
        }
    }
}

struct ItemWriteTests {
    let database: AppDatabase

    init() throws {
        database = try makeDatabase()
    }

    @Test func `Upsert keeps the FTS rowid, tags and content file`() throws {
        try database.run { db in
            try ItemDao.upsert(db, item("a"), tags: ["x"])
            try ItemDao.upsert(db, item("b"))
            let rowA = try #require(try ItemDao.ftsRowId(db, itemId: "a"))
            #expect(rowA != (try ItemDao.ftsRowId(db, itemId: "b")))
            try ContentFileDao.upsert(
                db, ContentFileRecord(itemId: "a", contentId: "c-a", state: .downloaded, bytes: 10))
            try ItemDao.upsert(db, item("a", title: "changed"))
            #expect(try ItemDao.ftsRowId(db, itemId: "a") == rowA)
            #expect(try ItemDao.tagNames(db, itemId: "a") == ["x"])
            #expect(try ContentFileDao.get(db, itemId: "a")?.bytes == 10)
        }
    }

    @Test func `Re-key moves the row, its tags and its FTS row and drops the content file`() throws {
        try database.run { db in
            try ItemDao.upsert(db, item("old", title: "Rekeyed article", contentId: "c"), tags: ["Keep", "Me"])
            try ContentFileDao.upsert(db, ContentFileRecord(itemId: "old", contentId: "c", state: .queued))
            let rowId = try ItemDao.ftsRowId(db, itemId: "old")
            #expect(try ItemDao.rekey(db, from: "old", to: "new"))
            #expect(try ItemDao.item(db, id: "old") == nil)
            #expect(try ItemDao.ftsRowId(db, itemId: "new") == rowId)
            #expect(try ItemDao.tagNames(db, itemId: "new") == ["Keep", "Me"])
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM item_tags WHERE item_id = 'old'") == 0)
            #expect(try ContentFileDao.get(db, itemId: "new") == nil)
            #expect(try ContentFileDao.get(db, itemId: "old") == nil)

            try ItemDao.upsert(db, item("other"))
            #expect(try !ItemDao.rekey(db, from: "new", to: "other"))
            #expect(try !ItemDao.rekey(db, from: "missing", to: "x"))
        }
        #expect(try database.searchIds("rekeyed") == ["new"])
        #expect(try database.searchIds("keep") == ["new"])
    }

    @Test func `Deleting an item cascades to tags and content file`() throws {
        try database.run { db in
            try ItemDao.upsert(db, item("a", contentId: "c"), tags: ["t"])
            try ContentFileDao.upsert(db, ContentFileRecord(itemId: "a", contentId: "c", state: .downloaded))
            try ItemDao.delete(db, id: "a")
            #expect(try ItemTagRecord.fetchCount(db) == 0)
            #expect(try ContentFileRecord.fetchCount(db) == 0)
        }
    }

    @Test func `Tag names are normalized and deduplicated by key`() throws {
        try database.run { db in
            try ItemDao.upsert(db, item("a"))
            try ItemDao.replaceTags(db, itemId: "a", names: ["  Swift  UI ", "swift ui", "", "  ", "Go"])
            #expect(try ItemDao.tagNames(db, itemId: "a") == ["Go", "Swift UI"])
            try ItemDao.replaceTags(db, itemId: "missing", names: ["x"])
            #expect(try ItemTagRecord.fetchCount(db) == 2)
        }
    }

    @Test func `Tag counts, rename merge, delete and recent tags`() throws {
        try database.run { db in
            try ItemDao.upsert(db, item("a", savedAt: 1), tags: ["Swift", "Go"])
            try ItemDao.upsert(db, item("b", savedAt: 2), tags: ["swift"])
            try ItemDao.upsert(db, item("c", savedAt: 3), tags: ["Rust"])
            try TagDao.upsertRows(db, [TagRecord(id: "t1", name: "Empty"), TagRecord(id: "t2", name: "Swift")])
            #expect(
                try TagDao.counts(db) == [
                    TagCount(name: "Empty", count: 0), TagCount(name: "Go", count: 1),
                    TagCount(name: "Rust", count: 1), TagCount(name: "Swift", count: 2),
                ])
            #expect(try TagDao.recent(db, limit: 2) == ["Rust", "Swift"])

            try ItemDao.renameTag(db, fromKey: "go", toName: "Rust")
            #expect(try ItemDao.tagNames(db, itemId: "a") == ["Rust", "Swift"])
            try ItemDao.deleteTag(db, nameKey: "swift")
            #expect(try ItemDao.tagNames(db, itemId: "b").isEmpty)
            #expect(try TagDao.allRows(db).map(\.id) == ["t1"])
            #expect(try TagDao.counts(db) == [TagCount(name: "Empty", count: 0), TagCount(name: "Rust", count: 2)])
        }
        #expect(try database.searchIds("swift").isEmpty)
        #expect(try database.searchIds("rust").sorted() == ["a", "c"])
    }

    @Test func `Resync deletes still-marked items without pending ops`() throws {
        try database.run { db in
            try ItemDao.upsert(db, item("seen"))
            try ItemDao.upsert(db, item("gone"))
            try ItemDao.upsert(db, item("local"))
            try PendingOpDao.enqueue(db, op("o", item: "local", type: "item.add"))
            try ItemDao.markAllForResync(db)
            try ItemDao.upsert(db, item("seen", title: "pulled again"))
            #expect(try ItemDao.deleteStaleMarked(db) == ["gone"])
            try ItemDao.clearResyncMarks(db)
            #expect(try ItemRecord.fetchAll(db).map(\.id).sorted() == ["local", "seen"])
        }
    }
}

struct ContentFileTests {
    let database: AppDatabase

    init() throws {
        database = try makeDatabase()
        try database.run { db in
            try ItemDao.upsert(db, item("none", savedAt: 9))
            try ItemDao.upsert(db, item("missing", savedAt: 8, contentId: "c"))
            try ItemDao.upsert(db, item("stale", savedAt: 7, contentId: "c2"))
            try ItemDao.upsert(db, item("queued", savedAt: 6, contentId: "c"))
            try ItemDao.upsert(db, item("failed4", savedAt: 5, contentId: "c"))
            try ItemDao.upsert(db, item("failed5", savedAt: 4, contentId: "c"))
            try ItemDao.upsert(db, item("downloading", savedAt: 3, contentId: "c"))
            try ItemDao.upsert(db, item("done", savedAt: 2, contentId: "c", leadImageKey: "img"))
            try ItemDao.upsert(db, item("archived", status: .archived, savedAt: 1, archivedAt: 1, contentId: "c"))
            try ItemDao.upsert(
                db, item("archfav", status: .archived, favorite: true, savedAt: 0, archivedAt: 1, contentId: "c"))
            try ContentFileDao.upsert(db, ContentFileRecord(itemId: "stale", contentId: "c1", state: .downloaded))
            try ContentFileDao.upsert(db, ContentFileRecord(itemId: "queued", contentId: "c", state: .queued))
            try ContentFileDao.upsert(
                db, ContentFileRecord(itemId: "failed4", contentId: "c", state: .failed, attempts: 4))
            try ContentFileDao.upsert(
                db, ContentFileRecord(itemId: "failed5", contentId: "c", state: .failed, attempts: 5))
            try ContentFileDao.upsert(db, ContentFileRecord(itemId: "downloading", contentId: "c", state: .downloading))
            try ContentFileDao.upsert(
                db, ContentFileRecord(itemId: "done", contentId: "c", state: .downloaded, bytes: 100))
        }
    }

    @Test func `Eligible downloads are newest first and skip done, downloading and exhausted rows`() throws {
        try database.writer.read { (db: Database) throws in
            #expect(
                try ContentFileDao.eligibleForDownload(db).map(\.itemId) == [
                    "missing", "stale", "queued", "failed4", "archfav",
                ])
            #expect(
                try ContentFileDao.eligibleForDownload(db, limit: 3).map(\.itemId) == ["missing", "stale", "queued"])
            #expect(try ContentFileDao.eligibleForDownload(db).first { $0.itemId == "stale" }?.contentId == "c2")
            #expect(try ContentFileDao.eligibleCount(db) == 5)
            #expect(try ContentFileDao.downloadedCount(db) == 1)
            #expect(try ContentFileDao.totalBytes(db) == 100)
            #expect(try ContentFileDao.thumbsToRetry(db).map(\.itemId) == ["done"])
        }
    }

    @Test func `Recovery queues downloading rows again`() throws {
        try database.run { db in
            try ContentFileDao.resetDownloading(db)
            #expect(try ContentFileDao.get(db, itemId: "downloading")?.state == .queued)
            #expect(try ContentFileDao.downloadedItemIds(db).sorted() == ["done", "stale"])
        }
    }

    @Test func `Commit marks downloaded only while the row is still downloading`() throws {
        try database.run { db in
            #expect(
                try ContentFileDao.commitDownloaded(
                    db, itemId: "downloading", contentId: "c", bytes: 5, downloadedAt: 9))
            #expect(try ContentFileDao.get(db, itemId: "downloading")?.state == .downloaded)
            #expect(
                try !ContentFileDao.commitDownloaded(db, itemId: "queued", contentId: "c", bytes: 5, downloadedAt: 9))
            try ContentFileDao.upsert(db, ContentFileRecord(itemId: "missing", contentId: "c", state: .downloading))
            try ContentFileDao.deleteAll(db)
            #expect(
                try !ContentFileDao.commitDownloaded(db, itemId: "missing", contentId: "c", bytes: 5, downloadedAt: 9))
        }
    }

    @Test func `Eviction picks old archived non-favorite downloads not read or downloaded recently`() throws {
        try database.run { db in
            let day: Int64 = 86_400_000
            let now = 100 * day
            let cutoff = now - 30 * day
            try ItemDao.upsert(db, item("ev", status: .archived, savedAt: 1, archivedAt: cutoff - day, contentId: "c"))
            try ItemDao.upsert(
                db, item("recentArchive", status: .archived, savedAt: 1, archivedAt: cutoff + day, contentId: "c"))
            try ItemDao.upsert(
                db,
                item(
                    "readRecently", status: .archived, savedAt: 1, archivedAt: 1, lastReadAt: cutoff + day,
                    contentId: "c"))
            try ItemDao.upsert(
                db, item("fetchedRecently", status: .archived, savedAt: 1, archivedAt: 1, contentId: "c"))
            try ItemDao.upsert(
                db, item("fav", status: .archived, favorite: true, savedAt: 1, archivedAt: 1, contentId: "c"))
            try ItemDao.upsert(db, item("unread", savedAt: 1, contentId: "c"))
            for id in ["ev", "recentArchive", "readRecently", "fav", "unread"] {
                try ContentFileDao.upsert(
                    db, ContentFileRecord(itemId: id, contentId: "c", state: .downloaded, downloadedAt: 1))
            }
            try ContentFileDao.upsert(
                db,
                ContentFileRecord(
                    itemId: "fetchedRecently", contentId: "c", state: .downloaded, downloadedAt: cutoff + 1))
            #expect(try ContentFileDao.evictionCandidates(db, archivedBefore: cutoff) == ["ev"])
        }
    }

    @Test func `Offline state is derived from the content file row`() async throws {
        var iterator = database.observeOffline(itemId: "missing").makeAsyncIterator()
        #expect(try await iterator.next() == .availableRemote)
        try await database.write { db in
            try ContentFileDao.upsert(db, ContentFileRecord(itemId: "missing", contentId: "c", state: .downloading))
        }
        #expect(try await iterator.next() == .downloading)
        try await database.write { db in try ItemDao.delete(db, id: "missing") }
        #expect(try await iterator.next() == OfflineState.none)
    }
}
