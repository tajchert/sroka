import Foundation
import GRDB
import SrokaCore
import Testing

@testable import SrokaDatabase

struct FtsQueryTests {
    @Test func `A single term is a quoted prefix`() {
        #expect(FtsQuery.build("kotlin") == "\"kotlin\"*")
    }

    @Test func `Several terms are joined with AND`() {
        #expect(FtsQuery.build("  red   fox ") == "\"red\"* AND \"fox\"*")
    }

    @Test func `Syntax characters separate terms`() {
        #expect(FtsQuery.build("a\" * ( ) : ^ - b") == "\"a\"* AND \"b\"*")
        #expect(FtsQuery.build("title:x*") == "\"title\"* AND \"x\"*")
    }

    @Test func `Operators become literal words`() {
        #expect(
            FtsQuery.build("cats OR dogs NOT NEAR") == "\"cats\"* AND \"OR\"* AND \"dogs\"* AND \"NOT\"* AND \"NEAR\"*")
    }

    @Test func `Punctuation only yields nil`() {
        #expect(FtsQuery.build("\"*()-:^") == nil)
        #expect(FtsQuery.build("   ") == nil)
        #expect(FtsQuery.build("") == nil)
    }

    @Test func `Unicode letters and combining marks are kept`() {
        #expect(FtsQuery.build("zażółć") == "\"zażółć\"*")
        #expect(FtsQuery.build("cafe\u{301}") == "\"cafe\u{301}\"*")
        #expect(FtsQuery.build("東京 2024") == "\"東京\"* AND \"2024\"*")
    }

    @Test func `Terms are capped in number and length`() {
        let many = (1...20).map { "w\($0)" }.joined(separator: " ")
        #expect(FtsQuery.terms(many).count == FtsQuery.maxTerms)
        #expect(FtsQuery.build(String(repeating: "x", count: 500))?.count == FtsQuery.maxTermLength + 3)
    }
}

struct SearchTests {
    let database: AppDatabase

    init() throws {
        database = try makeDatabase()
    }

    @Test func `Index follows inserts, title changes, tags and deletes`() throws {
        try database.run { db in
            try ItemDao.upsert(
                db, item("a", title: "Kotlin coroutines guide", excerpt: "flows", siteName: "Blog"), tags: ["Dev"])
            try ItemDao.upsert(db, item("b", title: "Café résumé", savedAt: 2_000))
        }
        #expect(try database.searchIds("corout") == ["a"])
        #expect(try database.searchIds("kotlin guide") == ["a"])
        #expect(try database.searchIds("dev") == ["a"])
        #expect(try database.searchIds("blog") == ["a"])
        #expect(try database.searchIds("flows") == ["a"])
        #expect(try database.searchIds("nothing").isEmpty)

        try database.run { db in try ItemDao.setTitle(db, id: "a", title: "Rust ownership") }
        #expect(try database.searchIds("kotlin").isEmpty)
        #expect(try database.searchIds("rust") == ["a"])
        #expect(try database.searchIds("dev") == ["a"])

        try database.run { db in try ItemDao.replaceTags(db, itemId: "a", names: ["Ops"]) }
        #expect(try database.searchIds("dev").isEmpty)
        #expect(try database.searchIds("ops") == ["a"])

        try database.run { db in try ItemDao.delete(db, id: "a") }
        #expect(try database.searchIds("rust").isEmpty)
        let ftsRows = try database.writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM items_fts") }
        #expect(ftsRows == 1)
    }

    @Test func `Diacritics are folded both ways`() throws {
        try database.run { db in
            try ItemDao.upsert(db, item("b", title: "Café résumé"))
            try ItemDao.upsert(db, item("p", title: "Zażółć gęślą jaźń"))
        }
        #expect(try database.searchIds("cafe resume") == ["b"])
        #expect(try database.searchIds("CAFÉ") == ["b"])
        // "ł" is its own letter (no combining mark), so unicode61 keeps it, as on Android.
        #expect(try database.searchIds("zazołc gesla") == ["p"])
        #expect(try database.searchIds("zazolc").isEmpty)
        #expect(try database.searchIds("jaźń") == ["p"])
    }

    @Test func `Body is searchable and survives upserts`() throws {
        try database.run { db in
            try ItemDao.upsert(db, item("a", title: "Plain"))
            try ItemDao.setFtsBody(db, itemId: "a", body: "the quick brown fox jumps")
        }
        #expect(try database.searchIds("brown fox") == ["a"])
        try database.run { db in try ItemDao.upsert(db, item("a", title: "Plain renamed")) }
        #expect(try database.searchIds("quick") == ["a"])
        #expect(try database.searchIds("renamed") == ["a"])
        try database.run { db in try ItemDao.setFtsBody(db, itemId: "a", body: "") }
        #expect(try database.searchIds("quick").isEmpty)
    }

