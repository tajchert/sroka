import { ImportFormat, LIMITS, uuidv7 } from "@sroka/shared";
import { Hono } from "hono";
import type { AppEnv } from "../env.ts";
import { countRecentImports, getJob, insertJob, updateJob } from "../import/jobs.ts";
import type { ImportParams } from "../import/workflow.ts";

/** POST /v1/imports, GET /v1/imports/:id (api.md §11.1). Mounted at /v1/imports. */
export const importsRoutes = new Hono<AppEnv>();

const DAILY_LIMIT = 10;
const DAY_MS = 24 * 60 * 60 * 1000;

function ext(format: ImportFormat, bytes: Uint8Array): string {
  if (format === "pocket_csv") return bytes[0] === 0x50 && bytes[1] === 0x4b ? "zip" : "csv";
  if (format === "instapaper_csv") return "csv";
  return "html";
}

importsRoutes.post("/", async (c) => {
  const ctype = c.req.header("content-type") ?? "";
  if (!ctype.toLowerCase().startsWith("multipart/form-data")) {
    return c.json({ error: "unsupported_media_type", message: "multipart/form-data required" }, 415);
  }
  const len = Number(c.req.header("content-length") ?? "0");
  // Multipart overhead is tiny; reject clearly oversized bodies before buffering.
  if (len > LIMITS.maxImportBytes + 64 * 1024) return c.json({ error: "payload_too_large" }, 413);

  let form: FormData;
  try {
    form = await c.req.formData();
  } catch {
    return c.json({ error: "invalid_body", message: "malformed multipart body" }, 400);
  }
  const format = ImportFormat.safeParse(form.get("format"));
  if (!format.success) return c.json({ error: "invalid_format", message: `format must be one of ${ImportFormat.options.join(", ")}` }, 400);
  const file = form.get("file");
  if (file === null || typeof file === "string") return c.json({ error: "missing_file" }, 400);
  if (file.size > LIMITS.maxImportBytes) return c.json({ error: "payload_too_large" }, 413);
  if (file.size === 0) return c.json({ error: "empty_file" }, 400);

  const userId = c.var.userId;
  const now = Date.now();
  if ((await countRecentImports(c.env.DB, userId, now - DAY_MS)) >= DAILY_LIMIT) {
    return c.json({ error: "rate_limited", message: "10 imports per day" }, 429, { "Retry-After": "3600" });
  }

  const bytes = new Uint8Array(await file.arrayBuffer());
  const id = uuidv7();
  const uploadKey = `uploads/${userId}/${id}.${ext(format.data, bytes)}`;
  await c.env.CONTENT.put(uploadKey, bytes);
  await insertJob(c.env.DB, { id, userId, format: format.data, now });

  const params: ImportParams = { userId, importId: id, format: format.data, uploadKey, startedAt: now };
  try {
    await c.env.IMPORT_WORKFLOW.create({ id, params });
  } catch (e) {
    console.error("[sroka] import workflow create failed", e);
    await updateJob(c.env.DB, id, { status: "failed", error: "workflow_unavailable" });
    await c.env.CONTENT.delete(uploadKey);
    return c.json({ error: "unavailable", message: "could not start the import" }, 503);
  }
  const job = await getJob(c.env.DB, userId, id);
  return c.json({ job }, 202);
});

importsRoutes.get("/:id", async (c) => {
  const job = await getJob(c.env.DB, c.var.userId, c.req.param("id"));
  if (!job) return c.json({ error: "not_found" }, 404);
  return c.json({ job });
});
