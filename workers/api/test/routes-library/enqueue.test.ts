import { runInDurableObject } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { type ParseJob, uuidv7 } from "@sroka/shared";
import { describe, expect, it } from "vitest";
import { enqueueParseJobs } from "../../src/do/route-helpers.ts";
import type { Env } from "../../src/env.ts";

describe("enqueueParseJobs", () => {
  it("retries, never throws, and schedules the DO sweep when the queue keeps failing", async () => {
    const userId = `enq_${uuidv7()}`;
    let calls = 0;
    const failing = {
      async send() {
        calls++;
        throw new Error("queue down");
      },
      async sendBatch() {
        calls++;
        throw new Error("queue down");
      },
    };
    const testEnv = { ...(env as unknown as Env), PARSE_QUEUE: failing as unknown as Env["PARSE_QUEUE"] };
    const job: ParseJob = { userId, itemId: uuidv7(), url: "https://x.example/", parseGen: 1 };
    await expect(enqueueParseJobs(testEnv, [job], userId)).resolves.toBeUndefined();
    expect(calls).toBe(3);
    const stub = testEnv.LIBRARY.getByName(userId);
    await runInDurableObject(stub, async (_inst, state) => {
      const alarm = await state.storage.getAlarm();
      expect(alarm).not.toBeNull();
      expect(alarm! - Date.now()).toBeLessThan(60 * 60 * 1000);
    });
  });

  it("succeeds after a transient failure", async () => {
    const sent: ParseJob[] = [];
    let n = 0;
    const flaky = {
      async send(b: ParseJob) {
        if (n++ === 0) throw new Error("blip");
        sent.push(b);
      },
    };
    const testEnv = { ...(env as unknown as Env), PARSE_QUEUE: flaky as unknown as Env["PARSE_QUEUE"] };
    const job: ParseJob = { userId: "u", itemId: uuidv7(), url: "https://x.example/", parseGen: 1 };
    await enqueueParseJobs(testEnv, [job], "u");
    expect(sent).toEqual([job]);
  });
});
