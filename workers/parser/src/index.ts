import { FetchError } from "@sroka/extractor";
import { ParseJobSchema, type ParseJob } from "@sroka/shared";
import type { ParserEnv } from "./env.ts";
import { defaultDeps, failedResult, incrementRefCount, processJob, type Deps } from "./process.ts";

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
  try {
    let result;
    try {
      result = await processJob(env, job, deps);
    } catch (e) {
      const code = e instanceof FetchError ? e.code : "parse_failed";
      console.warn(`parse attempt ${msg.attempts} failed for ${job.itemId}: ${e instanceof Error ? e.message : e}`);
      if (msg.attempts <= MAX_RETRIES) {
        msg.retry({ delaySeconds: backoff(msg.attempts) });
        return;
      }
      result = failedResult(job, code);
    }
    const ack = await lib.markParsed(job.itemId, result);
    if (ack?.ok) await incrementRefCount(env, result);
    msg.ack();
  } catch (e) {
    // markParsed RPC failure etc. NOTE: the retry re-parses with a new contentId; orphaned R2 objects /
    // content row (ref_count 0) from this attempt are left to the weekly GC.
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
} satisfies ExportedHandler<ParserEnv, ParseJob>;
