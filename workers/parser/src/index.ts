import { FetchError } from "@sroka/extractor";
import { ParseJobSchema, r2Keys, type ParseJob } from "@sroka/shared";
import { deletePrefix, runWeeklyGc } from "./gc.ts";
import type { ParserEnv } from "./env.ts";
import { defaultDeps, failedResult, processJob, type Deps } from "./process.ts";

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
  const lib = env.LIBRARY.getByName(job.userId);
  // Superseded (newer parse gen), already done (duplicate delivery), item deleted or account wiped: skip the
  // fetch/extract/R2 work entirely. An RPC error degrades to "wanted".
  const stillWanted = async (): Promise<boolean> => {
    try {
      return await lib.parseWanted(job.itemId, job.parseGen);
    } catch (e) {
      console.warn(`parseWanted failed for ${job.itemId}`, e);
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
      result = await processJob(env, job, deps, stillWanted);
      if (result === null) {
        msg.ack();
        return;
      }
    } catch (e) {
      const code = e instanceof FetchError ? e.code : "parse_failed";
      console.warn(`parse attempt ${msg.attempts} failed for ${job.itemId}: ${e instanceof Error ? e.message : e}`);
      if (msg.attempts <= MAX_RETRIES) {
        msg.retry({ delaySeconds: backoff(msg.attempts) });
        return;
      }
      result = failedResult(job, code);
    }
    // Shared-content references are reported to D1 by the LibraryDO itself (content_refs, api.md §9).
    const ack = await lib.markParsed(job.itemId, result);
    if (!ack?.ok && result.contentPrivate && result.contentId) {
      // Rejected (stale, duplicate, item deleted, account wiped): this private dir is referenced by nothing.
      await deletePrefix(env.CONTENT, r2Keys.contentDir(result.contentId, job.userId)).catch((e) =>
        console.warn("private content cleanup failed", e),
      );
    }
    msg.ack();
  } catch (e) {
    // markParsed RPC failure etc. NOTE: the retry re-parses with a new contentId; a public dir from this
    // attempt has a content row without refs and is collected by the shared-content GC (gc.ts); private ones
    // are only swept once the account is deleted.
    console.error(`markParsed failed for ${job.itemId}`, e);
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
    try {
      await env.LIBRARY.getByName(parsed.data.userId).markParsed(parsed.data.itemId, failedResult(parsed.data, "parse_failed"));
      msg.ack();
    } catch (e) {
      console.error("DLQ markParsed failed", e);
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
