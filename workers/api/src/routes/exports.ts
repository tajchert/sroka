import { EXPORT_CSV_COLUMNS, ExportQuery, type ExportJson, type Item } from "@sroka/shared";
import { Hono } from "hono";
import type { AppEnv } from "../env.ts";
import { csvField } from "../import/csv.ts";

/** GET /v1/exports?format=csv|json (api.md §11.2). Mounted at /v1/exports. */
export const exportsRoutes = new Hono<AppEnv>();

const enc = new TextEncoder();

export function csvRow(i: Item): string {
  return (
    [
      i.title ?? "",
      i.url,
      String(Math.floor(i.savedAt / 1000)),
      i.tags.join("|"),
      i.status === "archived" ? "archive" : "unread",
      i.isFavorite ? "1" : "0",
    ]
      .map(csvField)
      .join(",") + "\r\n"
  );
}

export function exportJsonItem(i: Item): ExportJson["items"][number] {
  return {
    url: i.url,
    title: i.title,
    status: i.status,
    isFavorite: i.isFavorite,
    tags: i.tags,
    savedAt: i.savedAt,
    archivedAt: i.archivedAt,
    excerpt: i.excerpt,
    siteName: i.siteName,
    wordCount: i.wordCount,
    progress: i.progress,
  };
}

exportsRoutes.get("/", async (c) => {
  const q = ExportQuery.safeParse({ format: c.req.query("format") || undefined });
  if (!q.success) return c.json({ error: "invalid_format", message: "format must be csv or json" }, 400);
  const format = q.data.format;
  const now = Date.now();
  // Exports are newest first; the DO returns savedAt ascending.
  const items = (await c.env.LIBRARY.getByName(c.var.userId).exportItems()).reverse();

  const date = new Date(now).toISOString().slice(0, 10);
  const headers = {
    "Content-Disposition": `attachment; filename="sroka-export-${date}.${format}"`,
    "Cache-Control": "private, no-store",
    "X-Content-Type-Options": "nosniff",
  };

  // Stream in slices so large libraries don't build one giant string.
  let idx = 0;
  const SLICE = 500;
  let first = true;
  const body = new ReadableStream<Uint8Array>({
    pull(ctrl) {
      let out = "";
      if (format === "csv") {
        if (first) out += EXPORT_CSV_COLUMNS.join(",") + "\r\n";
        for (const i of items.slice(idx, idx + SLICE)) out += csvRow(i);
        idx += SLICE;
        first = false;
        ctrl.enqueue(enc.encode(out));
        if (idx >= items.length) ctrl.close();
      } else {
        if (first) out += `{"format":"sroka-export","version":1,"exportedAt":${now},"items":[`;
        const slice = items.slice(idx, idx + SLICE);
        out += slice.map((i) => JSON.stringify(exportJsonItem(i))).join(",");
        if (idx > 0 && slice.length > 0) out = "," + out;
        idx += SLICE;
        first = false;
        if (idx >= items.length) out += "]}";
        ctrl.enqueue(enc.encode(out));
        if (idx >= items.length) ctrl.close();
      }
    },
  });
  return new Response(body, {
    headers: {
      ...headers,
      "Content-Type": format === "csv" ? "text/csv; charset=utf-8" : "application/json",
    },
  });
});
