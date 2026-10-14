import type { Env } from "./env.ts";

/** Serve a static asset; on 404 for /app/* fall back to the SPA shell (D8). */
export async function serveAsset(req: Request, env: Env): Promise<Response> {
  const res = await env.ASSETS.fetch(req);
  const { pathname } = new URL(req.url);
  if (res.status === 404 && (pathname === "/app" || pathname.startsWith("/app/")) && (req.method === "GET" || req.method === "HEAD")) {
    const shell = new URL("/app/", req.url);
    return env.ASSETS.fetch(new Request(shell, { method: req.method, headers: req.headers }));
  }
  return res;
}
