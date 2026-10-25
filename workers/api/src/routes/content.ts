import { verifyContentPath } from "@sroka/shared";
import type { Env } from "../env.ts";
import { devOrigins } from "../auth.ts";

const TYPES: Record<string, string> = {
  html: "text/html; charset=utf-8",
  txt: "text/plain; charset=utf-8",
  webp: "image/webp",
  jpg: "image/jpeg",
  zip: "application/zip",
  json: "application/json",
  pdf: "application/pdf",
};

/** CSP of `.pdf` responses: no `sandbox` (it stops Chrome's PDF viewer). Final value pending a Chrome check. */
export const PDF_CSP = "default-src 'none'; object-src 'none'; frame-ancestors 'none'";

function baseHeaders(env: Env, req: Request): Headers {
  const h = new Headers();
  h.set("Vary", "Origin");
  h.set("X-Content-Type-Options", "nosniff");
  h.set("Content-Security-Policy", "default-src 'none'; img-src 'self' data:; style-src 'unsafe-inline'; sandbox");
  const origin = req.headers.get("Origin");
  if (origin && (origin === env.APP_ORIGIN || devOrigins(env).includes(origin))) {
    h.set("Access-Control-Allow-Origin", origin);
  }
  return h;
}

function err(env: Env, req: Request, status: number, error: string, message?: string): Response {
  const h = baseHeaders(env, req);
  h.set("Content-Type", "application/json");
  h.set("Cache-Control", "no-store");
  return new Response(JSON.stringify(message ? { error, message } : { error }), { status, headers: h });
}

/** Content host handler (api.md §10, D7). Cookieless; the signature in the path is the credential. */
export async function handleContent(req: Request, env: Env): Promise<Response> {
  const url = new URL(req.url);
  if (req.method === "OPTIONS") {
    const h = baseHeaders(env, req);
    h.set("Access-Control-Allow-Methods", "GET, HEAD, OPTIONS");
    h.set("Access-Control-Max-Age", "600");
    return new Response(null, { status: 204, headers: h });
  }
  if (!url.pathname.startsWith("/s/")) return err(env, req, 404, "not_found");
  if (req.method !== "GET" && req.method !== "HEAD") {
    const r = err(env, req, 405, "method_not_allowed");
    r.headers.set("Allow", "GET, HEAD, OPTIONS");
    return r;
  }
  const v = await verifyContentPath(env.CONTENT_URL_SIGNING_KEY, url.pathname);
  if (!v.ok) return err(env, req, 403, "forbidden", v.reason);

  const obj = req.method === "HEAD" ? await env.CONTENT.head(v.r2Key) : await env.CONTENT.get(v.r2Key);
  if (!obj) return err(env, req, 404, "not_found");

  const h = baseHeaders(env, req);
  const ext = v.file.split(".").pop()?.toLowerCase() ?? "";
  h.set("Content-Type", TYPES[ext] ?? obj.httpMetadata?.contentType ?? "application/octet-stream");
  if (ext === "pdf") {
    // PDFs are shown by the browser's viewer when the signed URL is opened directly, which the HTML CSP's `sandbox`
    // would block. The content host is cookieless and serves the file as an inert application/pdf (nosniff).
    h.set("Content-Disposition", 'inline; filename="document.pdf"');
    h.set("Content-Security-Policy", PDF_CSP);
  }
  h.set("Cache-Control", v.isPrivate ? "private, no-store" : "public, max-age=86400, immutable");
  h.set("ETag", obj.httpEtag);

  const inm = req.headers.get("If-None-Match");
  if (inm && inm.split(",").some((t) => t.trim() === obj.httpEtag || t.trim() === `W/${obj.httpEtag}`)) {
    if ("body" in obj) await (obj as R2ObjectBody).body.cancel();
    return new Response(null, { status: 304, headers: h });
  }
  h.set("Content-Length", String(obj.size));
  if (req.method === "HEAD" || !("body" in obj)) return new Response(null, { status: 200, headers: h });
  return new Response((obj as R2ObjectBody).body, { status: 200, headers: h });
}
