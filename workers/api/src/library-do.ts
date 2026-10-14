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
 * Per-user library (SQLite DO, decisions D5). Addressed with `env.LIBRARY.getByName(userId)`.
 * All mutations go through `applyOps` (REST helpers translate to ops first). Logic: `do/store.ts`.
 */
export class LibraryDO extends DurableObject<Env> {
  private store: LibraryStore;
  private ready = false;
  private alarmChecked = false;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.store = new LibraryStore(ctx.storage, () => this.userId());
    void ctx.blockConcurrencyWhile(async () => {
      this.ensureSchema();
    });
  }

  private ensureSchema(): void {
    if (this.ready) return;
    migrate(this.ctx.storage);
    this.ready = true;
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
  requestParse(itemId: string, opts: { rawKey?: string; force?: boolean } = {}): ParseJob | null {
    this.ensureSchema();
    return this.store.requestParse(itemId, opts);
  }

  /** Parser result. `{ok:false}` for unknown/deleted items and stale parseGen. */
  markParsed(itemId: string, result: ParseResult): { ok: boolean } {
    this.ensureSchema();
    const p = ParseResultSchema.safeParse(result);
    if (!p.success) return { ok: false };
    return this.store.markParsed(itemId, p.data);
  }

  async pull(cursor: number, limit: number): Promise<PullResult> {
    this.ensureSchema();
    const page = this.store.pull(cursor, limit);
    if ("error" in page) return { ok: false, error: page.error };
    return { ok: true, data: { ...page.data, items: await this.sign(page.data.items) } };
  }

  /** Account wipe: deletes the whole library (SQL, FTS, alarm). */
  async destroy(): Promise<void> {
    await this.ctx.storage.deleteAlarm();
    await this.ctx.storage.deleteAll();
    this.ready = false;
    this.alarmChecked = false;
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
    this.ensureSchema();
    const job = this.store.requestParse(itemId, opts);
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

  /**
   * Called by a route whose queue send failed after the ops were committed: schedules an earlier alarm so the
   * stuck-pending sweep re-enqueues those items soon (the client's idempotent retry returns no jobs).
   */
  async scheduleParseSweep(): Promise<void> {
    this.ensureSchema();
    const at = Date.now() + SWEEP_DELAY_MS;
    const cur = await this.ctx.storage.getAlarm();
    if (cur === null || cur > at) await this.ctx.storage.setAlarm(at);
    this.alarmChecked = true;
  }

  /** Re-enqueues parse jobs of items stuck in `pending` (lost queue sends). Returns the number re-enqueued. */
  async sweepStalePending(now: number = Date.now()): Promise<number> {
    this.ensureSchema();
    let total = 0;
    for (;;) {
      const jobs = this.store.requeueStalePending(now - STALE_PENDING_MS, SWEEP_BATCH, now);
      if (jobs.length === 0) break;
      if (jobs.length === 1) await this.env.PARSE_QUEUE.send(jobs[0]!);
      else await this.env.PARSE_QUEUE.sendBatch(jobs.map((body) => ({ body })));
      total += jobs.length;
      if (jobs.length < SWEEP_BATCH) break;
    }
    return total;
  }

  override async alarm(): Promise<void> {
    this.ensureSchema();
    this.store.prune();
    // Reschedule before the sweep: a failing queue send makes the alarm retry, but the daily cadence stays.
    await this.ctx.storage.setAlarm(Date.now() + DAY_MS);
    await this.sweepStalePending();
  }
}
