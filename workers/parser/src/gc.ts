import { log, r2Keys } from "@sroka/shared";
import type { ParserEnv } from "./env.ts";

/** Delete all R2 objects under a prefix (paged). Returns the number of objects deleted. */
export async function deletePrefix(bucket: R2Bucket, prefix: string): Promise<number> {
  let cursor: string | undefined;
  let n = 0;
  do {
    const page = await bucket.list({ prefix, cursor, limit: 1000 });
    if (page.objects.length) await bucket.delete(page.objects.map((o) => o.key));
    n += page.objects.length;
    cursor = page.truncated ? page.cursor : undefined;
  } while (cursor);
  return n;
}

/** Per-user R2 roots (r2Keys.privatePrefix / rawPrefix / uploadsPrefix). */
export const USER_ROOTS = ["private/", "raw/", "uploads/"] as const;

/**
 * Weekly GC (cron): deletes `private/{userId}/`, `raw/{userId}/` and `uploads/{userId}/` of user ids that no
 * longer exist in D1. Backstop for the account-deletion R2 wipe (runs once in waitUntil) and for writes that
 * were in flight while the account was deleted (parser results, captured HTML, uploads).
 * Shared public content (`content/`) is collected by sweepSharedContent.
 */
export async function sweepOrphanedUserData(env: Pick<ParserEnv, "DB" | "CONTENT">, now = Date.now()): Promise<{ deleted: string[] }> {
  const deleted: string[] = [];
  for (const root of USER_ROOTS) {
    let cursor: string | undefined;
    do {
      const page = await env.CONTENT.list({ prefix: root, delimiter: "/", cursor, limit: 1000 });
      const ids = page.delimitedPrefixes.map((p) => p.slice(root.length, -1)).filter(Boolean);
      if (ids.length) {
        const rows = await env.DB.prepare("SELECT id FROM user WHERE id IN (SELECT value FROM json_each(?1))")
          .bind(JSON.stringify(ids))
          .all<{ id: string }>();
        const live = new Set((rows.results ?? []).map((r) => r.id));
        for (const id of ids) {
          if (live.has(id)) continue;
          await deletePrefix(env.CONTENT, `${root}${id}/`);
          deleted.push(`${root}${id}/`);
        }
      }
      cursor = page.truncated ? page.cursor : undefined;
    } while (cursor);
  }
  try {
    await env.DB.prepare("DELETE FROM auth_throttle WHERE expires_at < ?1").bind(now).run();
  } catch (e) {
    log.warnException("auth_throttle cleanup failed", e, { event: "gc_throttle_cleanup_failed" });
  }
  return { deleted };
}

// ---------- shared public content (api.md §9 "Content references / GC") ----------

/** Unreferenced content is kept this long after its last use (insert, cache hit, attach, detach). */
export const CONTENT_GC_GRACE_MS = 30 * 24 * 60 * 60 * 1000;
/** Per cron run: content rows marked for deletion, R2 objects deleted (soft cap), users backfilled. */
export const GC_MAX_ROWS = 200;
export const GC_MAX_OBJECTS = 20_000;
export const BACKFILL_MAX_USERS = 1000;

/** `gc_state` keys. An operator sets `gc_backfill = 'start'`; the cron sets the other two. */
export const GC_KEYS = { start: "gc_backfill", cursor: "gc_backfill_cursor", done: "gc_backfill_done" } as const;

async function getState(db: D1Database, k: string): Promise<string | null> {
  return (await db.prepare("SELECT v FROM gc_state WHERE k = ?1").bind(k).first<{ v: string }>())?.v ?? null;
}
async function setState(db: D1Database, k: string, v: string): Promise<void> {
  await db.prepare("INSERT INTO gc_state (k, v) VALUES (?1, ?2) ON CONFLICT(k) DO UPDATE SET v = excluded.v").bind(k, v).run();
}

export interface BackfillResult {
  state: "not_started" | "in_progress" | "done";
  users: number;
  refs: number;
  /** User id whose library could not flush its refs (backfill stops there and resumes next run). */
  blockedAt?: string;
}

/**
 * One-time backfill of `content_refs` for items parsed before LibraryDOs reported references: once an operator
 * set `gc_state.gc_backfill = 'start'` (after deploying sroka-api with the ref outbox), asks every user's
 * LibraryDO (D1 `user` table, id order, resumable cursor) to re-emit its public refs. Sets `gc_backfill_done`
 * when every user succeeded. Precondition (documented in workers/parser/CLAUDE.md): the API is deployed first,
 * so every change after a library's re-emit is reported through its outbox.
 */
