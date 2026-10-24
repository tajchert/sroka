/**
 * LibraryDO SQLite schema (design §7.1 + docs/api.md §15, decisions D5).
 * Migrations run in the DO constructor inside blockConcurrencyWhile; each step in its own transactionSync,
 * tracked in the `_schema` table (PRAGMA user_version is not authorized in DO SQLite). Never edit an existing step — append a new one.
 */

export const MIGRATIONS: readonly string[][] = [
  // v1
  [
    `CREATE TABLE meta (k TEXT PRIMARY KEY, v)`,
    `INSERT INTO meta (k, v) VALUES ('seq', 0), ('tombstone_horizon', 0)`,
    `CREATE TABLE items (
      id              TEXT PRIMARY KEY,
      url             TEXT NOT NULL,
      canonical_url   TEXT NOT NULL,
      url_hash        TEXT NOT NULL,
      domain          TEXT NOT NULL,
      title           TEXT,
      user_title      TEXT,
      excerpt         TEXT,
      site_name       TEXT,
      author          TEXT,
      lang            TEXT,
      lead_image_key  TEXT,
      word_count      INTEGER,
      reading_minutes INTEGER,
      content_id      TEXT,
      content_private INTEGER NOT NULL DEFAULT 0,
      parse_status    TEXT NOT NULL DEFAULT 'pending',
      parse_error     TEXT,
      parse_gen       INTEGER NOT NULL DEFAULT 0,
      status          TEXT NOT NULL DEFAULT 'unread',
      is_favorite     INTEGER NOT NULL DEFAULT 0,
      progress        REAL NOT NULL DEFAULT 0,
      progress_anchor INTEGER,
      saved_at        INTEGER NOT NULL,
      archived_at     INTEGER,
      last_read_at    INTEGER,
      deleted_at      INTEGER,
      source          TEXT,
      clock           TEXT NOT NULL,
      seq             INTEGER NOT NULL,
      fts_rowid       INTEGER UNIQUE
    )`,
    `CREATE UNIQUE INDEX items_url ON items(url_hash) WHERE deleted_at IS NULL`,
    `CREATE INDEX items_seq ON items(seq)`,
    `CREATE INDEX items_saved ON items(saved_at, id)`,
    `CREATE INDEX items_words ON items(word_count, id)`,
    `CREATE INDEX items_domain ON items(domain)`,
    `CREATE TABLE tags (
      id         TEXT PRIMARY KEY,
      name       TEXT NOT NULL,
      name_key   TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      deleted_at INTEGER,
      seq        INTEGER NOT NULL
    )`,
    `CREATE UNIQUE INDEX tags_name_key ON tags(name_key) WHERE deleted_at IS NULL`,
    `CREATE INDEX tags_key_all ON tags(name_key)`,
    `CREATE INDEX tags_seq ON tags(seq)`,
    `CREATE TABLE item_tags (
      item_id TEXT NOT NULL,
      tag_id  TEXT NOT NULL,
      present INTEGER NOT NULL,
      at      INTEGER NOT NULL,
      dev     TEXT NOT NULL,
      PRIMARY KEY (item_id, tag_id)
    )`,
    `CREATE INDEX item_tags_tag ON item_tags(tag_id)`,
    `CREATE TABLE applied_ops (
      device_id  TEXT NOT NULL,
      op_id      TEXT NOT NULL,
      applied_at INTEGER NOT NULL,
      alias      TEXT,
      PRIMARY KEY (device_id, op_id)
    )`,
    `CREATE INDEX applied_ops_at ON applied_ops(applied_at)`,
    `CREATE TABLE item_aliases (client_id TEXT PRIMARY KEY, target_id TEXT NOT NULL)`,
    `CREATE TABLE tag_renames (from_key TEXT PRIMARY KEY, to_tag_id TEXT NOT NULL, at INTEGER NOT NULL)`,
    // Regular (not contentless) FTS5 table, maintained manually (api.md §8.5, D5).
    `CREATE VIRTUAL TABLE items_fts USING fts5(title, excerpt, site_name, tags)`,
  ],
  // v2: server-time bookkeeping. `deleted_at` / `tag_renames.at` hold the (clamped) client `at` and stay the
  // LWW / stale-op reference; purging (prune) uses the server-time columns so a skewed or long-offline
  // client can't get a fresh tombstone purged immediately. parse_requested_at / parse_raw_key let the alarm
  // re-enqueue parse jobs whose queue send was lost.
  [
    `ALTER TABLE items ADD COLUMN tombstoned_at INTEGER`,
    `UPDATE items SET tombstoned_at = deleted_at WHERE deleted_at IS NOT NULL`,
    `ALTER TABLE tags ADD COLUMN tombstoned_at INTEGER`,
    `UPDATE tags SET tombstoned_at = deleted_at WHERE deleted_at IS NOT NULL`,
    `ALTER TABLE tag_renames ADD COLUMN recorded_at INTEGER`,
    `UPDATE tag_renames SET recorded_at = at`,
    `ALTER TABLE items ADD COLUMN parse_requested_at INTEGER`,
    `ALTER TABLE items ADD COLUMN parse_raw_key TEXT`,
    `CREATE INDEX items_tombstoned ON items(tombstoned_at) WHERE tombstoned_at IS NOT NULL`,
    `CREATE INDEX items_pending ON items(parse_requested_at) WHERE parse_status = 'pending' AND deleted_at IS NULL`,
  ],
  // v3: shared-content references (api.md §9 "Content references"). `content_ref_outbox` = public content ids
  // whose D1 `content_refs` row may be out of date; `gen` is bumped on every re-mark so a flush only clears an
  // entry that did not change while its D1 write was in flight. The desired state is recomputed from `items`
  // at flush time (never stored), so the outbox is order-independent and idempotent.
  [
    `CREATE TABLE content_ref_outbox (content_id TEXT PRIMARY KEY, gen INTEGER NOT NULL)`,
    `CREATE INDEX items_content ON items(content_id) WHERE content_id IS NOT NULL`,
  ],
  // v4: uploaded PDFs (decisions D12). kind 'article' (default, all existing rows) | 'pdf'.
  [
    `ALTER TABLE items ADD COLUMN kind TEXT NOT NULL DEFAULT 'article'`,
    `ALTER TABLE items ADD COLUMN file_name TEXT`,
    `ALTER TABLE items ADD COLUMN file_size INTEGER`,
    `CREATE INDEX items_pdf ON items(file_size) WHERE kind = 'pdf' AND deleted_at IS NULL`,
  ],
];

