import { ParseJobSchema, type ParseJob } from "@sroka/shared";
import type { ParserEnv } from "./env.ts";

export default {
  async queue(batch: MessageBatch<ParseJob>, _env: ParserEnv): Promise<void> {
    for (const m of batch.messages) {
      const job = ParseJobSchema.safeParse(m.body);
      if (!job.success) {
        m.ack(); // malformed — drop
        continue;
      }
      // Placeholder: implemented in the "Extractor + parser worker" step.
      m.retry({ delaySeconds: 30 });
    }
  },
} satisfies ExportedHandler<ParserEnv, ParseJob>;