export async function backfillContentRefs(env: Pick<ParserEnv, "DB" | "LIBRARY">, maxUsers = BACKFILL_MAX_USERS): Promise<BackfillResult> {
  if ((await getState(env.DB, GC_KEYS.done)) === "1") return { state: "done", users: 0, refs: 0 };
  if ((await getState(env.DB, GC_KEYS.start)) !== "start") return { state: "not_started", users: 0, refs: 0 };
  const cursor = (await getState(env.DB, GC_KEYS.cursor)) ?? "";
  const rows = await env.DB.prepare("SELECT id FROM user WHERE id > ?1 ORDER BY id LIMIT ?2").bind(cursor, maxUsers).all<{ id: string }>();
  const ids = (rows.results ?? []).map((r) => r.id);
  let users = 0;
  let refs = 0;
  for (const id of ids) {
    let r: { refs: number; pending: number };
    try {
      r = await env.LIBRARY.getByName(id).reemitContentRefs();
    } catch (e) {
      log.exception("gc backfill: reemitContentRefs failed", e, { event: "gc_backfill_failed", userHash: id.slice(0, 8) });
      return { state: "in_progress", users, refs, blockedAt: id };
    }
    if (r.pending > 0) return { state: "in_progress", users, refs, blockedAt: id };
    users++;
    refs += r.refs;
    await setState(env.DB, GC_KEYS.cursor, id);
  }
  if (ids.length < maxUsers) {
    await setState(env.DB, GC_KEYS.done, "1");
    return { state: "done", users, refs };
  }
  return { state: "in_progress", users, refs };
}

export interface ContentGcResult {
  skipped?: "backfill_pending";
  deadRefs: number;
  rows: number;
  objects: number;
  /** Marked rows that turned out to be referenced again (unmarked, kept). */
  rescued: number;
}

/**
 * Deletes public content (`content/{id}/` in R2 + its D1 row) that no library references (`content_refs`)
 * and that was not used for CONTENT_GC_GRACE_MS. A no-op until the backfill is done. Steps:
 * 1. refs of user ids no longer in D1 are dropped (account deletion backstop);
 * 2. candidates are marked `gc_at` in ONE statement that re-checks "no refs + grace expired" — a cache hit
 *    touches `last_used_at` atomically with its lookup, and the cache skips marked rows, so a mark can't race a
 *    cache hit; rows marked by an earlier, interrupted run are resumed;
 * 3. right before deleting R2, each marked row is checked for refs once more (a late DO flush) and unmarked if
 *    referenced; then the R2 prefix is deleted (paged), then the row.
 * Bounded by GC_MAX_ROWS / GC_MAX_OBJECTS per run.
 */
export async function sweepSharedContent(
  env: Pick<ParserEnv, "DB" | "CONTENT">,
  now = Date.now(),
  limits: { rows?: number; objects?: number } = {},
): Promise<ContentGcResult> {
  const out: ContentGcResult = { deadRefs: 0, rows: 0, objects: 0, rescued: 0 };
  if ((await getState(env.DB, GC_KEYS.done)) !== "1") return { ...out, skipped: "backfill_pending" };
  const maxRows = limits.rows ?? GC_MAX_ROWS;
  const maxObjects = limits.objects ?? GC_MAX_OBJECTS;

  const dead = await env.DB.prepare("DELETE FROM content_refs WHERE user_id NOT IN (SELECT id FROM user)").run();
  out.deadRefs = dead.meta.changes ?? 0;

  const resumed = await env.DB.prepare("SELECT id FROM content WHERE gc_at IS NOT NULL ORDER BY gc_at LIMIT ?1").bind(maxRows).all<{ id: string }>();
  const ids = (resumed.results ?? []).map((r) => r.id);
  if (ids.length < maxRows) {
    const marked = await env.DB.prepare(
      `UPDATE content SET gc_at = ?1 WHERE id IN (
         SELECT c.id FROM content c WHERE c.gc_at IS NULL AND c.last_used_at < ?2
           AND NOT EXISTS (SELECT 1 FROM content_refs r WHERE r.content_id = c.id)
         ORDER BY c.last_used_at LIMIT ?3)
       AND gc_at IS NULL AND last_used_at < ?2 AND NOT EXISTS (SELECT 1 FROM content_refs r WHERE r.content_id = content.id)
       RETURNING id`,
    )
      .bind(now, now - CONTENT_GC_GRACE_MS, maxRows - ids.length)
      .all<{ id: string }>();
    ids.push(...(marked.results ?? []).map((r) => r.id));
  }

  for (const id of ids) {
    if (out.objects >= maxObjects) break;
    const ref = await env.DB.prepare("SELECT 1 AS x FROM content_refs WHERE content_id = ?1 LIMIT 1").bind(id).first();
    if (ref) {
      log.warn("content gc: referenced again, keeping it", { event: "gc_content_kept", contentId: id });
      await env.DB.prepare("UPDATE content SET gc_at = NULL, last_used_at = MAX(last_used_at, ?2) WHERE id = ?1").bind(id, now).run();
      out.rescued++;
      continue;
    }
    out.objects += await deletePrefix(env.CONTENT, r2Keys.contentDir(id));
    await env.DB.prepare("DELETE FROM content WHERE id = ?1 AND gc_at IS NOT NULL").bind(id).run();
    out.rows++;
  }
  return out;
}

/** The weekly cron: each step isolated so one failure doesn't block the others; logs one summary line. */
export async function runWeeklyGc(env: ParserEnv, now = Date.now()): Promise<void> {
  const summary: Record<string, unknown> = {};
  const step = async (name: string, fn: () => Promise<unknown>) => {
    try {
      summary[name] = await fn();
    } catch (e) {
      log.exception("gc step failed", e, { event: "gc_step_failed", step: name });
      summary[name] = { error: String(e) };
    }
  };
  await step("userData", async () => (await sweepOrphanedUserData(env, now)).deleted.length);
  await step("backfill", () => backfillContentRefs(env));
  await step("sharedContent", () => sweepSharedContent(env, now));
  log.info("gc sweep finished", { event: "gc_sweep", ...summary });
}
