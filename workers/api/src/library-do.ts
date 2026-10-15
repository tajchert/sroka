import { log } from "@sroka/shared";
import { DurableObject } from "cloudflare:workers";
import {
  type Item,
  type ListItemsQuery,
  type Op,
  type ParseJob,
  type ParseResult,
  type PullResponse,
  type UpdateItemRequest,
  Op as OpSchema,
  ParseResultSchema,
  normalizeUrl,
  uuidv7,
  urlHash,
} from "@sroka/shared";
import type { Env } from "./env.ts";
import { patchToOps } from "./do/rest.ts";
import { migrate } from "./do/schema.ts";
import { deletePrefix } from "./r2.ts";
import { withLeadImageUrls } from "./do/sign.ts";
import { type AddInfo, type ApplyResult, LibraryStore, type TagWithCount } from "./do/store.ts";

export type { ApplyResult, TagWithCount } from "./do/store.ts";

export type PullResult = { ok: true; data: PullResponse } | { ok: false; error: "resync_required" };
export type ListItemsResult = { ok: true; items: Item[]; nextCursor: string | null } | { ok: false; error: "bad_cursor" };
export interface RestResult extends ApplyResult {
  /** The (alias-resolved) item after applying, or null if unknown/deleted. */
  item: Item | null;
}

const DAY_MS = 24 * 60 * 60 * 1000;
/** Items `pending` longer than this are re-enqueued by the alarm sweep. */
const STALE_PENDING_MS = 30 * 60 * 1000;
/** Delay of the extra alarm scheduled when a route failed to enqueue parse jobs. */
const SWEEP_DELAY_MS = STALE_PENDING_MS + 60 * 1000;
const SWEEP_BATCH = 100;
/**
 * Per-user parse budget (token bucket): at most PARSE_BURST jobs at once, refilled at PARSE_BURST per hour.
 * Jobs over budget stay `pending` and are sent by the sweep later (DEFERRED_SWEEP_MS cadence).
 */
export const PARSE_BURST = 1000;
const PARSE_REFILL_PER_MS = PARSE_BURST / (60 * 60 * 1000);
const DEFERRED_SWEEP_MS = 10 * 60 * 1000;
/** Marker table created by destroy(): the library of a deleted account must never be recreated. */
const DESTROYED_TABLE = "_destroyed";
/** Content-ref outbox entries per D1 batch, and the alarm delay after a failed flush. */
const REF_BATCH = 50;
const REF_RETRY_MS = 10 * 60 * 1000;

export class LibraryDestroyedError extends Error {
  constructor() {
    super("library_destroyed");
  }
}

/**
 * Per-user library (SQLite DO, decisions D5). Addressed with `env.LIBRARY.getByName(userId)`.
 * All mutations go through `applyOps` (REST helpers translate to ops first). Logic: `do/store.ts`.
 */
