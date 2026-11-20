import Foundation
import GRDB
import SrokaCore
import Testing

@testable import SrokaDatabase

struct SchemaTests {
    @Test func `Migration v1 creates every table and index`() throws {
        let database = try makeDatabase()
        try database.writer.read { db in
            for table in Schema.tables { #expect(try db.tableExists(table), "\(table)") }
            let indexes = try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND name LIKE 'index_%' ORDER BY name"
            )
            #expect(
                indexes == [
                    "index_content_files_state", "index_item_tags_name_key", "index_items_canonical_url",
                    "index_items_fts_rowid", "index_items_is_favorite_saved_at_id", "index_items_saved_at",
                    "index_items_status_saved_at_id", "index_pending_ops_item_id", "index_pending_ops_op_id",
                    "index_tags_name_key",
                ])
            #expect(try Schema.migrator.hasCompletedMigrations(db))
            #expect(try Schema.migrator.appliedIdentifiers(db) == Set(Schema.migrator.migrations))
        }
    }

    @Test func `FTS index is FTS5 with diacritics removal 2`() throws {
        let database = try makeDatabase()
        let sql = try database.writer.read { db in
            try String.fetchOne(db, sql: "SELECT sql FROM sqlite_master WHERE name = 'items_fts'")
        }
        #expect(sql?.contains("fts5") == true)
        #expect(sql?.contains("remove_diacritics 2") == true)
    }

    @Test func `Item tags cascade on item update and delete`() throws {
        let database = try makeDatabase()
        let fks = try database.writer.read { db in
            try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(item_tags)")
        }
        #expect(fks.count == 1)
        #expect(fks.first?["on_update"] == "CASCADE")
        #expect(fks.first?["on_delete"] == "CASCADE")
    }

    @Test func `Stored enum literals match Android`() throws {
        let database = try makeDatabase()
        try database.run { db in
            try ItemDao.upsert(db, item("a", status: .archived, parseStatus: .partial, kind: .pdf))
        }
        let row = try database.writer.read { db in
            try Row.fetchOne(db, sql: "SELECT status, parse_status, kind FROM items")
        }
        #expect(row?["status"] == "ARCHIVED")
        #expect(row?["parse_status"] == "PARTIAL")
        #expect(row?["kind"] == "PDF")
    }

    @Test func `Shared file opens with persistent WAL and the extension sees it only once migrated`() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "sroka-db-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: AppDatabase.fileName)

        #expect(throws: DatabaseOpenError.needsAppUpdate) { try AppDatabase.openForExtension(at: url) }

        // A file that exists but was never migrated (e.g. an older app created it) is refused too.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try DatabaseQueue(path: url.path).write { db in try db.execute(sql: "CREATE TABLE t (x)") }
        #expect(throws: DatabaseOpenError.needsAppUpdate) { try AppDatabase.openForExtension(at: url) }
        let untouched = try DatabaseQueue(path: url.path).read { db in
            try String.fetchOne(db, sql: "PRAGMA journal_mode")
        }
        #expect(untouched == "delete")
        try FileManager.default.removeItem(at: directory)

        let app = try AppDatabase.openShared(at: url)
        try app.run { db in try ItemDao.upsert(db, item("a", title: "Shared")) }
        let mode = try app.writer.read { db in try String.fetchOne(db, sql: "PRAGMA journal_mode") }
        #expect(mode == "wal")

        let ext = try AppDatabase.openForExtension(at: url)
        #expect(try ext.ids(ItemQuery(tab: .myList)) == ["a"])
        try ext.run { db in try ItemDao.upsert(db, item("b", savedAt: 2_000)) }
        #expect(try app.ids(ItemQuery(tab: .myList)) == ["b", "a"])

        // Re-opening an already migrated file is a no-op migration.
        _ = try AppDatabase.openShared(at: url)
    }

    @Test func `A file migrated by a newer app is refused`() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "sroka-db-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: AppDatabase.fileName)
        _ = try AppDatabase.openShared(at: url)
        try DatabaseQueue(path: url.path).write { db in
            try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v999')")
        }
        #expect(throws: DatabaseOpenError.supersededSchema) { try AppDatabase.openShared(at: url) }
        #expect(throws: DatabaseOpenError.needsAppUpdate) { try AppDatabase.openForExtension(at: url) }
    }

    @Test func `Wipe empties every table and keeps the schema`() throws {
        let database = try makeDatabase()
        try database.run { db in
            try ItemDao.upsert(db, item("a", title: "Wipe me", contentId: "c"), tags: ["t"])
            try TagDao.upsertRows(db, [TagRecord(id: "tag1", name: "t")])
            try PendingOpDao.enqueue(db, op("o1", item: "a", type: "item.add"))
            try SyncStateDao.set(db, SyncStateRecord(cursor: 42))
            try ContentFileDao.upsert(db, ContentFileRecord(itemId: "a", contentId: "c", state: .downloaded))
            try MaintenanceDao.wipeAll(db)
        }
        try database.writer.read { (db: Database) throws in
            for table in Schema.tables {
                #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") == 0, "\(table)")
            }
            #expect(try SyncStateDao.get(db).cursor == 0)
        }
        #expect(try database.searchIds("wipe").isEmpty)
    }
}
