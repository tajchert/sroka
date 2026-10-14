import { log } from "@sroka/shared";
/**
 * LibraryStore — synchronous SQLite logic of the per-user LibraryDO (docs/api.md §7–§9, §15; decisions D5).
 * Everything here is sync (DO SQL API); async work (url hashing, URL signing) happens in library-do.ts.
 */
import {
  type ItemClock,
  type ListItemsQuery,
  type Op,
  type OpOf,
  type ParseJob,
  type ParseResult,
  type PullResponse,
  type PushResponse,
  type RejectReason,
  type Stamp,
  LIMITS,
  applyLww,
  clampAt,
  decodeListCursor,
  displayDomain,
  encodeListCursor,
  normalizeTagName,
  pairWins,
  parseClock,
  r2Keys,
  tagKey,
  uuidv7,
} from "@sroka/shared";
import { buildMatchQuery, escapeLike, normalizeDomainFilter } from "./fts.ts";
import { type ItemData, type ItemRow, type PairRow, type TagRow, compareTagNames, rowToItemData } from "./rows.ts";

type SqlValue = ArrayBuffer | string | number | null;
type Row = Record<string, SqlValue>;

/** Precomputed (async) data for an item.add op: canonical URL + sha256 hash, or null if the URL doesn't normalize. */
export type AddInfo = { canonical: string; hash: string } | null;

export class Reject extends Error {
  constructor(readonly reason: RejectReason) {
    super(reason);
  }
}

/** Internal: aborts the outer transaction of applyOpsAtomic. */
class Rollback extends Error {
  constructor(readonly result: ApplyResult) {
    super("rollback");
  }
}

export interface ApplyResult {
  response: PushResponse;
  parseJobs: ParseJob[];
}

export type PullPage = { data: Omit<PullResponse, "items"> & { items: ItemData[] } } | { error: "resync_required" };

export type ListResult = { items: ItemData[]; nextCursor: string | null } | { error: "bad_cursor" };

export interface TagWithCount {
  id: string;
  name: string;
  count: number;
  seq: number;
}

const MAX_ALIAS_HOPS = 10;
const MAX_RENAME_HOPS = 10;
/**
 * Max rows stamped with one seq. A huge op (tag rename/delete/merge over tens of thousands of carriers) spreads
 * its rows over several consecutive seqs so a sync pull "seq group" stays bounded (api.md §7.2).
 */
export const MAX_SEQ_GROUP = 250;
/** item.refresh on an item already pending for less than this is coalesced (no new parse job). */
export const REFRESH_COALESCE_MS = 10 * 60 * 1000;

/**
 * Per-op change context: allocates one seq per op (more only for ops touching > MAX_SEQ_GROUP rows) and
 * tracks touched rows.
 */
class OpCtx {
  private seqValue: number | null = null;
  private rowsInSeq = 0;
  readonly dirtyItems = new Set<string>();
  readonly jobs: ParseJob[] = [];
  /** R2 keys (or prefixes ending in "/") to delete once the op committed. */
  readonly cleanup: string[] = [];
  constructor(
    private readonly store: LibraryStore,
    /** Server time of this request (tombstone / bookkeeping timestamps; never used for LWW). */
    readonly now: number,
  ) {}
  seq(): number {
    if (this.seqValue === null) this.seqValue = this.store.nextSeq();
    return this.seqValue;
  }
  get changed(): boolean {
    return this.seqValue !== null;
  }
  /** Seq for one more stamped row; rolls over to a fresh seq once the current group is full. */
  private rowSeq(): number {
    if (this.seqValue !== null && this.rowsInSeq >= MAX_SEQ_GROUP) {
      this.seqValue = this.store.nextSeq();
      this.rowsInSeq = 0;
    }
    const s = this.seq();
    this.rowsInSeq++;
    return s;
  }
  touchItem(id: string): void {
    if (this.dirtyItems.has(id)) {
      this.store.exec("UPDATE items SET seq = ? WHERE id = ?", this.seq(), id);
      return;
    }
    this.store.exec("UPDATE items SET seq = ? WHERE id = ?", this.rowSeq(), id);
    this.dirtyItems.add(id);
  }
  touchTag(id: string): void {
    this.store.exec("UPDATE tags SET seq = ? WHERE id = ?", this.rowSeq(), id);
  }
}

export class LibraryStore {
  /** R2 keys/prefixes of committed ops awaiting deletion; drained by the LibraryDO (takeCleanup). */
  private pendingCleanup: string[] = [];

  constructor(
    private readonly storage: DurableObjectStorage,
    /** Resolves the owning user id (for ParseJob.userId). */
    private readonly userId: () => string,
  ) {}

  /** Returns and clears the R2 keys (prefixes end in "/") freed by committed ops. */
  takeCleanup(): string[] {
    const out = this.pendingCleanup;
    this.pendingCleanup = [];
    return out;
  }

  // ---------- low-level helpers ----------

  exec(query: string, ...binds: unknown[]): void {
    this.storage.sql.exec(query, ...binds);
  }
  all<T extends Row>(query: string, ...binds: unknown[]): T[] {
    return this.storage.sql.exec<T>(query, ...binds).toArray();
  }
  first<T extends Row>(query: string, ...binds: unknown[]): T | null {
    return this.all<T>(query, ...binds)[0] ?? null;
  }
  private txn<T>(fn: () => T): T {
    return this.storage.transactionSync(fn);
  }

  getMeta(k: string): number {
    return Number(this.first<{ v: number }>("SELECT v FROM meta WHERE k = ?", k)?.v ?? 0);
  }
  private setMeta(k: string, v: number | string): void {
    this.exec("INSERT INTO meta (k, v) VALUES (?, ?) ON CONFLICT(k) DO UPDATE SET v = excluded.v", k, v);
  }
  getMetaText(k: string): string | null {
    const r = this.first<{ v: SqlValue }>("SELECT v FROM meta WHERE k = ?", k);
    return r && typeof r.v === "string" ? r.v : null;
  }
  setMetaText(k: string, v: string): void {
    this.setMeta(k, v);
  }
  setMetaNumber(k: string, v: number): void {
    this.setMeta(k, v);
  }

