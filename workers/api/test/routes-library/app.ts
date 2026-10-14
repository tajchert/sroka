import { createExecutionContext, waitOnExecutionContext } from "cloudflare:test";
import { env } from "cloudflare:workers";
import type { ParseJob } from "@sroka/shared";
import { Hono } from "hono";
import type { Env } from "../../src/env.ts";
import { itemsRoutes } from "../../src/routes/items.ts";
import { syncRoutes } from "../../src/routes/sync.ts";
import { tagsRoutes } from "../../src/routes/tags.ts";

/** Test app: fake auth middleware (userId from `x-test-user`) + the library sub-apps, fake PARSE_QUEUE. */
export function makeApp() {
  const sent: ParseJob[] = [];
  const queue = {
    async send(body: ParseJob) {
      sent.push(body);
    },
    async sendBatch(msgs: Iterable<{ body: ParseJob }>) {
      for (const m of msgs) sent.push(m.body);
    },
  };
  const testEnv = { ...(env as unknown as Env), PARSE_QUEUE: queue as unknown as Env["PARSE_QUEUE"] };
  const app = new Hono<{ Bindings: Env; Variables: { userId: string } }>();
  app.use("/v1/*", async (c, next) => {
    const u = c.req.header("x-test-user");
    if (!u) return c.json({ error: "unauthorized" }, 401);
    c.set("userId", u);
    await next();
  });
  app.route("/v1/items", itemsRoutes);
  app.route("/v1/tags", tagsRoutes);
  app.route("/v1/sync", syncRoutes);

  let n = 0;
  const user = `rt_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 8)}`;
  async function call(method: string, path: string, body?: unknown, headers: Record<string, string> = {}) {
    const ctx = createExecutionContext();
    const init: RequestInit = { method, headers: { "x-test-user": user, ...headers } };
    if (body !== undefined) {
      init.body = typeof body === "string" ? body : JSON.stringify(body);
      (init.headers as Record<string, string>)["content-type"] = "application/json";
    }
    const res = await app.fetch(new Request(`http://localhost:8787${path}`, init), testEnv, ctx);
    await waitOnExecutionContext(ctx);
    n++;
    const text = await res.text();
    return { status: res.status, json: text ? (JSON.parse(text) as any) : null };
  }
  return { call, sent, user, env: testEnv };
}
