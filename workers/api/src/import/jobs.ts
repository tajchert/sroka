import type { Job } from "@sroka/shared";

interface JobRow {
  id: string;
  kind: string;
  status: string;
  format: string | null;
  total: number | null;
  done: number | null;
  skipped: number | null;
  error: string | null;
  created_at: number;
  updated_at: number;
}

export function rowToJob(r: JobRow): Job {
  return {
    id: r.id,
    kind: r.kind as Job["kind"],
    status: r.status as Job["status"],
    format: r.format,
    total: r.total,
    done: r.done ?? 0,
    skipped: r.skipped ?? 0,
    error: r.error,
    createdAt: r.created_at,
    updatedAt: r.updated_at,
  };
}

export async function getJob(db: D1Database, userId: string, id: string): Promise<Job | null> {
  const r = await db.prepare("SELECT * FROM jobs WHERE id = ? AND user_id = ?").bind(id, userId).first<JobRow>();
  return r ? rowToJob(r) : null;
}

/**
 * Atomically reserves an import slot: inserts the job row only while the user has fewer than `limit` imports
 * since `since` (one statement, so concurrent requests can't all pass a separate count check).
 * Returns false when the limit is reached.
 */
export async function reserveImportJob(
  db: D1Database,
  j: { id: string; userId: string; format: string; now: number; since: number; limit: number },
): Promise<boolean> {
  const r = await db
    .prepare(
      `INSERT INTO jobs (id, user_id, kind, status, format, total, done, skipped, error, created_at, updated_at)
       SELECT ?1, ?2, 'import', 'queued', ?3, NULL, 0, 0, NULL, ?4, ?4
       WHERE (SELECT COUNT(*) FROM jobs WHERE user_id = ?2 AND kind = 'import' AND created_at >= ?5
              AND COALESCE(error, '') != 'workflow_unavailable') < ?6`,
    )
    .bind(j.id, j.userId, j.format, j.now, j.since, j.limit)
    .run();
  return (r.meta.changes ?? 0) > 0;
}

export interface JobPatch {
  status?: Job["status"];
  total?: number;
  done?: number;
  skipped?: number;
  error?: string | null;
}

/** Absolute (idempotent) progress update. */
export async function updateJob(db: D1Database, id: string, p: JobPatch): Promise<void> {
  const sets: string[] = ["updated_at = ?"];
  const args: unknown[] = [Date.now()];
  for (const [col, v] of [
    ["status", p.status],
    ["total", p.total],
    ["done", p.done],
    ["skipped", p.skipped],
    ["error", p.error],
  ] as const) {
    if (v !== undefined) {
      sets.push(`${col} = ?`);
      args.push(v);
    }
  }
  await db.prepare(`UPDATE jobs SET ${sets.join(", ")} WHERE id = ?`).bind(...args, id).run();
}

export async function jobExists(db: D1Database, id: string): Promise<boolean> {
  return (await db.prepare("SELECT 1 AS x FROM jobs WHERE id = ?").bind(id).first()) !== null;
}
