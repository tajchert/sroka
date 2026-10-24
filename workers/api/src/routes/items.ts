/** /v1/items — docs/api.md §5. Mounted by index.ts behind the auth middleware (sets c.var.userId). */
import {
  CreateItemRequest,
  ItemSource,
  LIMITS,
  ListItemsQuery,
  type Op,
  PDF_FILE,
  TagNames,
  UpdateItemRequest,
  buildContentUrls,
  contentScope,
  log,
  r2Keys,
  tryNormalizeUrl,
  uuidv7,
  writeMetric,
} from "@sroka/shared";
import { Hono } from "hono";
import {
  type LibraryAppEnv,
  apiError,
  enqueueParseJobs,
  gunzipCapped,
  gzipText,
  isGzip,
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
  let bytes: Uint8Array = new Uint8Array(await c.req.arrayBuffer());
  if (bytes.byteLength > LIMITS.maxSaveBodyBytes) return apiError(c, 413, "payload_too_large");
  // The extension gzips captured pages (Content-Encoding: gzip). Sniff the magic bytes instead of trusting the
  // header, so a body the edge already decompressed (or a mislabelled one) still works.
  if (isGzip(bytes)) {
    const out = await gunzipCapped(bytes, LIMITS.maxSaveBodyBytes);
    if (out === "too_large") return apiError(c, 413, "payload_too_large");
    if (out === "corrupt") return apiError(c, 400, "invalid_request", "invalid_gzip");
    bytes = out;
  }
  let body: unknown;
  try {
    body = JSON.parse(new TextDecoder().decode(bytes));
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
  writeMetric(c.env.METRICS, { event: "save", blobs: [req.source ?? "api", rej ? rej.reason : "ok"] });
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
    if (job) await enqueueParseJobs(c.env, [job], c.var.userId);
    if (after) item = after;
  } else {
    await enqueueParseJobs(c.env, res.parseJobs, c.var.userId);
  }
  return c.json({ item, created }, 202);
});

// 5.8 PDF upload
type UploadAbortReason = "too_large" | "not_pdf";
class UploadAbort extends Error {
  constructor(
    readonly reason: UploadAbortReason,
    state: { abort: UploadAbortReason | null },
  ) {
    super(reason);
    state.abort = reason; // errors crossing stream/R2 boundaries lose their identity; the caller reads this instead
  }
}

/** Counts bytes, enforces the size cap while streaming and requires `%PDF-` within the first 1024 bytes. */
function pdfGuard(maxBytes: number, state: { abort: UploadAbortReason | null }): TransformStream<Uint8Array, Uint8Array> {
  let total = 0;
  let head = new Uint8Array(0);
  let checked = false;
  const check = (): void => {
    checked = true;
    // Latin-1 view of the head is enough for the ASCII marker.
    let text = "";
    for (const b of head) text += String.fromCharCode(b);
    if (!text.includes("%PDF-")) throw new UploadAbort("not_pdf", state);
  };
  return new TransformStream({
    transform(chunk, ctrl) {
      total += chunk.byteLength;
      if (total > maxBytes) throw new UploadAbort("too_large", state);
      if (!checked) {
        const merged = new Uint8Array(Math.min(1024, head.byteLength + chunk.byteLength));
        merged.set(head);
        merged.set(chunk.subarray(0, merged.byteLength - head.byteLength), head.byteLength);
        head = merged;
        if (head.byteLength >= 1024) check();
      }
      ctrl.enqueue(chunk);
    },
    flush() {
      if (!checked) check();
    },
  });
}

