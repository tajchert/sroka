/** /v1/sync — docs/api.md §7. Mounted by index.ts behind the auth middleware (sets c.var.userId). */
import { PullQuery, PushRequest } from "@sroka/shared";
import { Hono } from "hono";
import { type LibraryAppEnv, apiError, enqueueParseJobs, library, readJson, validationError } from "../do/route-helpers.ts";

export const syncRoutes = new Hono<LibraryAppEnv>();

syncRoutes.post("/push", async (c) => {
  const parsed = PushRequest.safeParse(await readJson(c));
  if (!parsed.success) return validationError(c, parsed.error);
  // Ops are validated one by one inside applyOps (invalid → rejected "invalid_op").
  const { response, parseJobs } = await library(c).applyOps(parsed.data.deviceId, parsed.data.ops);
  await enqueueParseJobs(c.env, parseJobs, c.var.userId);
  return c.json(response);
});

syncRoutes.get("/pull", async (c) => {
  const parsed = PullQuery.safeParse(c.req.query());
  if (!parsed.success) return validationError(c, parsed.error);
  const r = await library(c).pull(parsed.data.cursor, parsed.data.limit);
  if (!r.ok) return apiError(c, 410, r.error);
  return c.json(r.data);
});
