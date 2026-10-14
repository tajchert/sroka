/** /v1/items — docs/api.md §5. Mounted by index.ts behind the auth middleware (sets c.var.userId). */
import {
  CreateItemRequest,
  LIMITS,
  ListItemsQuery,
  type Op,
  UpdateItemRequest,
  buildContentUrls,
  contentScope,
  r2Keys,
  tryNormalizeUrl,
  uuidv7,
} from "@sroka/shared";
import { Hono } from "hono";
import {
  type LibraryAppEnv,
  apiError,
  enqueueParseJobs,
  gzipText,
  library,
  readJson,
  restDeviceId,
  validItemId,
  validationError,
} from "../do/route-helpers.ts";

export const itemsRoutes = new Hono<LibraryAppEnv>();

// 5.1 quick save
itemsRoutes.post("/", async (c) => {
  const len = Number(c.req.header("content-length") ?? "0");
  if (len > LIMITS.maxSaveBodyBytes) return apiError(c, 413, "payload_too_large");
  const text = await c.req.text();
  if (new TextEncoder().encode(text).byteLength > LIMITS.maxSaveBodyBytes) return apiError(c, 413, "payload_too_large");
  let body: unknown;
  try {
    body = JSON.parse(text);
  } catch {
    return apiError(c, 400, "invalid_request", "invalid_json");
  }
  const parsed = CreateItemRequest.safeParse(body);
  if (!parsed.success) return validationError(c, parsed.error);
  const req = parsed.data;
  if (req.html !== undefined && new TextEncoder().encode(req.html).byteLength > LIMITS.maxHtmlBytes) {
    return apiError(c, 413, "payload_too_large");
  }
  if (!tryNormalizeUrl(req.url)) return apiError(c, 400, "invalid_url");

  const userId = c.var.userId;
  const stub = library(c);
  const itemId = uuidv7();
  const op: Op = {
    opId: uuidv7(),
    at: Date.now(),
    type: "item.add",
    itemId,
    url: req.url,
    source: req.source ?? "api",
    onDuplicate: "readd",
  };
  if (req.title !== undefined) op.title = req.title;
  if (req.tags !== undefined) op.tags = req.tags;

  const res = await stub.applyRest(restDeviceId(c), [op], { itemId });
  const rej = res.response.rejected[0];
  if (rej) {
    if (rej.reason === "invalid_url") return apiError(c, 400, "invalid_url");
    return apiError(c, 400, "invalid_request", rej.reason);
  }
  if (!res.item) return apiError(c, 500, "internal");
  const created = res.response.aliases[itemId] === undefined;
  let item = res.item;

  if (req.html !== undefined) {
    const rawKey = r2Keys.raw(userId, item.id);
    await c.env.CONTENT.put(rawKey, await gzipText(req.html), {
      httpMetadata: { contentType: "text/html; charset=utf-8", contentEncoding: "gzip" },
    });
    const { job, item: after } = await stub.requestParseAndGet(item.id, { rawKey, force: true });
    if (job) await enqueueParseJobs(c.env, [job]);
    if (after) item = after;
  } else {
    await enqueueParseJobs(c.env, res.parseJobs);
  }
  return c.json({ item, created }, 202);
});

// 5.2 list / search / lookup
itemsRoutes.get("/", async (c) => {
  const parsed = ListItemsQuery.safeParse(c.req.query());
  if (!parsed.success) return validationError(c, parsed.error);
  const q = parsed.data;
  let canonical: string | null = null;
  if (q.url !== undefined) {
    canonical = tryNormalizeUrl(q.url);
    if (!canonical) return apiError(c, 400, "invalid_url");
  }
  const r = await library(c).listItems(q, canonical);
  if (!r.ok) return apiError(c, 400, "invalid_request", r.error);
  return c.json({ items: r.items, nextCursor: r.nextCursor });
});

// 5.3
itemsRoutes.get("/:id", async (c) => {
  const id = c.req.param("id");
  if (!validItemId(id)) return apiError(c, 404, "not_found");
  const item = await library(c).getItem(id);
  if (!item) return apiError(c, 404, "not_found");
  return c.json({ item });
});

// 5.4
itemsRoutes.patch("/:id", async (c) => {
  const id = c.req.param("id");
  if (!validItemId(id)) return apiError(c, 404, "not_found");
  const body = await readJson(c);
  if (body && typeof body === "object" && "tags" in body && Array.isArray(body.tags) && body.tags.length > LIMITS.maxTagsPerItem) {
    return apiError(c, 400, "invalid_request", "too_many_tags");
  }
  const parsed = UpdateItemRequest.safeParse(body);
  if (!parsed.success) return validationError(c, parsed.error);
  const res = await library(c).patchItem(restDeviceId(c), id, parsed.data, Date.now());
  if (!res.item) return apiError(c, 404, "not_found");
  const rej = res.response.rejected[0];
  if (rej) {
    if (rej.reason === "unknown_item" || rej.reason === "item_deleted") return apiError(c, 404, "not_found");
    return apiError(c, 400, "invalid_request", rej.reason);
  }
  return c.json({ item: res.item });
});

// 5.5
itemsRoutes.delete("/:id", async (c) => {
  const id = c.req.param("id");
  if (!validItemId(id)) return apiError(c, 404, "not_found");
  const res = await library(c).applyRest(restDeviceId(c), [{ opId: uuidv7(), at: Date.now(), type: "item.delete", itemId: id }], {
    itemId: id,
    requireLive: true,
  });
  if (res.response.applied.length === 0) return apiError(c, 404, "not_found");
  return c.body(null, 204);
});

// 5.6
itemsRoutes.post("/:id/refresh", async (c) => {
  const id = c.req.param("id");
  if (!validItemId(id)) return apiError(c, 404, "not_found");
  const res = await library(c).applyRest(restDeviceId(c), [{ opId: uuidv7(), at: Date.now(), type: "item.refresh", itemId: id }], {
    itemId: id,
    requireLive: true,
  });
  if (!res.item || res.response.applied.length === 0) return apiError(c, 404, "not_found");
  await enqueueParseJobs(c.env, res.parseJobs);
  return c.json({ item: res.item }, 202);
});

// 5.7 signed content URLs
itemsRoutes.get("/:id/content", async (c) => {
  const id = c.req.param("id");
  if (!validItemId(id)) return apiError(c, 404, "not_found");
  const item = await library(c).getItem(id);
  if (!item) return apiError(c, 404, "not_found");
  if (!item.contentId) return apiError(c, 409, "not_parsed");
  const urls = await buildContentUrls({
    origin: c.env.CONTENT_ORIGIN,
    secret: c.env.CONTENT_URL_SIGNING_KEY,
    scope: contentScope(item.contentPrivate, c.var.userId),
    contentId: item.contentId,
  });
  return c.json(urls);
});
