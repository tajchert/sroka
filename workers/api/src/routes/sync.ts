/** /v1/sync — docs/api.md §7. Mounted by index.ts behind the auth middleware (sets c.var.userId). */
import { PullQuery, PushRequest, log, writeMetric } from "@sroka/shared";
import { Hono } from "hono";
import { type LibraryAppEnv, apiError, enqueueParseJobs, library, readJson, validationError } from "../do/route-helpers.ts";

export const syncRoutes = new Hono<LibraryAppEnv>();

syncRoutes.post("/push", async (c) => {
  const parsed = PushRequest.safeParse(await readJson(c));
  if (!parsed.success) return validationError(c, parsed.error);
  // Ops are validated one by one inside applyOps (invalid → rejected "invalid_op").
  const { response, parseJobs } = await library(c).applyOps(parsed.data.deviceId, parsed.data.ops);
  await enqueueParseJobs(c.env, parseJobs, c.var.userId);
  writeMetric(c.env.METRICS, { event: "sync_push", blobs: [response.rejected.length ? "rejected" : "ok"], doubles: [parsed.data.ops.length, response.applied.length, response.rejected.length] });
  if (response.rejected.length) {
    const byReason: Record<string, number> = {};
    for (const r of response.rejected) byReason[r.reason] = (byReason[r.reason] ?? 0) + 1;
    log.warn("sync push rejected ops", { event: "sync_rejected", requestId: c.var.requestId, ops: parsed.data.ops.length, applied: response.applied.length, rejected: response.rejected.length, byReason });
  }
  return c.json(response);
});

syncRoutes.get("/pull", async (c) => {
  const parsed = PullQuery.safeParse(c.req.query());
  if (!parsed.success) return validationError(c, parsed.error);
  const r = await library(c).pull(parsed.data.cursor, parsed.data.limit, parsed.data.full);
  if (!r.ok) return apiError(c, 410, r.error);
  return c.json(r.data);
});
