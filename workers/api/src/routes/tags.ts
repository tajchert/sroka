/** /v1/tags — docs/api.md §6. Mounted by index.ts behind the auth middleware (sets c.var.userId). */
import { RenameTagRequest, TagSuggestionsQuery, tryNormalizeUrl } from "@sroka/shared";
import { Hono } from "hono";
import { type LibraryAppEnv, apiError, library, readJson, restDeviceId, validItemId, validationError } from "../do/route-helpers.ts";

export const tagsRoutes = new Hono<LibraryAppEnv>();

tagsRoutes.get("/", async (c) => {
  return c.json({ tags: await library(c).listTags() });
});

tagsRoutes.get("/suggestions", async (c) => {
  const parsed = TagSuggestionsQuery.safeParse(c.req.query());
  const url = parsed.success ? parsed.data.url : undefined;
  const canonical = url ? tryNormalizeUrl(url) : null;
  return c.json(await library(c).suggestions(canonical));
});

tagsRoutes.patch("/:id", async (c) => {
  const id = c.req.param("id");
  if (!validItemId(id)) return apiError(c, 404, "not_found");
  const parsed = RenameTagRequest.safeParse(await readJson(c));
  if (!parsed.success) return validationError(c, parsed.error);
  const tag = await library(c).renameTag(restDeviceId(c), id, parsed.data.name, Date.now());
  if (!tag) return apiError(c, 404, "not_found");
  return c.json({ tag });
});

tagsRoutes.delete("/:id", async (c) => {
  const id = c.req.param("id");
  if (!validItemId(id)) return apiError(c, 404, "not_found");
  const ok = await library(c).deleteTag(restDeviceId(c), id, Date.now());
  if (!ok) return apiError(c, 404, "not_found");
  return c.body(null, 204);
});