  nextSeq(): number {
    return Number(this.first<{ v: number }>("UPDATE meta SET v = v + 1 WHERE k = 'seq' RETURNING v")!.v);
  }

  itemRow(id: string): ItemRow | null {
    return this.first<ItemRow>("SELECT * FROM items WHERE id = ?", id);
  }
  private tagRow(id: string): TagRow | null {
    return this.first<TagRow>("SELECT * FROM tags WHERE id = ?", id);
  }
  private liveTagByKey(key: string): TagRow | null {
    return this.first<TagRow>("SELECT * FROM tags WHERE name_key = ? AND deleted_at IS NULL", key);
  }

  resolveItemId(id: string): string {
    let cur = id;
    for (let i = 0; i < MAX_ALIAS_HOPS; i++) {
      const r = this.first<{ target_id: string }>("SELECT target_id FROM item_aliases WHERE client_id = ?", cur);
      if (!r || r.target_id === cur) break;
      cur = r.target_id;
    }
    return cur;
  }

  /** Present tag names of the given items (live tags only). */
  tagsFor(ids: string[]): Map<string, string[]> {
    const out = new Map<string, string[]>();
    if (ids.length === 0) return out;
    for (const id of ids) out.set(id, []);
    const rows = this.all<{ item_id: string; name: string }>(
      `SELECT it.item_id, t.name FROM item_tags it JOIN tags t ON t.id = it.tag_id
       WHERE it.item_id IN (SELECT value FROM json_each(?)) AND it.present = 1 AND t.deleted_at IS NULL`,
      JSON.stringify(ids),
    );
    for (const r of rows) out.get(r.item_id)!.push(r.name);
    return out;
  }

  toItems(rows: ItemRow[]): ItemData[] {
    const tags = this.tagsFor(rows.map((r) => r.id));
    return rows.map((r) => rowToItemData(r, tags.get(r.id) ?? []));
  }

  /** Live item (or null). */
  getItem(id: string): ItemData | null {
    const r = this.itemRow(this.resolveItemId(id));
    if (!r || r.deleted_at !== null) return null;
    return this.toItems([r])[0]!;
  }

  private presentTagCount(itemId: string): number {
    return Number(
      this.first<{ n: number }>(
        `SELECT COUNT(*) AS n FROM item_tags it JOIN tags t ON t.id = it.tag_id
         WHERE it.item_id = ? AND it.present = 1 AND t.deleted_at IS NULL`,
        itemId,
      )!.n,
    );
  }

  private refreshFts(itemId: string): void {
    const r = this.first<{ title: string | null; user_title: string | null; excerpt: string | null; site_name: string | null; deleted_at: number | null; fts_rowid: number | null }>(
      "SELECT title, user_title, excerpt, site_name, deleted_at, fts_rowid FROM items WHERE id = ?",
      itemId,
    );
    if (!r || r.fts_rowid === null) return;
    this.exec("DELETE FROM items_fts WHERE rowid = ?", r.fts_rowid);
    if (r.deleted_at !== null) return;
    const tags = this.tagsFor([itemId]).get(itemId) ?? [];
    this.exec(
      "INSERT INTO items_fts (rowid, title, excerpt, site_name, tags) VALUES (?, ?, ?, ?, ?)",
      r.fts_rowid,
      r.user_title ?? r.title ?? "",
      r.excerpt ?? "",
      r.site_name ?? "",
      tags.join(" "),
    );
  }

  /** Runs `fn` in one transaction with an OpCtx; refreshes FTS of touched items at the end. */
  private withCtx<T>(fn: (ctx: OpCtx) => T, now: number = Date.now()): { value: T; ctx: OpCtx } {
    const res = this.txn(() => {
      const ctx = new OpCtx(this, now);
      const value = fn(ctx);
      for (const id of ctx.dirtyItems) this.refreshFts(id);
      return { value, ctx };
    });
    // Only reached when the transaction committed.
    this.pendingCleanup.push(...res.ctx.cleanup);
    return res;
  }

  private liveItemForOp(itemId: string): ItemRow {
    const row = this.itemRow(this.resolveItemId(itemId));
    if (!row) throw new Reject("unknown_item");
    if (row.deleted_at !== null) throw new Reject("item_deleted");
    return row;
  }

  private newParseJob(ctx: OpCtx, row: ItemRow, extra: { rawKey?: string; force?: boolean } = {}): ParseJob {
    const gen = row.parse_gen + 1;
    // The captured HTML is no longer the parse source (e.g. refresh from the web): don't keep it around.
    if (row.parse_raw_key && row.parse_raw_key !== extra.rawKey) ctx.cleanup.push(row.parse_raw_key);
    this.exec(
      `UPDATE items SET parse_gen = ?, parse_status = 'pending', parse_error = NULL, parse_requested_at = ?,
         parse_raw_key = ? WHERE id = ?`,
      gen,
      ctx.now,
      extra.rawKey ?? null,
      row.id,
    );
    ctx.touchItem(row.id);
    const job: ParseJob = { userId: this.userId(), itemId: row.id, url: row.url, parseGen: gen };
    if (extra.rawKey !== undefined) job.rawKey = extra.rawKey;
    if (extra.force !== undefined) job.force = extra.force;
    return job;
  }

  // ---------- applyOps ----------

  /**
   * Applies ops in order, each in its own transaction (api.md §7.1, §8). `addInfo[i]` must be set for
   * every item.add op at index i. Idempotent per (deviceId, opId).
   */
  applyOps(deviceId: string, ops: Op[], addInfo: AddInfo[], now: number = Date.now()): ApplyResult {
    return this.applyLoop(deviceId, ops, addInfo, now);
  }

