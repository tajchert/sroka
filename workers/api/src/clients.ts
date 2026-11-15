import type { MeResponse } from "@sroka/shared";
import { log } from "@sroka/shared";
import type { Env } from "./env.ts";

export type ClientKind = keyof NonNullable<MeResponse["clients"]>;
export const CLIENT_KINDS: readonly ClientKind[] = ["extension", "android"];

/** Extension: `X-Sroka-Device: ext-<uuid>`. Android: `User-Agent: Sroka-Android/<version>`. Else null (web, curl). */
export function clientKind(headers: Headers): ClientKind | null {
  if (headers.get("x-sroka-device")?.startsWith("ext-")) return "extension";
  if (headers.get("user-agent")?.startsWith("Sroka-Android/")) return "android";
  return null;
}

/**
 * `${userId}:${kind}` already recorded by this isolate, so steady-state requests make no DO call. Bounded
 * best-effort cache: cleared at SEEN_MAX, after which a pair may call the DO again (harmless, the DO write is once).
 */
const seen = new Set<string>();
const SEEN_MAX = 10_000;

/**
 * Records (write-once, in the user's LibraryDO) that `kind` made an authenticated request. Normally one DO
 * call per user+kind per isolate (see `seen`); runs in waitUntil so it never delays the response.
 */
export function noteClient(
  env: Pick<Env, "LIBRARY">,
  ctx: { waitUntil(p: Promise<unknown>): void },
  userId: string,
  kind: ClientKind,
): void {
  const key = `${userId}:${kind}`;
  if (seen.has(key)) return;
  if (seen.size >= SEEN_MAX) seen.clear();
  seen.add(key);
  ctx.waitUntil(
    (async () => {
      try {
        await env.LIBRARY.getByName(userId).noteClient(kind);
      } catch (e) {
        seen.delete(key);
        log.warnException("noteClient failed", e, { event: "note_client_failed", kind });
      }
    })(),
  );
}

/** Test hook: forget the isolate cache. */
export function resetSeenClients(): void {
  seen.clear();
}
