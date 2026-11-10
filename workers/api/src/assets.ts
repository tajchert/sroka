import type { Env } from "./env.ts";

/**
 * Headers for everything served from static assets. HTML documents must never be framed by another site
 * (the app uses cookie auth); a full script/style CSP is not set here.
 */
function withSecurityHeaders(res: Response): Response {
  // Asset responses can be immutable; copy before changing headers.
  const out = new Response(res.body, res);
  out.headers.set("X-Content-Type-Options", "nosniff");
  out.headers.set("Referrer-Policy", "strict-origin-when-cross-origin");
  if ((out.headers.get("content-type") ?? "").toLowerCase().startsWith("text/html")) {
    out.headers.set("Content-Security-Policy", "frame-ancestors 'none'");
    out.headers.set("X-Frame-Options", "DENY");
  }
  return out;
}

/** Serve a static asset; on 404 for /app/* fall back to the SPA shell (D8). */
export async function serveAsset(req: Request, env: Env): Promise<Response> {
  const res = await env.ASSETS.fetch(req);
  const { pathname } = new URL(req.url);
  if (res.status === 404 && (pathname === "/app" || pathname.startsWith("/app/")) && (req.method === "GET" || req.method === "HEAD")) {
    const shell = new URL("/app/", req.url);
    return withSecurityHeaders(await env.ASSETS.fetch(new Request(shell, { method: req.method, headers: req.headers })));
  }
  return withSecurityHeaders(res);
}