  /**
   * All-or-nothing variant for REST requests that synthesize several ops (PATCH /v1/items/:id): if any op is
   * rejected, everything (including applied_ops rows) is rolled back and `applied` is empty.
   */
  applyOpsAtomic(deviceId: string, ops: Op[], addInfo: AddInfo[], now: number = Date.now()): ApplyResult {
    const cleanupMark = this.pendingCleanup.length;
    try {
      return this.txn(() => {
        const res = this.applyLoop(deviceId, ops, addInfo, now);
        if (res.response.rejected.length > 0) throw new Rollback(res);
        return res;
      });
    } catch (e) {
      this.pendingCleanup.length = cleanupMark; // nothing of the rolled-back ops was committed
      if (!(e instanceof Rollback)) throw e;
      const r = e.result.response;
      return { response: { applied: [], rejected: r.rejected, aliases: {}, cursor: this.getMeta("seq") }, parseJobs: [] };
    }
  }

  private applyLoop(deviceId: string, ops: Op[], addInfo: AddInfo[], now: number): ApplyResult {
    const applied: string[] = [];
    const rejected: PushResponse["rejected"] = [];
    const aliases: Record<string, string> = {};
    const parseJobs: ParseJob[] = [];

    ops.forEach((op, i) => {
      const done = this.first<{ alias: string | null }>(
        "SELECT alias FROM applied_ops WHERE device_id = ? AND op_id = ?",
        deviceId,
        op.opId,
      );
      if (done) {
        applied.push(op.opId);
        if (done.alias && op.type === "item.add") aliases[op.itemId] = done.alias;
        return;
      }
      const stamp: Stamp = { at: clampAt(op.at, now), dev: deviceId };
      try {
        const { value: alias, ctx } = this.withCtx((ctx) => {
          const alias = this.applyOne(ctx, op, stamp, addInfo[i] ?? null);
          this.exec(
            "INSERT INTO applied_ops (device_id, op_id, applied_at, alias) VALUES (?, ?, ?, ?)",
            deviceId,
            op.opId,
            now,
            alias,
          );
          return alias;
        }, now);
        applied.push(op.opId);
        if (alias && op.type === "item.add") aliases[op.itemId] = alias;
        parseJobs.push(...ctx.jobs);
      } catch (e) {
        if (e instanceof Reject) rejected.push({ opId: op.opId, reason: e.reason });
        else if (e instanceof Rollback) throw e;
        else {
          // Safety net: an unexpected (SQL) error on one op is rolled back (own transaction) and reported as
          // rejected, so a single bad op can never fail — and permanently wedge — a device's whole push.
          log.exception("LibraryDO applyOps: op failed", e, { event: "do_op_failed", opType: op.type, opId: op.opId });
          rejected.push({ opId: op.opId, reason: "invalid_op" });
        }
      }
    });

    return { response: { applied, rejected, aliases, cursor: this.getMeta("seq") }, parseJobs };
  }

  /** Returns the alias target for an aliased item.add, else null. Throws Reject. */
  private applyOne(ctx: OpCtx, op: Op, stamp: Stamp, info: AddInfo): string | null {
    switch (op.type) {
      case "item.add":
        return this.opAdd(ctx, op, stamp, info);
      case "item.setStatus": {
        const row = this.liveItemForOp(op.itemId);
        const clock = parseClock(row.clock);
        if (applyLww(clock, "status", stamp)) {
          const archivedAt = op.status === "archived" ? stamp.at : null;
          this.exec("UPDATE items SET status = ?, archived_at = ?, clock = ? WHERE id = ?", op.status, archivedAt, JSON.stringify(clock), row.id);
          if (row.status !== op.status || row.archived_at !== archivedAt) ctx.touchItem(row.id);
        }
        return null;
      }
      case "item.setFavorite": {
        const row = this.liveItemForOp(op.itemId);
        const clock = parseClock(row.clock);
        if (applyLww(clock, "isFavorite", stamp)) {
          const v = op.value ? 1 : 0;
          this.exec("UPDATE items SET is_favorite = ?, clock = ? WHERE id = ?", v, JSON.stringify(clock), row.id);
          if (row.is_favorite !== v) ctx.touchItem(row.id);
        }
        return null;
      }
      case "item.setProgress": {
        const row = this.liveItemForOp(op.itemId);
        const clock = parseClock(row.clock);
        if (applyLww(clock, "progress", stamp)) {
          const anchor = op.anchor ?? null;
          this.exec(
            "UPDATE items SET progress = ?, progress_anchor = ?, last_read_at = ?, clock = ? WHERE id = ?",
            op.progress,
            anchor,
            stamp.at,
            JSON.stringify(clock),
            row.id,
          );
          if (row.progress !== op.progress || row.progress_anchor !== anchor || row.last_read_at !== stamp.at) ctx.touchItem(row.id);
        }
        return null;
      }
      case "item.setTitle": {
        const row = this.liveItemForOp(op.itemId);
        const clock = parseClock(row.clock);
        if (applyLww(clock, "title", stamp)) {
          const t = op.title.trim() === "" ? null : op.title.trim();
          this.exec("UPDATE items SET user_title = ?, clock = ? WHERE id = ?", t, JSON.stringify(clock), row.id);
          if (row.user_title !== t) ctx.touchItem(row.id);
        }
        return null;
      }
      case "item.tag": {
        const row = this.liveItemForOp(op.itemId);
        this.setPair(ctx, row.id, op.tag, op.present, stamp);
        return null;
      }
      case "item.delete": {
        const row = this.itemRow(this.resolveItemId(op.itemId));
        if (!row) throw new Reject("unknown_item");
        if (row.deleted_at !== null) return null; // applied no-op
        this.exec("UPDATE items SET deleted_at = ?, tombstoned_at = ? WHERE id = ?", stamp.at, ctx.now, row.id);
        ctx.touchItem(row.id);
        // Captured HTML and private extracted content belong to this item only: delete them with it.
        if (row.parse_raw_key) ctx.cleanup.push(row.parse_raw_key);
        if (row.content_private === 1 && row.content_id) ctx.cleanup.push(r2Keys.contentDir(row.content_id, this.userId()));
        return null;
      }
      case "item.refresh": {
        const row = this.liveItemForOp(op.itemId);
        // Coalesce refresh spam: a parse requested moments ago is still on its way (applied no-op).
        if (row.parse_status === "pending" && row.parse_requested_at !== null && row.parse_requested_at > ctx.now - REFRESH_COALESCE_MS) {
          return null;
        }
        ctx.jobs.push(this.newParseJob(ctx, row, { force: true }));
        return null;
      }
      case "tag.rename":
        this.opTagRename(ctx, op, stamp);
        return null;
      case "tag.delete":
        this.opTagDelete(ctx, op, stamp);
        return null;
    }
  }