export const SCHEMA_VERSION = MIGRATIONS.length;

/**
 * Applies pending migrations. Call inside blockConcurrencyWhile (or any sync context).
 * NOTE: DO SQLite rejects `PRAGMA user_version` (SQLITE_AUTH, verified in workerd), so the version lives in
 * a one-row `_schema` table instead (same semantics).
 */
export function migrate(storage: DurableObjectStorage): void {
  const sql = storage.sql;
  sql.exec("CREATE TABLE IF NOT EXISTS _schema (id INTEGER PRIMARY KEY CHECK (id = 1), version INTEGER NOT NULL)");
  const current = Number(sql.exec<{ version: number }>("SELECT version FROM _schema WHERE id = 1").toArray()[0]?.version ?? 0);
  for (let v = current; v < MIGRATIONS.length; v++) {
    storage.transactionSync(() => {
      for (const stmt of MIGRATIONS[v]!) {
        try {
          sql.exec(stmt);
        } catch (e) {
          throw new Error(`LibraryDO migration v${v + 1} failed at: ${stmt.slice(0, 80)}: ${String(e)}`);
        }
      }
      sql.exec(
        "INSERT INTO _schema (id, version) VALUES (1, ?) ON CONFLICT(id) DO UPDATE SET version = excluded.version",
        v + 1,
      );
    });
  }
}
