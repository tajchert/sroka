import { FetchError } from "@sroka/extractor";
import { displayDomain, log, ParseJobSchema, PARSER_VERSION, r2Keys, writeMetric, type ParseJob, type ParseResult } from "@sroka/shared";
import { deletePrefix, sweepOrphanedUserData } from "./gc.ts";
import type { ParserEnv } from "./env.ts";
import { defaultDeps, failedResult, incrementRefCount, processJob, type Deps, type JobStats } from "./process.ts";

export { processJob } from "./process.ts";

const DLQ = "sroka-parse-dlq";
/** queue max_retries (wrangler.jsonc) => attempts are 1..4 */
const MAX_RETRIES = 3;

function backoff(attempts: number): number {
  return Math.min(30 * 2 ** (attempts - 1), 900);
}

/** One `parse` log line + Analytics Engine point per finished job (domain only, never the URL path). */
function reportParse(env: ParserEnv, job: ParseJob, result: ParseResult, stats: JobStats, durationMs: number, attempts: number): void {
  const domain = displayDomain(job.url) || "unknown";
  const source = job.rawKey ? "capture" : job.force ? "refresh" : "fetch";
  const level = result.status === "failed" ? "warn" : "info";
  log[level]("parse", {
    event: "parse",
    domain,
    status: result.status,
    error: result.error,
    source,
    durationMs,
    bytes: stats.bytes ?? 0,
    images: stats.images ?? 0,
    cacheHit: stats.cacheHit ?? false,
    parserVersion: result.parserVersion,
    attempts,
    itemId: job.itemId,
  });
  writeMetric(env.METRICS, {
    event: "parse",
    blobs: [domain, result.status, result.error ?? "", source, stats.cacheHit ? "hit" : "miss"],
    doubles: [durationMs, stats.bytes ?? 0, stats.images ?? 0],
    index: domain,
  });
}

async function handleMessage(msg: Message<ParseJob>, env: ParserEnv, deps: Deps): Promise<void> {
  const parsed = ParseJobSchema.safeParse(msg.body);
  if (!parsed.success) {
    msg.ack(); // malformed — drop
    return;
  }
  const job = parsed.data;
  const t0 = Date.now();
  const stats: JobStats = {};
  const lib = env.LIBRARY.getByName(job.userId);
  // Superseded (newer parse gen), already done (duplicate delivery), item deleted or account wiped: skip the
  // fetch/extract/R2 work entirely. An RPC error degrades to "wanted".
  const stillWanted = async (): Promise<boolean> => {
    try {
      return await lib.parseWanted(job.itemId, job.parseGen);
    } catch (e) {
      log.warnException("parseWanted failed", e, { event: "parse_wanted_failed", itemId: job.itemId });
      return true;
    }
  };
  if (!(await stillWanted())) {
    msg.ack();
    return;
  }
  try {
    let result;
    try {
      result = await processJob(env, job, deps, stillWanted, stats);
      if (result === null) {
        msg.ack();
        return;
      }
    } catch (e) {
      const code = e instanceof FetchError ? e.code : "parse_failed";
      log.warnException("parse attempt failed", e, { event: "parse_retry", domain: displayDomain(job.url), itemId: job.itemId, attempt: msg.attempts, code, willRetry: msg.attempts <= MAX_RETRIES });
      if (msg.attempts <= MAX_RETRIES) {
        msg.retry({ delaySeconds: backoff(msg.attempts) });
        return;
      }
      result = failedResult(job, code);
    }
    reportParse(env, job, result, stats, Date.now() - t0, msg.attempts);
    const ack = await lib.markParsed(job.itemId, result);
    if (ack?.ok) await incrementRefCount(env, result);
    else if (result.contentPrivate && result.contentId) {
      // Rejected (stale, duplicate, item deleted, account wiped): this private dir is referenced by nothing.
      await deletePrefix(env.CONTENT, r2Keys.contentDir(result.contentId, job.userId)).catch((e) =>
        log.warnException("private content cleanup failed", e, { event: "private_cleanup_failed" }),
      );
    }
    msg.ack();
  } catch (e) {
    // markParsed RPC failure etc. NOTE: the retry re-parses with a new contentId; orphaned R2 objects /
    // content row (ref_count 0) from this attempt are not collected yet (private ones of deleted accounts
    // are swept by the weekly cron, see gc.ts).
    log.exception("markParsed failed", e, { event: "mark_parsed_failed", itemId: job.itemId, attempt: msg.attempts });
    msg.retry({ delaySeconds: backoff(msg.attempts) });
  }
}

async function handleDlq(batch: MessageBatch<ParseJob>, env: ParserEnv): Promise<void> {
  for (const msg of batch.messages) {
    const parsed = ParseJobSchema.safeParse(msg.body);
    if (!parsed.success) {
      msg.ack();
      continue;
    }
    log.warn("job reached the dead-letter queue", { event: "dlq", domain: displayDomain(parsed.data.url), itemId: parsed.data.itemId, attempts: msg.attempts, parserVersion: PARSER_VERSION });
    writeMetric(env.METRICS, { event: "parse", blobs: [displayDomain(parsed.data.url) || "unknown", "failed", "dlq", "dlq", "miss"], doubles: [0, 0, 0], index: displayDomain(parsed.data.url) || "unknown" });
    try {
      await env.LIBRARY.getByName(parsed.data.userId).markParsed(parsed.data.itemId, failedResult(parsed.data, "parse_failed"));
      msg.ack();
    } catch (e) {
      log.exception("DLQ markParsed failed", e, { event: "dlq_mark_failed", itemId: parsed.data.itemId });
      msg.retry({ delaySeconds: 60 });
    }
  }
}

export default {
  async queue(batch: MessageBatch<ParseJob>, env: ParserEnv): Promise<void> {
    if (batch.queue === DLQ) return handleDlq(batch, env);
    // sequential: one parse at a time keeps memory/CPU within the isolate limits
    for (const m of batch.messages) await handleMessage(m, env, defaultDeps);
  },
  /** Weekly cron (wrangler.jsonc triggers): R2 data of deleted accounts, expired auth throttle rows. */
  async scheduled(_ctrl: ScheduledController, env: ParserEnv): Promise<void> {
    const t0 = Date.now();
    const { deleted } = await sweepOrphanedUserData(env);
    log.info("gc sweep finished", { event: "gc_sweep", deletedPrefixes: deleted.length, durationMs: Date.now() - t0 });
  },
} satisfies ExportedHandler<ParserEnv, ParseJob>;