  private opAdd(ctx: OpCtx, op: OpOf<"item.add">, stamp: Stamp, info: AddInfo): string | null {
    if (!info) throw new Reject("invalid_url");
    let resolved = this.resolveItemId(op.itemId);
    let target = this.itemRow(resolved);
    if (!target && resolved !== op.itemId) {
      // Stale alias (its target's tombstone was purged): drop it so the new row is reachable by its own id.
      this.exec("DELETE FROM item_aliases WHERE client_id = ?", op.itemId);
      resolved = op.itemId;
      target = this.itemRow(resolved);
    }
    let alias: string | null = resolved !== op.itemId ? resolved : null;
    if (target) {
      if (target.deleted_at !== null) throw new Reject("item_deleted");
    } else {
      const dup = this.first<ItemRow>("SELECT * FROM items WHERE url_hash = ? AND deleted_at IS NULL", info.hash);
      if (dup) {
        target = dup;
        alias = dup.id;
        this.exec("INSERT INTO item_aliases (client_id, target_id) VALUES (?, ?) ON CONFLICT(client_id) DO NOTHING", op.itemId, dup.id);
      }
    }
    const provisionalTitle = op.title && op.title.trim() !== "" ? op.title.trim() : null;

    if (target) {
      // Duplicate (api.md §8.2 step 4).
      if (op.onDuplicate !== "merge") {
        // savedAt = max(savedAt, at) even when the status stamp loses: a max is order-independent, so
        // devices converge regardless of which duplicate add created the row.
        const savedAt = Math.max(target.saved_at, stamp.at);
        if (savedAt !== target.saved_at) {
          this.exec("UPDATE items SET saved_at = ? WHERE id = ?", savedAt, target.id);
          ctx.touchItem(target.id);
        }
        const clock = parseClock(target.clock);
        if (applyLww(clock, "status", stamp)) {
          this.exec(
            "UPDATE items SET status = 'unread', archived_at = NULL, clock = ? WHERE id = ?",
            JSON.stringify(clock),
            target.id,
          );
          if (target.status !== "unread" || target.archived_at !== null) ctx.touchItem(target.id);
        }
        if (provisionalTitle && target.title === null) {
          this.exec("UPDATE items SET title = ? WHERE id = ?", provisionalTitle, target.id);
          ctx.touchItem(target.id);
        }
      }
      for (const t of op.tags ?? []) this.setPair(ctx, target.id, t, true, stamp);
      if (target.parse_status === "failed") ctx.jobs.push(this.newParseJob(ctx, this.itemRow(target.id)!));
      return alias;
    }

    // New item (step 5).
    const status = op.status ?? "unread";
    const clock: ItemClock = { status: { ...stamp } };
    if (op.isFavorite !== undefined) clock.isFavorite = { ...stamp };
    const ftsRowid = Number(this.first<{ n: number }>("SELECT COALESCE(MAX(fts_rowid), 0) + 1 AS n FROM items")!.n);
    this.exec(
      `INSERT INTO items (id, url, canonical_url, url_hash, domain, title, status, archived_at, is_favorite, saved_at,
         source, parse_status, parse_gen, clock, seq, fts_rowid)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', 0, ?, 0, ?)`,
      op.itemId,
      op.url,
      info.canonical,
      info.hash,
      displayDomain(info.canonical).toLowerCase(),
      provisionalTitle,
      status,
      status === "archived" ? stamp.at : null,
      op.isFavorite ? 1 : 0,
      op.savedAt ?? stamp.at,
      op.source ?? null,
      JSON.stringify(clock),
      ftsRowid,
    );
    ctx.touchItem(op.itemId);
    for (const t of op.tags ?? []) this.setPair(ctx, op.itemId, t, true, stamp);
    ctx.jobs.push(this.newParseJob(ctx, this.itemRow(op.itemId)!));
    return null;
  }

  /**
   * Resolves the tag an item.tag-like op (name, at) refers to (api.md §8.4):
   * stale ops follow tag_renames; ops older than a tag delete are no-ops.
   */
  private resolveTag(name: string, at: number): { tag: TagRow } | { noop: true } | { missing: true } {
    const key = tagKey(name);
    const rename = this.first<{ to_tag_id: string; at: number }>("SELECT to_tag_id, at FROM tag_renames WHERE from_key = ?", key);
    if (rename && rename.at >= at) {
      let id = rename.to_tag_id;
      for (let hop = 0; ; hop++) {
        const t = this.tagRow(id);
        if (!t) return { noop: true };
        if (t.deleted_at === null) return { tag: t };
        const next = this.first<{ to_tag_id: string; at: number }>("SELECT to_tag_id, at FROM tag_renames WHERE from_key = ?", t.name_key);
        if (next && next.at >= at && next.to_tag_id !== t.id && hop < MAX_RENAME_HOPS) {
          id = next.to_tag_id;
          continue;
        }
        if (t.deleted_at >= at) return { noop: true };
        // The chain ends at a tombstone older than the op: the rename doesn't apply any more, resolve by the
        // op's own name below (a live tag of that name may exist again).
        break;
      }
    }
    const live = this.liveTagByKey(key);
    if (live) return { tag: live };
    const dead = this.first<{ d: number | null }>("SELECT MAX(deleted_at) AS d FROM tags WHERE name_key = ? AND deleted_at IS NOT NULL", key);
    if (dead?.d != null && dead.d >= at) return { noop: true };
    return { missing: true };
  }

