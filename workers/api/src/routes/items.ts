/** /v1/items — docs/api.md §5. Mounted by index.ts behind the auth middleware (sets c.var.userId). */
import {
  CreateItemRequest,
  ItemSource,
  LIMITS,
  ListItemsQuery,
  type Item,
  type Op,
  type ParseJob,
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
type UploadAbortReason = "too_large" | "not_pdf" | "length";
class UploadAbort extends Error {
  constructor(
    readonly reason: UploadAbortReason,
    state: { abort: UploadAbortReason | null },
  ) {
    super(reason);
    state.abort = reason; // errors crossing stream/R2 boundaries lose their identity; the caller reads this instead
  }
}

/** Counts bytes, enforces the size cap (and the declared length) while streaming and requires `%PDF-` within the first 1024 bytes. */
function pdfGuard(maxBytes: number, declared: number, state: { abort: UploadAbortReason | null }): TransformStream<Uint8Array, Uint8Array> {
  let total = 0;
  let head = new Uint8Array(0);
  let checked = false;
  let rejected = false;
  const check = (): void => {
    checked = true;
    // Latin-1 view of the head is enough for the ASCII marker.
    let text = "";
    for (const b of head) text += String.fromCharCode(b);
    // Not an error: the body keeps flowing (it is <= maxPdfBytes, declared) and the route sees state.abort after the
    // upload and deletes the object. Erroring/cancelling mid-body leaves the runtime's request stream unread, which
    // rejects unhandled ("client disconnected").
    if (!text.includes("%PDF-")) rejected = true;
  };
  return new TransformStream({
    transform(chunk, ctrl) {
      const before = total;
      total += chunk.byteLength;
      if (total > maxBytes) throw new UploadAbort("too_large", state);
      if (total > declared) {
        // Body longer than Content-Length: clip it and keep draining (a mid-body error leaves the runtime's request
        // stream unread, which rejects unhandled); the route answers 400 and deletes the object.
        state.abort ??= "length";
        chunk = chunk.subarray(0, Math.max(0, declared - before));
        if (chunk.byteLength === 0) return;
      }
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
      if (rejected) state.abort = "not_pdf"; // no throw: the stream completes normally; the caller checks the state
    },
  });
}

const hex = (buf: ArrayBuffer): string => [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");

/**
 * Display file name: control/format (bidi, zero-width) characters removed, `/ \\ :` replaced by `_`, trimmed, truncated
 * to maxFileNameLength keeping a trailing ".pdf" and never splitting a surrogate pair. Empty → "document.pdf".
 */
export function cleanFileName(raw: string): string {
  let name = raw
    // eslint-disable-next-line no-control-regex
    .replace(/[\u0000-\u001f\u007f]/g, "")
    .replace(/\p{Cf}/gu, "")
    .replace(/[/\\:]/g, "_")
    .trim();
  const max = LIMITS.maxFileNameLength;
  if (name.length > max) {
    const ext = /\.pdf$/i.test(name) ? name.slice(-4) : "";
    let cut = max - ext.length;
    const last = name.charCodeAt(cut - 1);
    if (last >= 0xd800 && last <= 0xdbff) cut--; // would leave a lone high surrogate
    name = name.slice(0, cut) + ext;
  }
  return name === "" ? "document.pdf" : name;
}

itemsRoutes.post("/pdf", async (c) => {
  const lenHeader = c.req.header("content-length");
  if (lenHeader === undefined || !/^\d+$/.test(lenHeader)) return apiError(c, 411, "length_required");
  const len = Number(lenHeader);
  if (len > LIMITS.maxPdfBytes) return apiError(c, 413, "payload_too_large");
  const ctype = (c.req.header("content-type") ?? "application/pdf").split(";")[0]!.trim().toLowerCase();
  if (ctype !== "application/pdf" && ctype !== "application/octet-stream") return apiError(c, 415, "unsupported_media_type");
  if ((c.req.query("name") ?? "").trim() === "") return apiError(c, 400, "invalid_request", "name_required");
  const name = cleanFileName(c.req.query("name")!);
  const tags = TagNames.safeParse(c.req.queries("tag") ?? []);
  if (!tags.success) return validationError(c, tags.error);
  const source = ItemSource.safeParse(c.req.query("source") ?? "api");
  if (!source.success) return validationError(c, source.error);
  if (!c.req.raw.body) return apiError(c, 415, "unsupported_media_type");

  const userId = c.var.userId;
  const contentId = uuidv7();
  const key = r2Keys.contentDir(contentId, userId) + PDF_FILE;
  const exec = (p: Promise<unknown>): void => c.executionCtx.waitUntil(p); // survives a client disconnect
  const removeObject = (k = key): Promise<void> =>
    c.env.CONTENT.delete(k).catch((e) => log.exception("pdf upload cleanup failed", e, { event: "pdf_cleanup_failed" }));
  const stub = library(c);

  // Reserve the content id first: an upload that is never committed (disconnect, failed delete) is reclaimed by the DO alarm.
  await stub.reservePdfUpload(contentId);

  // Stream into R2 and the SHA-256 digest at once; never buffer the file.
  let sha = "";
  let bodyPipe: Promise<void> = Promise.resolve();
  const guard: { abort: UploadAbortReason | null } = { abort: null };
  try {
    const guardStream = pdfGuard(LIMITS.maxPdfBytes, len, guard);
    // Own the pipe promise (pipeThrough would drop it): once the guard aborts, the rest of the request body
    // rejects with "client disconnected" and would surface as an uncaught exception.
    bodyPipe = c.req.raw.body.pipeTo(guardStream.writable).catch(() => {});
    const [forR2, forHash] = guardStream.readable.tee();
    const digest = new crypto.DigestStream("SHA-256");
    digest.digest.catch(() => {}); // rejects with the stream error; handled through `hashed` below
    const hashed = forHash.pipeTo(digest);
    const fixed = new FixedLengthStream(len);
    // Keep the pipe promise: when the guard aborts or the client disconnects it rejects, and nobody else awaits it.
    const piped = forR2.pipeTo(fixed.writable);
    const [put, hash, pipe] = await Promise.allSettled([
      c.env.CONTENT.put(key, fixed.readable, { httpMetadata: { contentType: "application/pdf" } }),
      hashed.then(() => digest.digest),
      piped,
    ]);
    if (put.status === "rejected") throw put.reason;
    if (hash.status === "rejected") throw hash.reason;
    if (pipe.status === "rejected") throw pipe.reason;
    if (guard.abort) throw new UploadAbort(guard.abort, guard);
    sha = hex(hash.value);
  } catch {
    await bodyPipe; // settle the body read before responding (else it surfaces as an uncaught "client disconnected")
    exec(removeObject());
    if (guard.abort === "too_large") return apiError(c, 413, "payload_too_large");
    if (guard.abort === "not_pdf") return apiError(c, 415, "unsupported_media_type");
    // A body shorter/longer than Content-Length, or a dropped connection.
    log.warn("pdf upload stream failed", { event: "pdf_upload_failed" });
    return apiError(c, 400, "invalid_request", "upload_failed");
  }

  const fileName = name;
  const req = {
    itemId: uuidv7(),
    url: `${c.env.APP_ORIGIN}/pdf/${sha}`,
    title: fileName.replace(/\.pdf$/i, "") || fileName,
    fileName,
    fileSize: len,
    contentId,
    tags: tags.data,
    source: source.data,
    at: Date.now(),
  };
  let result;
  try {
    result = await stub.addPdf(restDeviceId(c), req);
  } catch (e) {
    // Only a known pre-commit failure deletes the object. Anything else (RPC wire failure, a throw after the DO
    // committed) is an unknown outcome: keep the object; the reservation sweep reclaims it if no item references it.
    if (e instanceof Error && (e.name === "LibraryDestroyedError" || e.message === "library_destroyed")) exec(removeObject());
    else log.exception("pdf addPdf outcome unknown, object kept", e, { event: "pdf_commit_unknown" });
    throw e;
  }
  let response: { ok: true; item: Item; created: boolean; parseJobs: ParseJob[] } | { ok: false; error: string; message?: string } = result;
  if (result.ok && !result.created) {
    // Duplicate. If the existing item lost its original, adopt the new copy instead of discarding it.
    const oldId = result.item.contentId;
    let missing = result.item.kind !== "pdf" || !oldId;
    let known = true;
    if (!missing) {
      try {
        missing = (await c.env.CONTENT.head(r2Keys.contentDir(oldId!, userId) + PDF_FILE)) === null;
      } catch (e) {
        known = false; // cannot tell: keep both, never delete on a guess
        log.warnException("pdf duplicate head failed", e, { event: "pdf_dup_head_failed" });
      }
    }
    if (missing) {
      const fix = await stub.repointPdf(restDeviceId(c), { itemId: result.item.id, expectContentId: oldId, contentId, fileName, fileSize: len });
      if (fix.ok) response = { ok: true, item: fix.item, created: false, parseJobs: fix.parseJobs };
      else exec(removeObject());
    } else if (known) {
      exec(removeObject());
    }
  } else if (!result.ok) {
    exec(removeObject());
  }
  writeMetric(c.env.METRICS, { event: "save", blobs: [`pdf:${source.data}`, response.ok ? (response.created ? "ok" : "duplicate") : response.error] });
  if (!response.ok) {
    if (response.error === "storage_full") return apiError(c, 409, "storage_full");
    return apiError(c, 400, "invalid_request", response.message ?? response.error);
  }
  await enqueueParseJobs(c.env, response.parseJobs, userId);
  return c.json({ item: response.item, created: response.created }, 202);
});

// 5.9 PDF first-page preview (rendered by the uploading client)
const THUMB_FILES: Record<string, string> = { "image/webp": "thumb.webp", "image/jpeg": "thumb.jpg" };

function imageMatches(type: string, b: Uint8Array): boolean {
  if (type === "image/jpeg") return b.length >= 3 && b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff;
  const ascii = (from: number, to: number) => String.fromCharCode(...b.subarray(from, to));
  return b.length >= 12 && ascii(0, 4) === "RIFF" && ascii(8, 12) === "WEBP";
}

itemsRoutes.put("/:id/thumbnail", async (c) => {
  const id = c.req.param("id");
  const lenHeader = c.req.header("content-length");
  if (lenHeader === undefined || !/^\d+$/.test(lenHeader)) return apiError(c, 411, "length_required");
  if (Number(lenHeader) > LIMITS.maxThumbnailBytes) return apiError(c, 413, "payload_too_large");
  const ctype = (c.req.header("content-type") ?? "").split(";")[0]!.trim().toLowerCase();
  const file = THUMB_FILES[ctype];
  if (!file) return apiError(c, 415, "unsupported_media_type");
  if (!validItemId(id)) return apiError(c, 404, "not_found");
  const bytes = new Uint8Array(await c.req.arrayBuffer());
  if (bytes.byteLength > LIMITS.maxThumbnailBytes) return apiError(c, 413, "payload_too_large");
  if (!imageMatches(ctype, bytes)) return apiError(c, 415, "unsupported_media_type");

  const stub = library(c);
  const current = await stub.getItem(id);
  if (!current) return apiError(c, 404, "not_found");
  if (current.kind !== "pdf" || !current.contentId) return apiError(c, 409, "not_pdf");
  const dir = r2Keys.contentDir(current.contentId, c.var.userId);
  const remove = (k: string): Promise<void> =>
    c.env.CONTENT.delete(k).catch((e) => log.exception("thumbnail cleanup failed", e, { event: "thumb_cleanup_failed" }));
  await c.env.CONTENT.put(dir + file, bytes, { httpMetadata: { contentType: ctype } });
  const r = await stub.setPdfThumbnail(id, current.contentId, file);
  if (!r.ok) {
    // Deleted or re-pointed between the read and the commit: nothing references the object.
    await remove(dir + file);
    return apiError(c, 404, "not_found");
  }
  if (r.previousKey && r.previousKey !== file) c.executionCtx.waitUntil(remove(dir + r.previousKey));
  return c.json({ item: r.item });
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
