import { createExecutionContext, waitOnExecutionContext } from "cloudflare:test";
import { env } from "cloudflare:workers";
import type { ParseJob } from "@sroka/shared";
import { Hono } from "hono";
import type { Env } from "../../src/env.ts";
import { exportsRoutes } from "../../src/routes/exports.ts";
import { importsRoutes } from "../../src/routes/imports.ts";
import { migrate } from "../platform/helpers.ts";

export const uniqueUser = () => `ie_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 8)}`;

/** Test app with fake auth (x-test-user), fake PARSE_QUEUE and a recording fake IMPORT_WORKFLOW. */
export function makeApp(opts: { workflowFails?: boolean } = {}) {
  const sent: ParseJob[] = [];
  const created: { id: string; params: any }[] = [];
  const queue = {
    async send(body: ParseJob) {
      sent.push(body);
    },
    async sendBatch(msgs: Iterable<{ body: ParseJob }>) {
      for (const m of msgs) sent.push(m.body);
    },
  };
  const workflow = {
    async create(o: { id: string; params: unknown }) {
      if (opts.workflowFails) throw new Error("boom");
      created.push({ id: o.id, params: o.params });
      return {};
    },
  };
  const testEnv = {
    ...(env as unknown as Env),
    PARSE_QUEUE: queue as unknown as Env["PARSE_QUEUE"],
    IMPORT_WORKFLOW: workflow as unknown as Env["IMPORT_WORKFLOW"],
  } as Env;
  const app = new Hono<{ Bindings: Env; Variables: { userId: string } }>();
  app.use("/v1/*", async (c, next) => {
    const u = c.req.header("x-test-user");
    if (!u) return c.json({ error: "unauthorized" }, 401);
    c.set("userId", u);
    await next();
  });
  app.route("/v1/imports", importsRoutes);
  app.route("/v1/exports", exportsRoutes);
  const user = uniqueUser();

  async function raw(path: string, init: RequestInit = {}, asUser = user): Promise<Response> {
    await migrate();
    const ctx = createExecutionContext();
    const res = await app.fetch(
      new Request(`http://localhost:8787${path}`, { ...init, headers: { "x-test-user": asUser, ...(init.headers as object) } }),
      testEnv,
      ctx,
    );
    await waitOnExecutionContext(ctx);
    return res;
  }
  return { raw, sent, created, user, env: testEnv };
}