  /** Pair LWW (api.md §8.1) for item `itemId` (must be live) and tag `name`. */
  private setPair(ctx: OpCtx, itemId: string, name: string, present: boolean, stamp: Stamp): void {
    const res = this.resolveTag(name, stamp.at);
    if ("noop" in res) return;
    let tag: TagRow;
    if ("missing" in res) {
      if (!present) return;
      const norm = normalizeTagName(name);
      // Re-check: a live tag of this name may exist even when the op's rename chain was a dead end.
      const live = this.liveTagByKey(tagKey(norm));
      if (live) return this.setPairOn(ctx, itemId, live, present, stamp);
      if (this.presentTagCount(itemId) >= LIMITS.maxTagsPerItem) throw new Reject("too_many_tags");
      tag = { id: uuidv7(), name: norm, name_key: tagKey(norm), created_at: stamp.at, deleted_at: null, seq: 0 };
      this.exec(
        "INSERT INTO tags (id, name, name_key, created_at, deleted_at, seq) VALUES (?, ?, ?, ?, NULL, ?)",
        tag.id,
        tag.name,
        tag.name_key,
        tag.created_at,
        ctx.seq(),
      );
    } else {
      tag = res.tag;
    }
    this.setPairOn(ctx, itemId, tag, present, stamp);
  }

  private setPairOn(ctx: OpCtx, itemId: string, tag: TagRow, present: boolean, stamp: Stamp): void {
    const pair = this.first<PairRow>("SELECT present, at, dev FROM item_tags WHERE item_id = ? AND tag_id = ?", itemId, tag.id);
    if (pair && !pairWins(stamp, { at: pair.at, dev: pair.dev })) return;
    const was = pair?.present === 1;
    if (present && !was && this.presentTagCount(itemId) >= LIMITS.maxTagsPerItem) throw new Reject("too_many_tags");
    this.writePair(itemId, tag.id, present, stamp);
    if (was !== present) ctx.touchItem(itemId);
  }

  private writePair(itemId: string, tagId: string, present: boolean, stamp: Stamp): void {
    this.exec(
      `INSERT INTO item_tags (item_id, tag_id, present, at, dev) VALUES (?, ?, ?, ?, ?)
       ON CONFLICT(item_id, tag_id) DO UPDATE SET present = excluded.present, at = excluded.at, dev = excluded.dev`,
      itemId,
      tagId,
      present ? 1 : 0,
      stamp.at,
      stamp.dev,
    );
  }

  /** Live items currently carrying the tag. */
  private liveCarriers(tagId: string): string[] {
    return this.all<{ id: string }>(
      `SELECT i.id FROM item_tags it JOIN items i ON i.id = it.item_id
       WHERE it.tag_id = ? AND it.present = 1 AND i.deleted_at IS NULL`,
      tagId,
    ).map((r) => r.id);
  }

  private opTagRename(ctx: OpCtx, op: OpOf<"tag.rename">, stamp: Stamp): void {
    const fromKey = tagKey(op.from);
    const toName = normalizeTagName(op.to);
    const toKey = tagKey(toName);
    const from = this.liveTagByKey(fromKey);
    if (!from) throw new Reject("unknown_tag");
    // A stale (offline) op must not act on a tag created after it: applied no-op (api.md §8.4).
    if (from.created_at > stamp.at) return;
    const other = fromKey === toKey ? null : this.liveTagByKey(toKey);
    let targetId = from.id;
    if (other) {
      // Merge `from` into `other`: per-pair LWW merge (keeps each pair's own stamp so stale ops converge).
      targetId = other.id;
      const pairs = this.all<{ item_id: string } & PairRow>("SELECT item_id, present, at, dev FROM item_tags WHERE tag_id = ?", from.id);
      for (const p of pairs) {
        const live = this.first<{ d: number | null }>("SELECT deleted_at AS d FROM items WHERE id = ?", p.item_id);
        const cur = this.first<PairRow>("SELECT present, at, dev FROM item_tags WHERE item_id = ? AND tag_id = ?", p.item_id, other.id);
        let changed = p.present === 1; // loses the `from` name
        if (!cur || pairWins({ at: p.at, dev: p.dev }, { at: cur.at, dev: cur.dev })) {
          this.writePair(p.item_id, other.id, p.present === 1, { at: p.at, dev: p.dev });
          if ((cur?.present === 1) !== (p.present === 1)) changed = true;
        }
        this.exec("UPDATE item_tags SET present = 0 WHERE item_id = ? AND tag_id = ?", p.item_id, from.id);
        if (changed && live && live.d === null) ctx.touchItem(p.item_id);
      }
      this.exec("UPDATE tags SET deleted_at = ?, tombstoned_at = ? WHERE id = ?", stamp.at, ctx.now, from.id);
      ctx.touchTag(from.id);
    } else if (from.name !== toName) {
      this.exec("UPDATE tags SET name = ?, name_key = ? WHERE id = ?", toName, toKey, from.id);
      ctx.touchTag(from.id);
      for (const id of this.liveCarriers(from.id)) ctx.touchItem(id);
    }
    this.exec(
      `INSERT INTO tag_renames (from_key, to_tag_id, at, recorded_at) VALUES (?, ?, ?, ?)
       ON CONFLICT(from_key) DO UPDATE SET to_tag_id = excluded.to_tag_id, at = excluded.at, recorded_at = excluded.recorded_at`,
      fromKey,
      targetId,
      stamp.at,
      ctx.now,
    );
  }

