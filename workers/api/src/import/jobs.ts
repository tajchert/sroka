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

export async function insertJob(db: D1Database, j: { id: string; userId: string; format: string; now: number }): Promise<void> {
  await db
    .prepare(
      "INSERT INTO jobs (id, user_id, kind, status, format, total, done, skipped, error, created_at, updated_at) VALUES (?, ?, 'import', 'queued', ?, NULL, 0, 0, NULL, ?, ?)",
    )
    .bind(j.id, j.userId, j.format, j.now, j.now)
    .run();
}

export async function getJob(db: D1Database, userId: string, id: string): Promise<Job | null> {
  const r = await db.prepare("SELECT * FROM jobs WHERE id = ? AND user_id = ?").bind(id, userId).first<JobRow>();
  return r ? rowToJob(r) : null;
}

export async function countRecentImports(db: D1Database, userId: string, since: number): Promise<number> {
  const r = await db
    .prepare("SELECT COUNT(*) AS n FROM jobs WHERE user_id = ? AND kind = 'import' AND created_at >= ? AND COALESCE(error, '') != 'workflow_unavailable'")
    .bind(userId, since)
    .first<{ n: number }>();
  return r?.n ?? 0;
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
