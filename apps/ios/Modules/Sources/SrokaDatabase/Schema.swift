import GRDB

/// The database schema. A port of Android's Room schema version 3
/// (`apps/android/core/database/schemas/…/3.json`), with two deliberate differences:
/// `item_tags` declares `ON UPDATE CASCADE` (so re-keying an item is one `UPDATE`), and `items_fts`
/// is FTS5 with `remove_diacritics 2` instead of FTS4.
///
/// Rules: migrations are append-only and never destructive (no drop-and-recreate). A migration that
/// starts reading a new server field also sets `sync_state.cursor = 0` so every row is pulled again.
public enum Schema {
    /// Every table, FTS index included.
    public static let tables = [
        "items", "item_tags", "tags", "items_fts", "pending_ops", "sync_state", "content_files",
    ]

    /// The migrator for every database file. `eraseDatabaseOnSchemaChange` stays off on purpose.
    public static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try createV1(db)
        }
        return migrator
    }

    private static func createV1(_ db: Database) throws {
        try db.execute(
            sql: """
                CREATE TABLE items (
                  id TEXT NOT NULL PRIMARY KEY,
                  url TEXT NOT NULL,
                  canonical_url TEXT NOT NULL,
                  title TEXT,
                  excerpt TEXT,
                  site_name TEXT,
                  author TEXT,
                  lang TEXT,
                  lead_image_key TEXT,
                  word_count INTEGER,
                  reading_minutes INTEGER,
                  content_id TEXT,
                  content_private INTEGER NOT NULL,
                  parse_status TEXT NOT NULL,
                  parse_error TEXT,
                  status TEXT NOT NULL,
                  is_favorite INTEGER NOT NULL,
                  progress REAL NOT NULL,
                  progress_anchor INTEGER,
                  saved_at INTEGER NOT NULL,
                  archived_at INTEGER,
                  last_read_at INTEGER,
                  source TEXT,
                  server_seq INTEGER,
                  fts_rowid INTEGER NOT NULL,
                  resync_mark INTEGER NOT NULL DEFAULT 0,
                  kind TEXT NOT NULL DEFAULT 'ARTICLE',
                  file_name TEXT,
                  file_size INTEGER
                );
                CREATE INDEX index_items_status_saved_at_id ON items (status, saved_at, id);
                CREATE INDEX index_items_is_favorite_saved_at_id ON items (is_favorite, saved_at, id);
                CREATE INDEX index_items_saved_at ON items (saved_at);
                CREATE INDEX index_items_canonical_url ON items (canonical_url);
                CREATE UNIQUE INDEX index_items_fts_rowid ON items (fts_rowid);

                CREATE TABLE item_tags (
                  item_id TEXT NOT NULL REFERENCES items(id) ON UPDATE CASCADE ON DELETE CASCADE,
                  name_key TEXT NOT NULL,
                  name TEXT NOT NULL,
                  PRIMARY KEY (item_id, name_key)
                );
                CREATE INDEX index_item_tags_name_key ON item_tags (name_key);

                CREATE TABLE tags (
                  id TEXT NOT NULL PRIMARY KEY,
                  name TEXT NOT NULL,
                  name_key TEXT NOT NULL
                );
                CREATE UNIQUE INDEX index_tags_name_key ON tags (name_key);

                CREATE VIRTUAL TABLE items_fts USING fts5(
                  title, excerpt, site_name, tags, body,
                  tokenize = 'unicode61 remove_diacritics 2'
                );

                CREATE TABLE pending_ops (
                  local_seq INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                  op_id TEXT NOT NULL,
                  item_id TEXT,
                  type TEXT NOT NULL,
                  payload TEXT NOT NULL,
                  created_at INTEGER NOT NULL,
                  attempts INTEGER NOT NULL DEFAULT 0,
                  last_error TEXT
                );
                CREATE UNIQUE INDEX index_pending_ops_op_id ON pending_ops (op_id);
                CREATE INDEX index_pending_ops_item_id ON pending_ops (item_id);

                CREATE TABLE sync_state (
                  id INTEGER NOT NULL PRIMARY KEY,
                  cursor INTEGER NOT NULL,
                  last_success_at INTEGER,
                  last_error TEXT,
                  full_resync INTEGER NOT NULL DEFAULT 0
                );

                CREATE TABLE content_files (
                  item_id TEXT NOT NULL PRIMARY KEY REFERENCES items(id) ON DELETE CASCADE,
                  content_id TEXT NOT NULL,
                  state TEXT NOT NULL,
                  bytes INTEGER NOT NULL DEFAULT 0,
                  attempts INTEGER NOT NULL DEFAULT 0,
                  error TEXT,
                  downloaded_at INTEGER,
                  thumb_path TEXT,
                  thumb_attempts INTEGER NOT NULL DEFAULT 0
                );
                CREATE INDEX index_content_files_state ON content_files (state);
                """
        )
    }
}