export class LibraryDO extends DurableObject<Env> {
  private store: LibraryStore;
  private ready = false;
  private alarmChecked = false;
  private destroyed: boolean | null = null;
  /** Serializes content-ref flushes (flushContentRefs). */
  private refChain: Promise<unknown> = Promise.resolve();

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.store = new LibraryStore(ctx.storage, () => this.userId());
    void ctx.blockConcurrencyWhile(async () => {
      if (!this.isDestroyed()) this.ensureSchema();
    });
  }

  private isDestroyed(): boolean {
    if (this.destroyed === null) {
      this.destroyed =
        this.ctx.storage.sql.exec("SELECT 1 AS x FROM sqlite_master WHERE type = 'table' AND name = ?", DESTROYED_TABLE).toArray().length > 0;
    }
    return this.destroyed;
  }

  /** Migrates on first use. Throws LibraryDestroyedError for a wiped (deleted-account) library. */
  private ensureSchema(): void {
    if (this.ready) return;
    if (this.isDestroyed()) throw new LibraryDestroyedError();
    migrate(this.ctx.storage);
    this.ready = true;
  }

  /** Deletes R2 objects freed by committed ops (raw captures, private content). Best effort. */
  private async flushCleanup(): Promise<void> {
    const keys = this.store.takeCleanup();
    if (keys.length === 0) return;
    const exact = keys.filter((k) => !k.endsWith("/"));
    const prefixes = keys.filter((k) => k.endsWith("/"));
    try {
      await Promise.all([
        exact.length ? this.env.CONTENT.delete(exact) : Promise.resolve(),
        ...prefixes.map((p) => deletePrefix(this.env.CONTENT, p)),
      ]);
    } catch (e) {
      log.exception("LibraryDO R2 cleanup failed", e, { event: "do_r2_cleanup_failed", keyCount: keys.length });
    }
  }

  /**
   * Flushes the content-ref outbox to D1 `content_refs` (api.md §9 "Content references"). Serialized per
   * instance: the desired state is computed right before each D1 batch, and an entry re-marked while its
   * batch was in flight keeps its row (gen mismatch) and is flushed again — so concurrent flushes can never
   * write an older state over a newer one. On failure the alarm retries (REF_RETRY_MS). Returns the number of
   * entries still pending.
   */
  private flushContentRefs(): Promise<number> {
    const run = this.refChain.then(() => this.flushRefsNow());
    this.refChain = run.catch(() => undefined);
    return run;
  }

  private async flushRefsNow(): Promise<number> {
    if (this.isDestroyed()) return 0;
    const db = this.env.DB;
    const userId = this.userId();
    for (;;) {
      const batch = this.store.refBatch(REF_BATCH);
      if (batch.length === 0) return 0;
      const now = Date.now();
      const stmts: D1PreparedStatement[] = [];
      for (const r of batch) {
        stmts.push(
          r.live
            ? db.prepare("INSERT INTO content_refs (content_id, user_id, at) VALUES (?1, ?2, ?3) ON CONFLICT DO NOTHING").bind(r.contentId, userId, now)
            : db.prepare("DELETE FROM content_refs WHERE content_id = ?1 AND user_id = ?2").bind(r.contentId, userId),
          // Attach/detach restarts the GC grace period; ref_count is only a cache of COUNT(content_refs).
          db
            .prepare(
              "UPDATE content SET last_used_at = MAX(last_used_at, ?2), ref_count = (SELECT COUNT(*) FROM content_refs WHERE content_id = ?1) WHERE id = ?1",
            )
            .bind(r.contentId, now),
        );
      }
      try {
        await db.batch(stmts);
      } catch (e) {
        console.error("LibraryDO: content_refs flush failed", e);
        await this.scheduleSweepIn(REF_RETRY_MS).catch(() => undefined);
        return this.store.pendingRefCount();
      }
      this.store.clearRefs(batch);
    }
  }

  /** Flushes the outbox if it has entries (cheap check on the hot paths). */
  private async flushRefsIfPending(): Promise<void> {
    if (this.store.pendingRefCount() > 0) await this.flushContentRefs();
  }

  /** Takes up to `n` tokens of the parse budget; returns how many were granted. */
  private takeParseTokens(n: number, now = Date.now()): number {
    if (n <= 0) return 0;
    const last = this.store.getMeta("parse_budget_at");
    const stored = last === 0 ? PARSE_BURST : this.store.getMeta("parse_budget");
    const tokens = Math.min(PARSE_BURST, stored + Math.max(0, now - last) * PARSE_REFILL_PER_MS);
    const granted = Math.min(n, Math.floor(tokens));
    this.store.setMetaNumber("parse_budget", tokens - granted);
    this.store.setMetaNumber("parse_budget_at", now);
    return granted;
  }

  /** Applies the parse budget: returns the jobs to send now; the rest are deferred to the sweep. */
  private async budgetJobs(jobs: ParseJob[]): Promise<ParseJob[]> {
    if (jobs.length === 0) return jobs;
    const granted = this.takeParseTokens(jobs.length);
    if (granted === jobs.length) return jobs;
    this.store.deferParse(jobs.slice(granted).map((j) => j.itemId));
    await this.scheduleSweepIn(DEFERRED_SWEEP_MS);
    return jobs.slice(0, granted);
  }

  private async scheduleSweepIn(ms: number): Promise<void> {
    const at = Date.now() + ms;
    const cur = await this.ctx.storage.getAlarm();
    if (cur === null || cur > at) await this.ctx.storage.setAlarm(at);
    this.alarmChecked = true;
  }

  private userId(): string {
    const name = this.ctx.id.name;
    if (name) {
      if (this.store.getMetaText("user_id") !== name) this.store.setMetaText("user_id", name);
      return name;
    }
    const stored = this.store.getMetaText("user_id");
    if (!stored) throw new Error("LibraryDO: unknown user id (use getByName(userId))");
    return stored;
  }

  private async ensureAlarm(): Promise<void> {
    if (this.alarmChecked) return;
    this.alarmChecked = true;
    if ((await this.ctx.storage.getAlarm()) === null) await this.ctx.storage.setAlarm(Date.now() + DAY_MS);
  }

  private sign(items: Parameters<typeof withLeadImageUrls>[2]): Promise<Item[]> {
    return withLeadImageUrls(this.env, this.userId(), items);
  }

  private async signOne(item: ReturnType<LibraryStore["getItem"]>): Promise<Item | null> {
    return item ? (await this.sign([item]))[0]! : null;
  }

  /** Validates ops (invalid → rejected invalid_op) and precomputes canonical URLs/hashes, then applies. */
  private async apply(deviceId: string, raw: readonly unknown[], atomic = false): Promise<ApplyResult> {
    this.ensureSchema();
    const ops: Op[] = [];
    const invalid: { opId: string; reason: "invalid_op" }[] = [];
    for (const r of raw) {
      const p = OpSchema.safeParse(r);
      if (p.success) ops.push(p.data);
      else {
        const opId = r && typeof r === "object" && "opId" in r && typeof r.opId === "string" ? r.opId : "";
        invalid.push({ opId, reason: "invalid_op" });
      }
    }
    const info: AddInfo[] = [];
    for (const op of ops) {
      if (op.type !== "item.add") {
        info.push(null);
        continue;
      }
      let canonical: string;
      try {
        canonical = normalizeUrl(op.url);
      } catch {
        info.push(null);
        continue;
      }
      info.push({ canonical, hash: await urlHash(canonical) });
    }
    // Everything below is synchronous (no interleaving with other requests).
    const res = atomic ? this.store.applyOpsAtomic(deviceId, ops, info) : this.store.applyOps(deviceId, ops, info);
    res.response.rejected.unshift(...invalid);
    if (ops.length > 0) await this.ensureAlarm();
    res.parseJobs = await this.budgetJobs(res.parseJobs);
    await this.flushCleanup();
    await this.flushRefsIfPending();
    return res;
  }

  // ---------- public RPC surface (api.md §15) ----------

  /** Liveness probe (used by the parser test harness). */
  ping(): string {
    return "pong";
  }

  /** Sync push / single mutation path. Returns the PushResponse and parse jobs for the caller to enqueue. */
  async applyOps(deviceId: string, ops: readonly unknown[]): Promise<ApplyResult> {
    return this.apply(deviceId, ops);
  }

  /** Bumps parse_gen and returns the job to enqueue (html save path), or null if the item is unknown/deleted. */
  async requestParse(itemId: string, opts: { rawKey?: string; force?: boolean } = {}): Promise<ParseJob | null> {
    this.ensureSchema();
    const job = this.store.requestParse(itemId, opts);
    await this.flushCleanup();
    return job ? ((await this.budgetJobs([job]))[0] ?? null) : null;
  }

  /**
   * Parser result. `{ok:false}` for unknown/deleted items, stale parseGen, a result already applied for this
   * gen, or a destroyed library (the parser then deletes private content it wrote).
   */
  async markParsed(itemId: string, result: ParseResult): Promise<{ ok: boolean }> {
    if (this.isDestroyed()) return { ok: false };
    this.ensureSchema();
    const p = ParseResultSchema.safeParse(result);
    if (!p.success) return { ok: false };
    const r = this.store.markParsed(itemId, p.data);
    await this.flushCleanup();
    await this.flushRefsIfPending();
    return r;
  }

  /**
   * One-time backfill (parser GC, api.md §9): re-emits every public content reference of this library to D1
   * `content_refs` and flushes. `pending` > 0 means the flush failed (retry later). A destroyed library has none.
   */
  async reemitContentRefs(): Promise<{ refs: number; pending: number }> {
    if (this.isDestroyed()) return { refs: 0, pending: 0 };
    this.ensureSchema();
    const refs = this.store.markAllRefsDirty();
    const pending = await this.flushContentRefs();
    return { refs, pending };
  }

  /** Parser pre-check: false when the job is superseded / already done / the item or library is gone. */
  parseWanted(itemId: string, parseGen: number): boolean {
    if (this.isDestroyed()) return false;
    this.ensureSchema();
    return this.store.parseWanted(itemId, parseGen);
  }

  async pull(cursor: number, limit: number, full = false): Promise<PullResult> {
    this.ensureSchema();
    const page = this.store.pull(cursor, limit, full);
    if ("error" in page) return { ok: false, error: page.error };
    return { ok: true, data: { ...page.data, items: await this.sign(page.data.items) } };
  }

  /** Account wipe: deletes the whole library (SQL, FTS, alarm). */
  async destroy(): Promise<void> {
    await this.ctx.storage.deleteAlarm();
    await this.ctx.storage.deleteAll();
    // Tombstone: later RPCs (in-flight pushes, import steps, parser results, a retried alarm) must not
    // migrate a fresh schema and recreate the deleted user's library.
    this.ctx.storage.sql.exec(`CREATE TABLE IF NOT EXISTS ${DESTROYED_TABLE} (at INTEGER)`);
    this.ctx.storage.sql.exec(`INSERT INTO ${DESTROYED_TABLE} (at) VALUES (?)`, Date.now());
    this.destroyed = true;
    this.ready = false;
    this.alarmChecked = true;
    // Detach all shared content of this user. Best effort: the parser GC also ignores (and purges) refs of
    // user ids no longer in D1, which covers a failure here and a flush that was in flight during the wipe.
    try {
      await this.env.DB.prepare("DELETE FROM content_refs WHERE user_id = ?1").bind(this.ctx.id.name ?? "").run();
    } catch (e) {
      console.warn("LibraryDO: content_refs cleanup on destroy failed", e);
    }
  }

  // ---------- internal helpers for workers/api routes ----------

  /**
   * Applies REST-synthesized ops and returns the resulting item. With `requireLive`, returns
   * `{item:null}` without applying anything when the item is unknown or deleted (→ 404).
   */
  async applyRest(deviceId: string, ops: Op[], opts: { itemId: string; requireLive?: boolean }): Promise<RestResult> {
    this.ensureSchema();
    if (opts.requireLive && !this.store.getItem(opts.itemId)) {
      return { response: { applied: [], rejected: [], aliases: {}, cursor: this.store.getMeta("seq") }, parseJobs: [], item: null };
    }
    const res = await this.apply(deviceId, ops);
    const id = res.response.aliases[opts.itemId] ?? opts.itemId;
    return { ...res, item: await this.signOne(this.store.getItem(id)) };
  }

  /** PATCH /v1/items/:id — diffed into ops inside the DO (atomic w.r.t. the current tag set). */
  async patchItem(deviceId: string, itemId: string, patch: UpdateItemRequest, at: number): Promise<RestResult> {
    this.ensureSchema();
    const current = this.store.getItem(itemId);
    if (!current) return { response: { applied: [], rejected: [], aliases: {}, cursor: this.store.getMeta("seq") }, parseJobs: [], item: null };
    // All-or-nothing: a PATCH is one request, it must not be half-applied and reported as failed.
    const res = await this.apply(deviceId, patchToOps(patch, current, at), true);
    return { ...res, item: await this.signOne(this.store.getItem(current.id)) };
  }

  async requestParseAndGet(itemId: string, opts: { rawKey?: string; force?: boolean }): Promise<{ job: ParseJob | null; item: Item | null }> {
    const job = await this.requestParse(itemId, opts);
    return { job, item: await this.signOne(this.store.getItem(itemId)) };
  }

  async getItem(itemId: string): Promise<Item | null> {
    this.ensureSchema();
    return this.signOne(this.store.getItem(itemId));
  }

  /** GET /v1/items. `canonicalUrl` = normalizeUrl(q.url) computed by the route (null if q.url didn't normalize). */
  async listItems(q: ListItemsQuery, canonicalUrl: string | null = null): Promise<ListItemsResult> {
    this.ensureSchema();
    const r = this.store.list(q, canonicalUrl);
    if ("error" in r) return { ok: false, error: r.error };
    return { ok: true, items: await this.sign(r.items), nextCursor: r.nextCursor };
  }

  listTags(): TagWithCount[] {
    this.ensureSchema();
    return this.store.listTags();
  }

  suggestions(canonicalUrl: string | null): { recent: string[]; frequent: string[]; current: string[] } {
    this.ensureSchema();
    return this.store.suggestions(canonicalUrl);
  }

  /** PATCH /v1/tags/:id → tag.rename; returns the surviving tag (merge target if merged) or null (404). */
  async renameTag(deviceId: string, tagId: string, name: string, at: number): Promise<TagWithCount | null> {
    this.ensureSchema();
    const tag = this.store.liveTag(tagId);
    if (!tag) return null;
    await this.apply(deviceId, [{ opId: uuidv7(), at, type: "tag.rename", from: tag.name, to: name }]);
    const survivor = this.store.liveTagIdByName(name) ?? tagId;
    return this.store.tagWithCount(survivor);
  }

  /** DELETE /v1/tags/:id → tag.delete; false if unknown/deleted (404). */
  async deleteTag(deviceId: string, tagId: string, at: number): Promise<boolean> {
    this.ensureSchema();
    const tag = this.store.liveTag(tagId);
    if (!tag) return false;
    await this.apply(deviceId, [{ opId: uuidv7(), at, type: "tag.delete", tag: tag.name }]);
    return true;
  }

  /** GET /v1/me stats. */
  stats(): { unread: number; archived: number; favorites: number; tags: number } {
    this.ensureSchema();
    return this.store.stats();
  }

  /** All live items (export), savedAt ascending. */
  async exportItems(): Promise<Item[]> {
    this.ensureSchema();
    return this.sign(this.store.exportItems());
  }

  /** Export page, newest first, unsigned (no image URLs). Pass the last item of the previous page as `after`. */
  exportPage(after: { savedAt: number; id: string } | null, limit: number): Omit<Item, "leadImageUrl">[] {
    this.ensureSchema();
    return this.store.exportPage(after, Math.min(Math.max(1, limit), 1000));
  }

  /**
   * Called by a route whose queue send failed after the ops were committed: schedules an earlier alarm so the
   * stuck-pending sweep re-enqueues those items soon (the client's idempotent retry returns no jobs).
   */
  async scheduleParseSweep(): Promise<void> {
    this.ensureSchema();
    await this.scheduleSweepIn(SWEEP_DELAY_MS);
  }

  /**
   * Re-sends parse jobs of items stuck in `pending` (lost queue sends, budget-deferred jobs), within the parse
   * budget. Returns the number re-sent; schedules another sweep when the budget ran out first.
   */
  async sweepStalePending(now: number = Date.now()): Promise<number> {
    this.ensureSchema();
    let total = 0;
    for (;;) {
      const budget = this.takeParseTokens(SWEEP_BATCH, now);
      const jobs = budget > 0 ? this.store.requeueStalePending(now - STALE_PENDING_MS, budget, now) : [];
      // Return unused tokens.
      if (budget > jobs.length) this.store.setMetaNumber("parse_budget", this.store.getMeta("parse_budget") + budget - jobs.length);
      if (budget === 0) {
        await this.scheduleSweepIn(DEFERRED_SWEEP_MS);
        break;
      }
      if (jobs.length === 0) break;
      if (jobs.length === 1) await this.env.PARSE_QUEUE.send(jobs[0]!);
      else await this.env.PARSE_QUEUE.sendBatch(jobs.map((body) => ({ body })));
      total += jobs.length;
      if (jobs.length < budget) break;
    }
    return total;
  }

  override async alarm(): Promise<void> {
    if (this.isDestroyed()) {
      await this.ctx.storage.deleteAlarm();
      return;
    }
    this.ensureSchema();
    this.store.prune();
    // Reschedule before the sweep: a failing queue send makes the alarm retry, but the daily cadence stays.
    await this.ctx.storage.setAlarm(Date.now() + DAY_MS);
    await this.flushRefsIfPending(); // retries failed content-ref flushes (errors are swallowed)
    const t0 = Date.now();
    const resent = await this.sweepStalePending();
    log.info("LibraryDO alarm sweep", { event: "do_alarm_sweep", resent, durationMs: Date.now() - t0 });
  }
}