  private opTagDelete(ctx: OpCtx, op: OpOf<"tag.delete">, stamp: Stamp): void {
    const tag = this.liveTagByKey(tagKey(op.tag));
    if (!tag) throw new Reject("unknown_tag");
    // A stale (offline) delete must not destroy a tag created after it: applied no-op (api.md §8.4).
    if (tag.created_at > stamp.at) return;
    for (const id of this.liveCarriers(tag.id)) ctx.touchItem(id);
    // Only pairs the delete wins take its stamp; newer pair stamps are kept (LWW).
    this.exec(
      "UPDATE item_tags SET present = 0, at = ?1, dev = ?2 WHERE tag_id = ?3 AND present = 1 AND (at < ?1 OR (at = ?1 AND dev <= ?2))",
      stamp.at,
      stamp.dev,
      tag.id,
    );
    // Pairs stamped after the delete keep their own stamp (the tag is gone either way).
    this.exec("UPDATE item_tags SET present = 0 WHERE tag_id = ? AND present = 1", tag.id);
    this.exec("UPDATE tags SET deleted_at = ?, tombstoned_at = ? WHERE id = ?", stamp.at, ctx.now, tag.id);
    ctx.touchTag(tag.id);
  }

  // ---------- parse pipeline ----------

  /** api.md §9: bumps parse_gen, sets pending, returns the job (null if unknown/deleted). */
  requestParse(itemId: string, opts: { rawKey?: string; force?: boolean } = {}, now: number = Date.now()): ParseJob | null {
    const row = this.itemRow(this.resolveItemId(itemId));
    if (!row || row.deleted_at !== null) return null;
    return this.withCtx((ctx) => this.newParseJob(ctx, row, opts), now).value;
  }

  /**
   * Alarm sweep: re-sends parse jobs of live items stuck in `pending` since before `olderThan` (e.g. the
   * queue send after a committed push failed, or the job was deferred by the parse budget). Reuses the stored
   * raw HTML key and keeps parse_gen: a still-queued original job stays valid, and whichever copy finishes
   * first wins (markParsed accepts one result per gen; the parser skips jobs that are no longer pending).
   */
  requeueStalePending(olderThan: number, limit: number, now: number = Date.now()): ParseJob[] {
    const rows = this.all<ItemRow>(
      `SELECT * FROM items WHERE parse_status = 'pending' AND deleted_at IS NULL
         AND (parse_requested_at IS NULL OR parse_requested_at < ?) ORDER BY parse_requested_at LIMIT ?`,
      olderThan,
      limit,
    );
    if (rows.length === 0) return [];
    const uid = this.userId();
    return this.txn(() =>
      rows.map((row) => {
        this.exec("UPDATE items SET parse_requested_at = ? WHERE id = ?", now, row.id);
        const job: ParseJob = { userId: uid, itemId: row.id, url: row.url, parseGen: row.parse_gen };
        if (row.parse_raw_key) job.rawKey = row.parse_raw_key;
        return job;
      }),
    );
  }

  /** Marks jobs that were not sent (parse budget exhausted) so the next sweep picks them up first. */
  deferParse(itemIds: readonly string[]): void {
    if (itemIds.length === 0) return;
    this.exec(
      "UPDATE items SET parse_requested_at = 0 WHERE parse_status = 'pending' AND id IN (SELECT value FROM json_each(?))",
      JSON.stringify(itemIds),
    );
  }

  /** True while the item is live and still waiting for the result of parse generation `gen`. */
  parseWanted(itemId: string, gen: number): boolean {
    const row = this.first<{ g: number; s: string; d: number | null }>(
      "SELECT parse_gen AS g, parse_status AS s, deleted_at AS d FROM items WHERE id = ?",
      itemId,
    );
    return !!row && row.d === null && row.g === gen && row.s === "pending";
  }

  /**
   * Parser result. Accepted once per parse generation, only while the item is pending for it: a duplicate
   * delivery, or a DLQ `failed` after a committed success, is ignored (`ok:false`).
   */
  markParsed(itemId: string, result: ParseResult): { ok: boolean } {
    const row = this.itemRow(itemId);
    if (!row || row.deleted_at !== null || row.parse_gen !== result.parseGen || row.parse_status !== "pending") return { ok: false };
    this.withCtx((ctx) => {
      // The previous private content of this item is superseded (a new private dir, or now public content).
      if (row.content_private === 1 && row.content_id && row.content_id !== result.contentId) {
        ctx.cleanup.push(r2Keys.contentDir(row.content_id, this.userId()));
      }
      if (result.status === "failed") {
        this.exec("UPDATE items SET parse_status = 'failed', parse_error = ? WHERE id = ?", result.error ?? null, row.id);
      } else {
        this.exec(
          `UPDATE items SET content_id = ?, content_private = ?, lead_image_key = ?, title = COALESCE(?, title),
             excerpt = ?, site_name = ?, author = ?, lang = ?, word_count = ?, reading_minutes = ?,
             parse_status = ?, parse_error = ? WHERE id = ?`,
          result.contentId ?? null,
          result.contentPrivate ? 1 : 0,
          result.leadImageKey ?? null,
          result.title,
          result.excerpt,
          result.siteName,
          result.author,
          result.lang,
          result.wordCount,
          result.readingMinutes,
          result.status,
          result.error ?? null,
          row.id,
        );
      }
      ctx.touchItem(row.id);
    });
    return { ok: true };
  }

  // ---------- sync pull ----------

