import { WorkflowEntrypoint, type WorkflowEvent, type WorkflowStep } from "cloudflare:workers";
import { IMPORT_DEVICE_ID, log, type ImportFormat, uuidv7 } from "@sroka/shared";
import type { Env } from "../env.ts";
import { enqueueParseJobs } from "../do/route-helpers.ts";
import { jobExists, updateJob } from "./jobs.ts";
import { type ImportRow, ImportParseError, parseImport } from "./parsers.ts";

export interface ImportParams {
  userId: string;
  importId: string;
  format: ImportFormat;
  /** R2 key of the upload. */
  uploadKey: string;
  /** Job creation time (stable `at` for generated ops across step retries). */
  startedAt: number;
}

export const IMPORT_BATCH_SIZE = 200;
export const IMPORT_THROTTLE = "3 seconds" as const;

type RowWithId = ImportRow & { itemId: string };
type StepLike = Pick<WorkflowStep, "do" | "sleep">;

const chunkKey = (p: ImportParams, i: number) => `uploads/${p.userId}/${p.importId}/rows-${i}.json`;

const RETRY = { retries: { limit: 3, delay: "5 seconds", backoff: "exponential" }, timeout: "5 minutes" } as const;

/** Deletes the upload and all row chunks of an import (also on failure: they hold the user's whole export). */
async function cleanup(env: Env, p: ImportParams): Promise<void> {
  const prefix = `uploads/${p.userId}/${p.importId}/`;
  const keys = [p.uploadKey];
  let cursor: string | undefined;
  do {
    const l = await env.CONTENT.list({ prefix, cursor });
    keys.push(...l.objects.map((o) => o.key));
    cursor = l.truncated ? l.cursor : undefined;
  } while (cursor);
  for (let i = 0; i < keys.length; i += 1000) await env.CONTENT.delete(keys.slice(i, i + 1000));
}

/** Workflow body, separated from the class so tests can drive it with a fake step. */
export async function runImport(
  env: Env,
  p: ImportParams,
  step: StepLike,
  opts: { throttle?: boolean } = {},
): Promise<{ status: "done" | "failed"; total: number; skipped: number }> {
  const throttle = opts.throttle ?? true;
  try {
    // 1. Parse the upload into normalized row batches stored in R2 (step outputs are limited to 1 MiB).
    const parsed = await step.do("parse", async () => {
      await updateJob(env.DB, p.importId, { status: "running" });
      const obj = await env.CONTENT.get(p.uploadKey);
      if (!obj) return { ok: false as const, error: "upload_missing" };
      let result;
      try {
        result = parseImport(p.format, new Uint8Array(await obj.arrayBuffer()));
      } catch (e) {
        if (e instanceof ImportParseError) return { ok: false as const, error: e.code };
        throw e;
      }
      const rows: RowWithId[] = result.rows.map((r) => ({ ...r, itemId: uuidv7() }));
      const batches = Math.ceil(rows.length / IMPORT_BATCH_SIZE);
      for (let i = 0; i < batches; i++) {
        await env.CONTENT.put(chunkKey(p, i), JSON.stringify(rows.slice(i * IMPORT_BATCH_SIZE, (i + 1) * IMPORT_BATCH_SIZE)));
      }
      const total = rows.length + result.invalid;
      await updateJob(env.DB, p.importId, { total, done: result.invalid, skipped: result.invalid });
      return { ok: true as const, total, invalid: result.invalid, batches };
    });

    if (!parsed.ok) {
      await step.do("fail", async () => {
        await updateJob(env.DB, p.importId, { status: "failed", error: parsed.error });
        await cleanup(env, p);
      });
      return { status: "failed", total: 0, skipped: 0 };
    }

    // 2. Apply batches (newest first) and enqueue parse jobs; progress is written as absolute values.
    let done = parsed.invalid;
    let skipped = parsed.invalid;
    for (let i = 0; i < parsed.batches; i++) {
      const res = await step.do(`apply-${i}`, RETRY, async () => {
        // The account was deleted while we ran: do nothing (and don't recreate the user's library).
        if (!(await jobExists(env.DB, p.importId))) return { count: 0, rejected: 0, gone: true };
        const obj = await env.CONTENT.get(chunkKey(p, i));
        if (!obj) throw new Error(`rows chunk ${i} missing`);
        const rows = (await obj.json()) as RowWithId[];
        const ops = rows.map((r, j) => ({
          type: "item.add" as const,
          // Deterministic per import + row: step retries replay idempotently in the DO.
          opId: `${p.importId}:${i * IMPORT_BATCH_SIZE + j}`,
          at: p.startedAt,
          itemId: r.itemId,
          url: r.url,
          ...(r.title ? { title: r.title } : {}),
          tags: r.tags,
          source: "import" as const,
          ...(r.savedAt ? { savedAt: r.savedAt } : {}),
          status: r.status,
          isFavorite: r.isFavorite,
          onDuplicate: "merge" as const,
        }));
        const { response, parseJobs } = await env.LIBRARY.getByName(p.userId).applyOps(IMPORT_DEVICE_ID, ops);
        await enqueueParseJobs(env, parseJobs, p.userId);
        return { count: rows.length, rejected: response.rejected.length, gone: false };
      });
      if (res.gone) {
        await cleanup(env, p);
        return { status: "failed", total: parsed.total, skipped };
      }
      done += res.count;
      skipped += res.rejected;
      await step.do(`progress-${i}`, async () => updateJob(env.DB, p.importId, { done, skipped }));
      if (throttle && i < parsed.batches - 1) await step.sleep(`throttle-${i}`, IMPORT_THROTTLE);
    }

    // 3. Finish + cleanup.
    await step.do("finish", async () => {
      await updateJob(env.DB, p.importId, { status: "done", done, skipped });
      await cleanup(env, p);
    });
    return { status: "done", total: parsed.total, skipped };
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    log.exception("import failed", e, { event: "import_failed", importId: p.importId });
    await step.do("fail-unexpected", async () => {
      await updateJob(env.DB, p.importId, { status: "failed", error: msg.slice(0, 300) });
      await cleanup(env, p);
    });
    return { status: "failed", total: 0, skipped: 0 };
  }
}

export class ImportWorkflow extends WorkflowEntrypoint<Env, ImportParams> {
  override async run(event: Readonly<WorkflowEvent<ImportParams>>, step: WorkflowStep) {
    return runImport(this.env, event.payload, step);
  }
}