const hex = (buf: ArrayBuffer): string => [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");

/** Trimmed, control characters removed, truncated to maxFileNameLength keeping a trailing ".pdf". */
function cleanFileName(raw: string): string {
  // eslint-disable-next-line no-control-regex
  let name = raw.replace(/[\u0000-\u001f\u007f]/g, "").trim();
  const max = LIMITS.maxFileNameLength;
  if (name.length > max) {
    const ext = /\.pdf$/i.test(name) ? name.slice(-4) : "";
    name = name.slice(0, max - ext.length) + ext;
  }
  return name;
}

itemsRoutes.post("/pdf", async (c) => {
  const lenHeader = c.req.header("content-length");
  if (lenHeader === undefined || !/^\d+$/.test(lenHeader)) return apiError(c, 411, "length_required");
  const len = Number(lenHeader);
  if (len > LIMITS.maxPdfBytes) return apiError(c, 413, "payload_too_large");
  const ctype = (c.req.header("content-type") ?? "application/pdf").split(";")[0]!.trim().toLowerCase();
  if (ctype !== "application/pdf" && ctype !== "application/octet-stream") return apiError(c, 415, "unsupported_media_type");
  const name = cleanFileName(c.req.query("name") ?? "");
  if (name === "") return apiError(c, 400, "invalid_request", "name_required");
  const tags = TagNames.safeParse(c.req.queries("tag") ?? []);
  if (!tags.success) return validationError(c, tags.error);
  const source = ItemSource.safeParse(c.req.query("source") ?? "api");
  if (!source.success) return validationError(c, source.error);
  if (!c.req.raw.body) return apiError(c, 415, "unsupported_media_type");

  const userId = c.var.userId;
  const contentId = uuidv7();
  const key = r2Keys.contentDir(contentId, userId) + PDF_FILE;
  const removeObject = (): Promise<void> => c.env.CONTENT.delete(key).catch((e) => log.exception("pdf upload cleanup failed", e, { event: "pdf_cleanup_failed" }));

  // Stream into R2 and the SHA-256 digest at once; never buffer the file.
  let sha = "";
  const guard: { abort: UploadAbortReason | null } = { abort: null };
  try {
    const [forR2, forHash] = c.req.raw.body.pipeThrough(pdfGuard(LIMITS.maxPdfBytes, guard)).tee();
    const digest = new crypto.DigestStream("SHA-256");
    digest.digest.catch(() => {}); // rejects with the stream error; handled through `hashed` below
    const hashed = forHash.pipeTo(digest);
    const [put, hash] = await Promise.allSettled([
      c.env.CONTENT.put(key, forR2.pipeThrough(new FixedLengthStream(len)), { httpMetadata: { contentType: "application/pdf" } }),
      hashed.then(() => digest.digest),
    ]);
    if (put.status === "rejected") throw put.reason;
    if (hash.status === "rejected") throw hash.reason;
    sha = hex(hash.value);
  } catch (e) {
    await removeObject();
    if (guard.abort === "too_large") return apiError(c, 413, "payload_too_large");
    if (guard.abort === "not_pdf") return apiError(c, 415, "unsupported_media_type");
    // A body shorter/longer than Content-Length, or a dropped connection.
    log.warn("pdf upload stream failed", { event: "pdf_upload_failed" });
    return apiError(c, 400, "invalid_request", "upload_failed");
  }

  const fileName = name;
  let result;
  try {
    result = await library(c).addPdf(restDeviceId(c), {
      itemId: uuidv7(),
      url: `${c.env.APP_ORIGIN}/pdf/${sha}`,
      title: fileName.replace(/\.pdf$/i, "") || fileName,
      fileName,
      fileSize: len,
      contentId,
      tags: tags.data,
      source: source.data,
      at: Date.now(),
    });
  } catch (e) {
    await removeObject();
    throw e;
  }
  if (!result.ok || !result.created) await removeObject();
  writeMetric(c.env.METRICS, { event: "save", blobs: [`pdf:${source.data}`, result.ok ? (result.created ? "ok" : "duplicate") : result.error] });
  if (!result.ok) {
    if (result.error === "storage_full") return apiError(c, 409, "storage_full");
    return apiError(c, 400, "invalid_request", result.message ?? result.error);
  }
  await enqueueParseJobs(c.env, result.parseJobs, userId);
  return c.json({ item: result.item, created: result.created }, 202);
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
  await enqueueParseJobs(c.env, res.parseJobs, c.var.userId);
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
    pdf: item.kind === "pdf",
  });
  return c.json(urls);
});
