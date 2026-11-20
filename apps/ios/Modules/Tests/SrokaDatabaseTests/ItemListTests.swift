import Foundation
import GRDB
import SrokaCore
import Testing

@testable import SrokaDatabase

struct ItemListTests {
    let database: AppDatabase

    init() throws {
        database = try makeDatabase()
        try database.run { db in
            try ItemDao.upsert(db, item("old", savedAt: 100, words: 900, minutes: 4))
            try ItemDao.upsert(db, item("mid", savedAt: 200, words: 100, minutes: 1))
            try ItemDao.upsert(db, item("new", favorite: true, savedAt: 300, words: 5000, minutes: 22))
            try ItemDao.upsert(db, item("nowords", savedAt: 250))
            try ItemDao.upsert(
                db, item("arch", status: .archived, savedAt: 150, archivedAt: 160, words: 50, minutes: 1))
            try ItemDao.upsert(db, item("archfav", status: .archived, favorite: true, savedAt: 50, archivedAt: 60))
            try ItemDao.replaceTags(db, itemId: "old", names: ["Swift", "iOS"])
            try ItemDao.replaceTags(db, itemId: "new", names: ["swift"])
            try ItemDao.replaceTags(db, itemId: "arch", names: ["Swift"])
        }
    }

    @Test func `Each sort orders the list`() throws {
        #expect(try database.ids(ItemQuery(tab: .myList, sort: .newest)) == ["new", "nowords", "mid", "old"])
        #expect(try database.ids(ItemQuery(tab: .myList, sort: .oldest)) == ["old", "mid", "nowords", "new"])
        // Unknown length always last; ties by newest.
        #expect(try database.ids(ItemQuery(tab: .myList, sort: .shortest)) == ["mid", "old", "new", "nowords"])
        #expect(try database.ids(ItemQuery(tab: .myList, sort: .longest)) == ["new", "old", "mid", "nowords"])
    }

    @Test func `Tabs select status or favorites`() throws {
        #expect(try database.ids(ItemQuery(tab: .archive)) == ["arch", "archfav"])
        #expect(try database.ids(ItemQuery(tab: .favorites)) == ["new", "archfav"])
        #expect(try database.ids(ItemQuery(tab: nil)).count == 6)
    }

    @Test func `Filters combine with AND`() throws {
        #expect(try database.ids(ItemQuery(tab: .myList, favoritesOnly: true)) == ["new"])
        #expect(try database.ids(ItemQuery(tab: .myList, maxReadingMinutes: 10)) == ["mid", "old"])
        #expect(try database.ids(ItemQuery(tab: .myList, tag: "SWIFT")) == ["new", "old"])
        #expect(try database.ids(ItemQuery(tab: .myList, tag: "swift", maxReadingMinutes: 10)) == ["old"])
        #expect(try database.ids(ItemQuery(tab: .myList, tag: "swift", favoritesOnly: true)) == ["new"])
        #expect(try database.ids(ItemQuery(tab: nil, tag: "swift")) == ["new", "arch", "old"])
        #expect(try database.ids(ItemQuery(tab: .archive, tag: "swift", maxReadingMinutes: 1)) == ["arch"])
        #expect(try database.ids(ItemQuery(tab: .favorites, favoritesOnly: true)) == ["new", "archfav"])
    }

    @Test func `Search narrows the list and a symbol-only search is empty`() throws {
        try database.run { db in try ItemDao.setTitle(db, id: "mid", title: "Zebra stripes") }
        #expect(try database.ids(ItemQuery(tab: .myList, search: "zeb")) == ["mid"])
        #expect(try database.ids(ItemQuery(tab: .archive, search: "zeb")).isEmpty)
        #expect(try database.ids(ItemQuery(tab: .myList, tag: "swift", search: "swift")) == ["new", "old"])
        #expect(try database.ids(ItemQuery(tab: .myList, search: "*()")).isEmpty)
    }

    @Test func `Growing limit reports more rows`() throws {
        let first = try database.writer.read { db in try ItemDao.page(db, query: ItemQuery(tab: .myList), limit: 2) }
        #expect(first.items.map(\.id) == ["new", "nowords"])
        #expect(first.hasMore)
        let all = try database.writer.read { db in try ItemDao.page(db, query: ItemQuery(tab: .myList), limit: 4) }
        #expect(all.items.count == 4)
        #expect(!all.hasMore)
    }

