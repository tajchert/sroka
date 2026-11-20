/**
 * FCM HTTP v1 sender (Android `play` flavor). Auth: service-account JWT (RS256) exchanged at Google's OAuth token
 * endpoint; the access token is cached per isolate until 5 minutes before it expires.
 */
import { log } from "@sroka/shared";
import { type Fetch, importSigningKey, signJwt } from "./jwt.ts";
import { type Alive, PUSH_FETCH_TIMEOUT_MS, PUSH_TTL_S, type SendOutcome } from "./types.ts";

const SCOPE = "https://www.googleapis.com/auth/firebase.messaging";
const DEFAULT_TOKEN_URI = "https://oauth2.googleapis.com/token";
const REFRESH_EARLY_MS = 5 * 60 * 1000;

export interface ServiceAccount {
  project_id: string;
  client_email: string;
  private_key: string;
  token_uri?: string;
}

/** Parses the `FCM_SERVICE_ACCOUNT` secret (the whole JSON key file); null when unusable. */
export function parseServiceAccount(json: string | undefined): ServiceAccount | null {
  if (!json) return null;
  try {
    const v = JSON.parse(json) as Partial<ServiceAccount>;
    if (typeof v.project_id !== "string" || typeof v.client_email !== "string" || typeof v.private_key !== "string") return null;
    return { project_id: v.project_id, client_email: v.client_email, private_key: v.private_key, token_uri: typeof v.token_uri === "string" ? v.token_uri : undefined };
  } catch {
    return null;
  }
}

type Cached = { token: string; exp: number };
/** Per-isolate access-token cache, keyed by service-account email. */
const tokenCache = new Map<string, Cached>();
const inflight = new Map<string, Promise<string>>();

export function resetFcmCache(): void {
  tokenCache.clear();
  inflight.clear();
}

/** FCM v1 message body for the silent sync push (docs/api.md §17). */
export function fcmMessage(token: string): unknown {
  return { message: { token, data: { type: "sync" }, android: { priority: "HIGH", collapse_key: "sync", ttl: `${PUSH_TTL_S}s` } } };
}

type FcmError = { error?: { status?: string; message?: string; details?: { errorCode?: string }[] } };

export class FcmSender {
  constructor(
    private readonly sa: ServiceAccount,
    private readonly fetchImpl: Fetch,
    private readonly now: () => number = Date.now,
    private readonly timeoutMs: number = PUSH_FETCH_TIMEOUT_MS,
  ) {}

  private accessToken(): Promise<string> {
    const key = this.sa.client_email;
    const hit = tokenCache.get(key);
    if (hit && hit.exp - REFRESH_EARLY_MS > this.now()) return Promise.resolve(hit.token);
    let p = inflight.get(key);
    if (!p) {
      p = this.fetchAccessToken().finally(() => inflight.delete(key));
      inflight.set(key, p);
    }
    return p;
  }

  private async fetchAccessToken(): Promise<string> {
    const aud = this.sa.token_uri ?? DEFAULT_TOKEN_URI;
    const iat = Math.floor(this.now() / 1000);
    const jwt = await signJwt(await importSigningKey(this.sa.private_key, "RS256"), "RS256", {}, {
      iss: this.sa.client_email,
      scope: SCOPE,
      aud,
      iat,
      exp: iat + 3600,
    });
    const res = await this.fetchImpl(aud, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion: jwt }).toString(),
      signal: AbortSignal.timeout(this.timeoutMs),
    });
    if (!res.ok) throw new Error(`fcm oauth ${res.status}`);
    const data = (await res.json()) as { access_token?: string; expires_in?: number };
    if (!data.access_token) throw new Error("fcm oauth: no access_token");
    tokenCache.set(this.sa.client_email, { token: data.access_token, exp: this.now() + (data.expires_in ?? 3600) * 1000 });
    return data.access_token;
  }

  async send(token: string, alive: Alive = () => true): Promise<SendOutcome> {
    let access: string;
    try {
      access = await this.accessToken();
    } catch (e) {
      log.warnException("fcm access token failed", e, { event: "push_auth_failed", platform: "fcm" });
      return { status: "failed", reason: "auth" };
    }
    if (!alive()) return { status: "skipped" };
    let res: Response;
    let err: FcmError = {};
    try {
      res = await this.fetchImpl(`https://fcm.googleapis.com/v1/projects/${encodeURIComponent(this.sa.project_id)}/messages:send`, {
        method: "POST",
        headers: { authorization: `Bearer ${access}`, "content-type": "application/json" },
        body: JSON.stringify(fcmMessage(token)),
        signal: AbortSignal.timeout(this.timeoutMs),
      });
      if (res.ok) {
        await res.body?.cancel();
        return { status: "sent" };
      }
      const text = await res.text();
      try {
        err = JSON.parse(text) as FcmError;
      } catch {
        // non-JSON error body
      }
    } catch (e) {
      return { status: "failed", reason: e instanceof Error && e.name === "TimeoutError" ? "timeout" : "network" };
    }
    const codes = (err.error?.details ?? []).map((d) => d.errorCode).filter(Boolean);
    if (res.status === 404 || codes.includes("UNREGISTERED")) return { status: "prune", reason: "unregistered" };
    if (res.status === 400 && (err.error?.status === "INVALID_ARGUMENT" || codes.includes("INVALID_ARGUMENT"))) {
      // The message itself is fixed, so an INVALID_ARGUMENT that names the token means the token is malformed.
      if (/token/i.test(err.error?.message ?? "")) return { status: "prune", reason: "invalid_token" };
    }
    if (res.status === 401) tokenCache.delete(this.sa.client_email);
    return { status: "failed", reason: codes[0] ?? err.error?.status ?? `http_${res.status}` };
  }
}
