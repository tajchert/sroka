/** GET /pdf/:sha256 on the app host — the item URL of an uploaded PDF as a working "open original" link (api.md §5.8). */
import { ListItemsQuery, buildContentUrls, contentScope, normalizeUrl } from "@sroka/shared";
import { Hono } from "hono";
import { createAuth } from "../auth.ts";
import type { AppEnv } from "../env.ts";

export const pdfLinkRoutes = new Hono<AppEnv>();

pdfLinkRoutes.get("/:sha", async (c) => {
  const sha = c.req.param("sha");
  const headers = { "Cache-Control": "private, no-store" };
  if (!/^[0-9a-f]{64}$/.test(sha)) return c.json({ error: "not_found" }, 404, headers);
  const session = await createAuth(c.env, c.executionCtx).api.getSession({ headers: c.req.raw.headers });
  if (!session) return new Response(null, { status: 302, headers: { ...headers, Location: "/app/" } });

  const userId = session.user.id;
  const canonical = normalizeUrl(`${c.env.APP_ORIGIN}/pdf/${sha}`);
  const r = await c.env.LIBRARY.getByName(userId).listItems(ListItemsQuery.parse({ url: canonical }), canonical);
  const item = r.ok ? r.items[0] : undefined;
  if (!item || item.kind !== "pdf" || !item.contentId) return c.json({ error: "not_found" }, 404, headers);
  const urls = await buildContentUrls({
    origin: c.env.CONTENT_ORIGIN,
    secret: c.env.CONTENT_URL_SIGNING_KEY,
    scope: contentScope(item.contentPrivate, userId),
    contentId: item.contentId,
    pdf: true,
  });
  return new Response(null, { status: 302, headers: { ...headers, Location: urls.documentUrl! } });
});
