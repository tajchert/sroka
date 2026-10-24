/** Shared helpers for the library routes (routes/items.ts, tags.ts, sync.ts). */
import { DEVICE_HEADER, DeviceId, log, type ParseJob, REST_DEVICE_ID, isUuid, toApiError } from "@sroka/shared";
import type { Context } from "hono";
import type { ContentfulStatusCode } from "hono/utils/http-status";
import type { z } from "zod";
import type { Env } from "../env.ts";

/** Hono env of the /v1 library sub-apps: an auth middleware (api-platform) has set `userId`. */
export type LibraryAppEnv = { Bindings: Env; Variables: { userId: string; requestId: string } };
export type LibraryContext = Context<LibraryAppEnv>;

export function apiError(c: Context, status: ContentfulStatusCode, error: string, message?: string): Response {
  return c.json(message === undefined ? { error } : { error, message }, status);
}

export function validationError(c: Context, err: z.ZodError): Response {
  return c.json(toApiError(err), 400);
}

export function library(c: LibraryContext) {
  return c.env.LIBRARY.getByName(c.var.userId);
}

/** LWW tie-breaker device id from `X-Sroka-Device` (api.md §1); invalid/missing → "rest". */
export function restDeviceId(c: Context): string {
  const h = c.req.header(DEVICE_HEADER);
  return h && DeviceId.safeParse(h).success ? h : REST_DEVICE_ID;
}

/** Reads a JSON body; null on malformed JSON. */
export async function readJson(c: Context): Promise<unknown> {
  try {
    return await c.req.json();
  } catch {
    return undefined;
  }
}

export function validItemId(id: string): boolean {
  return isUuid(id);
}

const ENQUEUE_ATTEMPTS = 3;

/**
 * Enqueues parse jobs (≤100 per sendBatch), retrying each chunk. Never throws: the ops behind the jobs are
 * already committed (a 500 would make the client retry an idempotent push that returns no jobs). If a send
 * still fails, the LibraryDO is asked to run its stuck-pending sweep soon, which re-enqueues those items.
 */
export async function enqueueParseJobs(env: Env, jobs: readonly ParseJob[], userId?: string): Promise<void> {
  for (let i = 0; i < jobs.length; i += 100) {
    const chunk = jobs.slice(i, i + 100);
    let lastErr: unknown;
    for (let attempt = 0; attempt < ENQUEUE_ATTEMPTS; attempt++) {
      try {
        if (chunk.length === 1) await env.PARSE_QUEUE.send(chunk[0]!);
        else await env.PARSE_QUEUE.sendBatch(chunk.map((body) => ({ body })));
        lastErr = undefined;
        break;
      } catch (e) {
        lastErr = e;
      }
    }
    if (lastErr !== undefined) {
      log.exception("parse queue send failed, deferring to the LibraryDO sweep", lastErr, { event: "queue_send_failed", jobs: chunk.length });
      const uid = userId ?? chunk[0]!.userId;
      try {
        await env.LIBRARY.getByName(uid).scheduleParseSweep();
      } catch (e) {
        // The daily alarm sweep still picks the items up.
        log.exception("scheduleParseSweep failed", e, { event: "sweep_schedule_failed" });
      }
    }
  }
}

/** gzip (CompressionStream) of a UTF-8 string. */
export async function gzipText(text: string): Promise<ArrayBuffer> {
  const stream = new Blob([text]).stream().pipeThrough(new CompressionStream("gzip"));
  return new Response(stream).arrayBuffer();
}

export const isGzip = (b: Uint8Array): boolean => b.byteLength >= 2 && b[0] === 0x1f && b[1] === 0x8b;

/** Gunzip with an output cap (gzip bombs): the bytes, or "too_large" / "corrupt". */
export async function gunzipCapped(input: Uint8Array, maxBytes: number): Promise<Uint8Array | "too_large" | "corrupt"> {
  const reader = new Blob([input]).stream().pipeThrough(new DecompressionStream("gzip")).getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.byteLength;
      if (total > maxBytes) {
        await reader.cancel().catch(() => {});
        return "too_large";
      }
      chunks.push(value);
    }
  } catch {
    return "corrupt";
  }
  const out = new Uint8Array(total);
  let off = 0;
  for (const c of chunks) {
    out.set(c, off);
    off += c.byteLength;
  }
  return out;
}