  pull(cursor: number, limit: number): PullPage {
    const horizon = this.getMeta("tombstone_horizon");
    if (cursor > 0 && cursor < horizon) return { error: "resync_required" };
    type K = { kind: string; id: string; seq: number };
    let rows = this.all<K>(
      `SELECT kind, id, seq FROM (
         SELECT 'i' AS kind, id, seq FROM items WHERE seq > ?1
         UNION ALL SELECT 't' AS kind, id, seq FROM tags WHERE seq > ?1)
       ORDER BY seq LIMIT ?2`,
      cursor,
      limit,
    );
    let hasMore = false;
    let next = this.getMeta("seq");
    if (rows.length === limit) {
      const lastSeq = rows[rows.length - 1]!.seq;
      const group = this.all<K>(
        `SELECT 'i' AS kind, id, seq FROM items WHERE seq = ?1 UNION ALL SELECT 't' AS kind, id, seq FROM tags WHERE seq = ?1`,
        lastSeq,
      );
      rows = rows.filter((r) => r.seq !== lastSeq).concat(group);
      hasMore =
        this.first<{ x: number }>(
          "SELECT 1 AS x WHERE EXISTS (SELECT 1 FROM items WHERE seq > ?1) OR EXISTS (SELECT 1 FROM tags WHERE seq > ?1)",
          lastSeq,
        ) !== null;
      if (hasMore) next = lastSeq;
    }
    const itemIds = rows.filter((r) => r.kind === "i").map((r) => r.id);
    const tagIds = rows.filter((r) => r.kind === "t").map((r) => r.id);
    const itemRows = itemIds.length
      ? this.all<ItemRow>("SELECT * FROM items WHERE id IN (SELECT value FROM json_each(?)) ORDER BY seq, id", JSON.stringify(itemIds))
      : [];
    const tagRows = tagIds.length
      ? this.all<TagRow>("SELECT * FROM tags WHERE id IN (SELECT value FROM json_each(?)) ORDER BY seq, id", JSON.stringify(tagIds))
      : [];
    const liveItems = itemRows.filter((r) => r.deleted_at === null);
    return {
      data: {
        cursor: next,
        hasMore,
        items: this.toItems(liveItems),
        tags: tagRows.filter((t) => t.deleted_at === null).map((t) => ({ id: t.id, name: t.name, seq: t.seq })),
        deleted: {
          items: itemRows.filter((r) => r.deleted_at !== null).map((r) => r.id),
          tags: tagRows.filter((t) => t.deleted_at !== null).map((t) => t.id),
        },
      },
    };
  }

  // ---------- list / search ----------

  list(q: ListItemsQuery, canonicalUrl?: string | null): ListResult {
    if (q.url !== undefined) {
      if (!canonicalUrl) return { items: [], nextCursor: null };
      const r = this.first<ItemRow>("SELECT * FROM items WHERE canonical_url = ? AND deleted_at IS NULL", canonicalUrl);
      return { items: r ? this.toItems([r]) : [], nextCursor: null };
    }
    const where: string[] = ["i.deleted_at IS NULL"];
    const binds: unknown[] = [];
    if (q.state === "unread") where.push("i.status = 'unread'");
    else if (q.state === "archived") where.push("i.status = 'archived'");
    else if (q.state === "favorites") where.push("i.is_favorite = 1");
    if (q.tag !== undefined) {
      where.push(
        `EXISTS (SELECT 1 FROM item_tags it JOIN tags t ON t.id = it.tag_id
          WHERE it.item_id = i.id AND it.present = 1 AND t.deleted_at IS NULL AND t.name_key = ?)`,
      );
      binds.push(tagKey(q.tag));
    }
    if (q.q !== undefined) {
      const match = buildMatchQuery(q.q);
      if (!match) return { items: [], nextCursor: null };
      where.push("i.fts_rowid IN (SELECT rowid FROM items_fts WHERE items_fts MATCH ?)");
      binds.push(match);
    }
    if (q.domain !== undefined) {
      const d = normalizeDomainFilter(q.domain);
      where.push("(i.domain = ? OR i.domain LIKE ? ESCAPE '\\')");
      binds.push(d, "%." + escapeLike(d));
    }

    const byWords = q.sort === "shortest" || q.sort === "longest";
    const asc = q.sort === "oldest" || q.sort === "shortest";
    const col = byWords ? "i.word_count" : "i.saved_at";
    const cmp = asc ? ">" : "<";
    if (q.cursor !== undefined) {
      const c = decodeListCursor(q.cursor);
      if (!c || (!byWords && c.k === null)) return { error: "bad_cursor" };
      if (c.k === null) {
        where.push(`(${col} IS NULL AND i.id ${cmp} ?)`);
        binds.push(c.id);
      } else if (byWords) {
        where.push(`(${col} ${cmp} ? OR (${col} = ? AND i.id ${cmp} ?) OR ${col} IS NULL)`);
        binds.push(c.k, c.k, c.id);
      } else {
        where.push(`(${col} ${cmp} ? OR (${col} = ? AND i.id ${cmp} ?))`);
        binds.push(c.k, c.k, c.id);
      }
    }
    const dir = asc ? "ASC" : "DESC";
    const order = byWords ? `${col} ${dir} NULLS LAST, i.id ${dir}` : `${col} ${dir}, i.id ${dir}`;
    const sql = `SELECT i.* FROM items i WHERE ${where.join(" AND ")} ORDER BY ${order} LIMIT ?`;
    let rows: ItemRow[];
    try {
      rows = this.all<ItemRow>(sql, ...binds, q.limit + 1);
    } catch (e) {
      // Odd FTS input must never 500 (api.md §5.2).
      if (q.q !== undefined) return { items: [], nextCursor: null };
      throw e;
    }
    const more = rows.length > q.limit;
    if (more) rows = rows.slice(0, q.limit);
    const last = rows[rows.length - 1];
    const nextCursor =
      more && last ? encodeListCursor({ k: byWords ? last.word_count : last.saved_at, id: last.id }) : null;
    return { items: this.toItems(rows), nextCursor };
  }

