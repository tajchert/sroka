import { DurableObject } from "cloudflare:workers";
import type { Env } from "./env.ts";

/** Per-user library (SQLite DO). Schema: design §7.1; all mutations via applyOps (decisions D5). Placeholder. */
export class LibraryDO extends DurableObject<Env> {
  ping(): string {
    return "pong";
  }
}
