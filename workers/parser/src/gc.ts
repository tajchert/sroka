import { log } from "@sroka/shared";
import type { ParserEnv } from "./env.ts";

/** Delete all R2 objects under a prefix (paged). */
export async function deletePrefix(bucket: R2Bucket, prefix: string): Promise<void> {
  let cursor: string | undefined;
  do {
    const page = await bucket.list({ prefix, cursor, limit: 1000 });
    if (page.objects.length) await bucket.delete(page.objects.map((o) => o.key));
    cursor = page.truncated ? page.cursor : undefined;
  } while (cursor);
}

/** Per-user R2 roots (r2Keys.privatePrefix / rawPrefix / uploadsPrefix). */
export const USER_ROOTS = ["private/", "raw/", "uploads/"] as const;

/**
 * Weekly GC (cron): deletes `private/{userId}/`, `raw/{userId}/` and `uploads/{userId}/` of user ids that no
 * longer exist in D1. Backstop for the account-deletion R2 wipe (runs once in waitUntil) and for writes that
 * were in flight while the account was deleted (parser results, captured HTML, uploads).
 * Shared public content (`content/`) is NOT collected here (ref counting is not reliable yet).
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
