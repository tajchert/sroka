import { Hono } from "hono";
import type { Env } from "./env.ts";

export { LibraryDO } from "./library-do.ts";

const app = new Hono<{ Bindings: Env }>();
app.get("/v1/health", (c) => c.json({ ok: true }));

export default app;