    @Test func `Search syntax is neutralized`() throws {
        try database.run { db in try ItemDao.upsert(db, item("a", title: "Hello world")) }
        for text in ["\"", "hello AND", "(hello", "hello*:", "-hello", "NEAR(", "{title}: x", "hello OR"] {
            _ = try database.searchIds(text)
        }
        #expect(try database.searchIds("\"hello\" -") == ["a"])
    }

    @Test func `Hits say whether the title or the text matched, with highlighted snippets`() throws {
        try database.run { db in
            try ItemDao.upsert(db, item("t", title: "Zebra crossing", savedAt: 3))
            try ItemDao.upsert(db, item("b", title: "Plain", savedAt: 2))
            try ItemDao.setFtsBody(
                db, itemId: "b", body: "A long story about a zebra that wandered far across the savanna.")
            try ItemDao.upsert(db, item("x", title: "Zebra facts", savedAt: 1))
            try ItemDao.setFtsBody(db, itemId: "x", body: "Everything about the zebra stripes.")
            try ItemDao.upsert(db, item("g", title: "Animals", savedAt: 0), tags: ["zebras"])
        }
        let page = try database.writer.read { db in try SearchDao.page(db, query: "zebr", scope: .all, limit: 10) }
        #expect(page.results.map(\.id) == ["t", "b", "x", "g"])
        #expect(page.results.map(\.matchIn) == [.title, .text, .both, .title])
        #expect(page.results[0].snippet == nil)
        let body = page.results[1]
        let snippet = try #require(body.snippet)
        #expect(snippet.contains("zebra"))
        #expect(!snippet.contains("\u{E000}"))
        let range = try #require(body.highlights.first)
        let utf16 = Array(snippet.utf16)
        #expect(String(decoding: utf16[range], as: UTF16.self) == "zebra")
    }

    @Test func `Scopes and counts agree`() throws {
        try database.run { db in
            try ItemDao.upsert(db, item("u", title: "Topic unread", savedAt: 4))
            try ItemDao.upsert(db, item("a", title: "Topic archived", status: .archived, savedAt: 3, archivedAt: 1))
            try ItemDao.upsert(db, item("f", title: "Topic fav", favorite: true, savedAt: 2))
            try ItemDao.upsert(
                db, item("af", title: "Topic both", status: .archived, favorite: true, savedAt: 1, archivedAt: 1))
            try ItemDao.upsert(db, item("n", title: "Other", savedAt: 0))
        }
        #expect(try database.searchIds("topic") == ["u", "a", "f", "af"])
        #expect(try database.searchIds("topic", scope: .archive) == ["a", "af"])
        #expect(try database.searchIds("topic", scope: .favorites) == ["f", "af"])
        try database.writer.read { db in
            #expect(try SearchDao.count(db, query: "topic", scope: .all) == 4)
            #expect(try SearchDao.count(db, query: "topic", scope: .archive) == 2)
            #expect(try SearchDao.count(db, query: "topic", scope: .favorites) == 2)
            #expect(try SearchDao.count(db, query: "  ", scope: .all) == 0)
            let limited = try SearchDao.page(db, query: "topic", scope: .all, limit: 2)
            #expect(limited.results.count == 2)
            #expect(limited.hasMore)
        }
    }

    @Test func `Search rows carry the pending change`() throws {
        try database.run { db in
            try ItemDao.upsert(db, item("a", title: "Topic"))
            try PendingOpDao.enqueue(db, op("o", item: "a", type: "item.add"))
        }
        let result = try database.writer.read { db in try SearchDao.page(db, query: "topic", scope: .all, limit: 5) }
        #expect(result.results.first?.summary.pendingChange == .save)
    }

    @Test func `Snippet parsing strips markers and keeps UTF-16 ranges`() throws {
        let parsed = try #require(parseSnippet("…🙂 \u{E000}zebra\u{E001} and \u{E000}zeb\u{E001}"))
        #expect(parsed.text == "…🙂 zebra and zeb")
        #expect(parsed.ranges == [4..<9, 14..<17])
        #expect(parseSnippet("  ") == nil)
        #expect(parseSnippet(nil) == nil)
    }
}
