import { FetchError } from "@sroka/extractor";
import { displayDomain, log, ParseJobSchema, PARSER_VERSION, r2Keys, type ParseJob } from "@sroka/shared";
import { reportParse } from "./attempts.ts";
import { deletePrefix, runWeeklyGc } from "./gc.ts";
import type { ParserEnv } from "./env.ts";
import { TEXT_FILE } from "./pdf-text.ts";
import { defaultDeps, failedResult, processJob, type Deps, type JobStats } from "./process.ts";

export { processJob } from "./process.ts";

const DLQ = "sroka-parse-dlq";
/** queue max_retries (wrangler.jsonc) => attempts are 1..4 */
const MAX_RETRIES = 3;

function backoff(attempts: number): number {
  return Math.min(30 * 2 ** (attempts - 1), 900);
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
      stats.errorDetail ??= (e instanceof Error ? e.message : String(e)).slice(0, 300);
    }
    await reportParse(env, { job, result, stats, durationMs: Date.now() - t0, attempt: msg.attempts });
    const ack = await lib.markParsed(job.itemId, result);
    if (!ack?.ok && result.contentPrivate && result.contentId) {
      // Rejected (stale, duplicate, item deleted, account wiped): this private dir is referenced by nothing.
      // PDF jobs: the dir holds the user's original (document.pdf) — only drop the text.txt this job wrote.
      const cleanup = job.pdf
        ? env.CONTENT.delete(r2Keys.contentDir(result.contentId, job.userId) + TEXT_FILE)
        : deletePrefix(env.CONTENT, r2Keys.contentDir(result.contentId, job.userId));
      await cleanup.catch((e) =>
        log.warnException("private content cleanup failed", e, { event: "private_cleanup_failed" }),
      );
    }
    msg.ack();
  } catch (e) {
    // markParsed RPC failure etc. NOTE: the retry re-parses with a new contentId; a public dir from this
    // attempt has a content row without refs and is collected by the shared-content GC (gc.ts); private ones
    // are only swept once the account is deleted.
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
    const result = failedResult(parsed.data, "parse_failed");
    try {
      await env.LIBRARY.getByName(parsed.data.userId).markParsed(parsed.data.itemId, result);
      await reportParse(env, { job: parsed.data, result, stats: { errorDetail: "dlq" }, durationMs: 0, attempt: msg.attempts, source: "dlq" });
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
  /** Weekly cron (wrangler.jsonc triggers): deleted accounts' R2 data, auth throttle rows, shared content (gc.ts). */
  async scheduled(_ctrl: ScheduledController, env: ParserEnv): Promise<void> {
    await runWeeklyGc(env);
  },
} satisfies ExportedHandler<ParserEnv, ParseJob>;
