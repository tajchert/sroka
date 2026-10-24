import { EXPORT_CSV_COLUMNS, ExportQuery, type ExportJson, type Item } from "@sroka/shared";
import { Hono } from "hono";
import type { AppEnv } from "../env.ts";
import { csvField } from "../import/csv.ts";

/** GET /v1/exports?format=csv|json (api.md §11.2). Mounted at /v1/exports. */
export const exportsRoutes = new Hono<AppEnv>();

const enc = new TextEncoder();

type ExportItem = Omit<Item, "leadImageUrl">;

/** Neutralises spreadsheet formula injection: a leading = + - @ TAB CR gets a `'` prefix (the importer strips it). */
export function csvSafe(v: string): string {
  return /^[=+\-@\t\r]/.test(v) ? "'" + v : v;
}

function tagsCell(tags: string[]): string {
  // Tags are joined with `|`. A lone tag containing a comma gets a trailing `|` so the importer doesn't split it on commas.
  const cell = tags.map((t) => t.replace(/\|/g, "/")).join("|");
  return tags.length === 1 && cell.includes(",") ? cell + "|" : cell;
}

export function csvRow(i: ExportItem): string {
  return (
    [
      csvSafe(i.title ?? ""),
      i.url,
      String(Math.floor(i.savedAt / 1000)),
      csvSafe(tagsCell(i.tags)),
      i.status === "archived" ? "archive" : "unread",
      i.isFavorite ? "1" : "0",
    ]
      .map(csvField)
      .join(",") + "\r\n"
  );
}

export function exportJsonItem(i: ExportItem): ExportJson["items"][number] & Pick<ExportItem, "kind" | "fileName" | "fileSize"> {
  return {
    kind: i.kind,
    fileName: i.fileName,
    fileSize: i.fileSize,
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
  const stub = c.env.LIBRARY.getByName(c.var.userId);

  const date = new Date(now).toISOString().slice(0, 10);
  const headers = {
    "Content-Disposition": `attachment; filename="sroka-export-${date}.${format}"`,
    "Cache-Control": "private, no-store",
    "X-Content-Type-Options": "nosniff",
  };

  // Stream one DO page per pull (newest first); nothing but the current page is held in memory.
  const PAGE = 500;
  let after: { savedAt: number; id: string } | null = null;
  let first = true;
  const body = new ReadableStream<Uint8Array>({
    async pull(ctrl) {
      const page: ExportItem[] = await stub.exportPage(after, PAGE);
      let out = "";
      if (format === "csv") {
        if (first) out += EXPORT_CSV_COLUMNS.join(",") + "\r\n";
        for (const i of page) out += csvRow(i);
      } else {
        if (first) out += `{"format":"sroka-export","version":1,"exportedAt":${now},"items":[`;
        out += page.map((i) => JSON.stringify(exportJsonItem(i))).join(",");
        if (!first && page.length > 0) out = "," + out;
      }
      const done = page.length < PAGE;
      if (format === "json" && done) out += "]}";
      first = false;
      if (page.length > 0) after = { savedAt: page[page.length - 1]!.savedAt, id: page[page.length - 1]!.id };
      if (out) ctrl.enqueue(enc.encode(out));
      if (done) ctrl.close();
    },
  });
  return new Response(body, {
    headers: {
      ...headers,
      "Content-Type": format === "csv" ? "text/csv; charset=utf-8" : "application/json",
    },
  });
});