    @Test func `Rows map to summaries with tags, offline state and pending change`() throws {
        try database.run { db in
            try ItemDao.upsert(db, item("c", title: "  ", savedAt: 400, contentId: "v2"))
            try ContentFileDao.upsert(db, ContentFileRecord(itemId: "c", contentId: "v1", state: .downloaded))
            try PendingOpDao.enqueue(db, op("o1", item: "c", type: "item.tag"))
            try PendingOpDao.enqueue(db, op("o2", item: "c", type: "item.setProgress"))
        }
        let page = try database.writer.read { db in try ItemDao.page(db, query: ItemQuery(tab: .myList), limit: 10) }
        let c = try #require(page.items.first)
        #expect(c.id == "c")
        #expect(c.displayTitle == "example.com")
        #expect(c.offline == .availableRemote)
        #expect(c.pendingChange == .tags)
        #expect(c.savedAt == Date(timeIntervalSince1970: 0.4))
        let old = try #require(page.items.first { $0.id == "old" })
        #expect(old.tags == ["iOS", "Swift"])
    }

    @Test func `Pending change follows the newest non-progress op`() throws {
        func pending(_ id: String) throws -> PendingChange? {
            try database.writer.read { db in
                try ItemDao.page(db, query: ItemQuery(tab: nil), limit: 100).items.first { $0.id == id }?.pendingChange
            }
        }
        #expect(try pending("old") == nil)
        try database.run { db in try PendingOpDao.enqueue(db, op("1", item: "old", type: "item.add")) }
        #expect(try pending("old") == .save)
        try database.run { db in try PendingOpDao.enqueue(db, op("2", item: "old", type: "item.setFavorite")) }
        #expect(try pending("old") == .favorite)
        try database.run { db in try PendingOpDao.enqueue(db, op("3", item: "old", type: "item.setStatus")) }
        #expect(try pending("old") == .other)
        try database.run { db in try PendingOpDao.enqueue(db, op("4", item: "old", type: "item.setProgress")) }
        #expect(try pending("old") == .other)
        try database.run { db in try PendingOpDao.deleteForItem(db, "old") }
        #expect(try pending("old") == nil)
    }

    @Test func `Continue reading takes unread items between 5 and 95 percent`() throws {
        try database.run { db in
            try ItemDao.setProgress(db, id: "old", progress: 0.5, anchor: 3, readAt: 10)
            try ItemDao.setProgress(db, id: "mid", progress: 0.2, anchor: nil, readAt: 20)
            try ItemDao.setProgress(db, id: "new", progress: 0.99, anchor: nil, readAt: 30)
            try ItemDao.setProgress(db, id: "nowords", progress: 0.01, anchor: nil, readAt: 40)
            try ItemDao.setProgress(db, id: "arch", progress: 0.5, anchor: nil, readAt: 50)
        }
        let ids = try database.writer.read { db in try ItemDao.continueReading(db, limit: 10).map(\.id) }
        #expect(ids == ["mid", "old"])
    }

    @Test func `Next unread and next readable skip the excluded item`() throws {
        try database.run { db in
            try ItemDao.upsert(db, item("pending", savedAt: 500, parseStatus: .pending))
            try ItemDao.upsert(db, item("pdf", savedAt: 450, parseStatus: .pending, kind: .pdf))
        }
        try database.writer.read { (db: Database) throws in
            #expect(try ItemDao.nextUnread(db, excludeId: nil)?.id == "pending")
            #expect(try ItemDao.nextUnread(db, excludeId: "pending")?.id == "pdf")
            #expect(try ItemDao.nextReadable(db, excludeId: nil)?.id == "pdf")
            #expect(try ItemDao.nextReadable(db, excludeId: "pdf")?.id == "new")
        }
    }

    @Test func `Counts, detail and canonical URL lookup`() throws {
        try database.writer.read { db in
            #expect(try ItemDao.counts(db) == LibraryCounts(unread: 4, archived: 2, favorites: 2))
            let detail = try #require(try ItemDao.detail(db, id: "old")?.toItem())
            #expect(detail.tags == ["iOS", "Swift"])
            #expect(detail.offline == .none)
            #expect(try ItemDao.item(db, canonicalUrl: "https://example.com/mid")?.id == "mid")
            #expect(try ItemDao.item(db, canonicalUrl: "https://example.com/zzz") == nil)
            #expect(try ItemDao.existingIds(db, ["old", "zzz", "mid"]).sorted() == ["mid", "old"])
        }
    }

    @Test func `Observation emits the current page then changes`() async throws {
        var iterator = database.observeItems(ItemQuery(tab: .archive), limit: 10).makeAsyncIterator()
        #expect(try await iterator.next()?.items.map(\.id) == ["arch", "archfav"])
        try await database.write { db in try ItemDao.setStatus(db, id: "old", status: .archived, archivedAt: 1) }
        #expect(try await iterator.next()?.items.map(\.id) == ["arch", "old", "archfav"])
    }
}