  // ---------- tags ----------

  listTags(): TagWithCount[] {
    const rows = this.all<{ id: string; name: string; seq: number; count: number }>(
      `SELECT t.id, t.name, t.seq,
         (SELECT COUNT(*) FROM item_tags it JOIN items i ON i.id = it.item_id
            WHERE it.tag_id = t.id AND it.present = 1 AND i.deleted_at IS NULL) AS count
       FROM tags t WHERE t.deleted_at IS NULL`,
    );
    return rows
      .map((r) => ({ id: r.id, name: r.name, count: Number(r.count), seq: r.seq }))
      .sort((a, b) => compareTagNames(a.name, b.name));
  }

  liveTag(id: string): TagRow | null {
    const t = this.tagRow(id);
    return t && t.deleted_at === null ? t : null;
  }

  tagWithCount(id: string): TagWithCount | null {
    return this.listTags().find((t) => t.id === id) ?? null;
  }

  liveTagIdByName(name: string): string | null {
    return this.liveTagByKey(tagKey(name))?.id ?? null;
  }

  suggestions(canonicalUrl: string | null): { recent: string[]; frequent: string[]; current: string[] } {
    const recent = this.all<{ name: string }>(
      `SELECT t.name, MAX(it.at) AS m FROM item_tags it
         JOIN tags t ON t.id = it.tag_id JOIN items i ON i.id = it.item_id
       WHERE it.present = 1 AND t.deleted_at IS NULL AND i.deleted_at IS NULL
       GROUP BY t.id ORDER BY m DESC, t.name_key ASC LIMIT 10`,
    ).map((r) => r.name);
    const recentSet = new Set(recent);
    const frequent = this.listTags()
      .filter((t) => t.count > 0 && !recentSet.has(t.name))
      .sort((a, b) => b.count - a.count || compareTagNames(a.name, b.name))
      .slice(0, 10)
      .map((t) => t.name);
    let current: string[] = [];
    if (canonicalUrl) {
      const r = this.first<ItemRow>("SELECT * FROM items WHERE canonical_url = ? AND deleted_at IS NULL", canonicalUrl);
      if (r) current = this.toItems([r])[0]!.tags;
    }
    return { recent, frequent, current };
  }

  // ---------- misc ----------

  stats(): { unread: number; archived: number; favorites: number; tags: number } {
    const r = this.first<{ unread: number; archived: number; favorites: number }>(
      `SELECT COALESCE(SUM(status = 'unread'), 0) AS unread, COALESCE(SUM(status = 'archived'), 0) AS archived,
              COALESCE(SUM(is_favorite = 1), 0) AS favorites FROM items WHERE deleted_at IS NULL`,
    )!;
    const t = this.first<{ n: number }>("SELECT COUNT(*) AS n FROM tags WHERE deleted_at IS NULL")!;
    return { unread: Number(r.unread), archived: Number(r.archived), favorites: Number(r.favorites), tags: Number(t.n) };
  }

  /** All live items (export). Ordered by savedAt ascending. */
  exportItems(): ItemData[] {
    return this.toItems(this.all<ItemRow>("SELECT * FROM items WHERE deleted_at IS NULL ORDER BY saved_at, id"));
  }

  /** One export page, newest first (saved_at DESC, id), unsigned. `after` is the last row of the previous page. */
  exportPage(after: { savedAt: number; id: string } | null, limit: number): ItemData[] {
    const rows = after
      ? this.all<ItemRow>(
          "SELECT * FROM items WHERE deleted_at IS NULL AND (saved_at < ? OR (saved_at = ? AND id > ?)) ORDER BY saved_at DESC, id LIMIT ?",
          after.savedAt, after.savedAt, after.id, limit,
        )
      : this.all<ItemRow>("SELECT * FROM items WHERE deleted_at IS NULL ORDER BY saved_at DESC, id LIMIT ?", limit);
    return this.toItems(rows);
  }

  /**
   * Alarm: purge old tombstones / tag_renames / applied_ops (api.md §7.3, §14). Uses the server-time columns
   * (tombstoned_at, recorded_at), never the client `at`, so a skewed/offline device can't trigger an early purge.
   */
  prune(now: number = Date.now()): void {
    const tombCut = now - LIMITS.tombstoneTtlMs;
    this.txn(() => {
      const maxItem = this.first<{ s: number | null }>("SELECT MAX(seq) AS s FROM items WHERE tombstoned_at < ?", tombCut)!.s;
      const maxTag = this.first<{ s: number | null }>("SELECT MAX(seq) AS s FROM tags WHERE tombstoned_at < ?", tombCut)!.s;
      const horizon = Math.max(this.getMeta("tombstone_horizon"), maxItem ?? 0, maxTag ?? 0);
      this.exec("DELETE FROM item_tags WHERE item_id IN (SELECT id FROM items WHERE tombstoned_at < ?)", tombCut);
      this.exec("DELETE FROM items WHERE tombstoned_at < ?", tombCut);
      this.exec("DELETE FROM item_tags WHERE tag_id IN (SELECT id FROM tags WHERE tombstoned_at < ?)", tombCut);
      this.exec("DELETE FROM tags WHERE tombstoned_at < ?", tombCut);
      // Aliases whose target is gone would hide a later re-save under the same client id.
      this.exec("DELETE FROM item_aliases WHERE target_id NOT IN (SELECT id FROM items)");
      this.exec("DELETE FROM tag_renames WHERE recorded_at < ?", tombCut);
      this.exec("DELETE FROM applied_ops WHERE applied_at < ?", now - LIMITS.appliedOpsTtlMs);
      this.setMeta("tombstone_horizon", horizon);
    });
  }
}
