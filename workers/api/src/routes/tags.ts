import { Hono } from "hono";
import type { AppEnv } from "../env.ts";

// STUB (platform agent): replaced by the real implementation at merge. Mounted at /v1/tags.
export const tagsRoutes = new Hono<AppEnv>();
