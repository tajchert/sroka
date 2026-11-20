/**
 * APNs sender (iOS, HTTP/2 via plain fetch — verified from the Workers edge). Auth: ES256 provider JWT from the
 * `.p8` key (`iss` = team id, `kid` = key id), reused for 40 minutes (Apple: refresh between 20 and 60 minutes).
 */
import type { ApnsEnvironment } from "@sroka/shared";
import { type Fetch, importSigningKey, signJwt } from "./jwt.ts";
import { PUSH_TTL_S, type SendOutcome } from "./types.ts";

const JWT_REUSE_MS = 40 * 60 * 1000;

export const APNS_HOSTS: Record<ApnsEnvironment, string> = {
  sandbox: "https://api.sandbox.push.apple.com",
  production: "https://api.push.apple.com",
};

export interface ApnsConfig {
  key: string;
  keyId: string;
  teamId: string;
}

type Cached = { jwt: string; at: number };
/** Per-isolate provider-token cache, keyed by team + key id. */
const jwtCache = new Map<string, Cached>();

export function resetApnsCache(): void {
  jwtCache.clear();
}

export const APNS_BODY = JSON.stringify({ aps: { "content-available": 1 }, type: "sync" });

const other = (env: ApnsEnvironment): ApnsEnvironment => (env === "sandbox" ? "production" : "sandbox");

type Attempt = { status: number; reason: string } | { status: 0; reason: "network" };

export class ApnsSender {
  constructor(
    private readonly cfg: ApnsConfig,
    private readonly fetchImpl: Fetch,
    private readonly now: () => number = Date.now,
  ) {}

  private get cacheKey(): string {
    return `${this.cfg.teamId}:${this.cfg.keyId}`;
  }

  private async providerToken(): Promise<string> {
    const hit = jwtCache.get(this.cacheKey);
    if (hit && this.now() - hit.at < JWT_REUSE_MS) return hit.jwt;
    const at = this.now();
    const jwt = await signJwt(await importSigningKey(this.cfg.key, "ES256"), "ES256", { kid: this.cfg.keyId }, {
      iss: this.cfg.teamId,
      iat: Math.floor(at / 1000),
    });
    jwtCache.set(this.cacheKey, { jwt, at });
    return jwt;
  }

  private async post(env: ApnsEnvironment, token: string, topic: string, jwt: string): Promise<Attempt> {
    let res: Response;
    try {
      res = await this.fetchImpl(`${APNS_HOSTS[env]}/3/device/${token}`, {
        method: "POST",
        headers: {
          authorization: `bearer ${jwt}`,
          "apns-push-type": "background",
          "apns-priority": "5",
          "apns-topic": topic,
          "apns-collapse-id": "sync",
          "apns-expiration": String(Math.floor(this.now() / 1000) + PUSH_TTL_S),
          "content-type": "application/json",
        },
        body: APNS_BODY,
      });
    } catch {
      return { status: 0, reason: "network" };
    }
    if (res.status === 200) {
      await res.body?.cancel();
      return { status: 200, reason: "" };
    }
    let reason = "";
    try {
      reason = ((await res.json()) as { reason?: string }).reason ?? "";
    } catch {
      // non-JSON error body
    }
    return { status: res.status, reason };
  }

  private dead(a: Attempt): boolean {
    return a.status === 410 || (a.status === 400 && (a.reason === "BadDeviceToken" || a.reason === "DeviceTokenNotForTopic"));
  }

  async send(token: string, env: ApnsEnvironment, topic: string): Promise<SendOutcome> {
    let jwt: string;
    try {
      jwt = await this.providerToken();
    } catch {
      return { status: "failed", reason: "auth" };
    }
    const first = await this.post(env, token, topic, jwt);
    if (first.status === 200) return { status: "sent" };
    if (first.status === 400 && first.reason === "BadDeviceToken") {
      // A dev build's token sent to production (or vice versa) reads as BadDeviceToken: try the other host once.
      const alt = other(env);
      const second = await this.post(alt, token, topic, jwt);
      if (second.status === 200) return { status: "sent", apnsEnv: alt };
      if (this.dead(second)) return { status: "prune", reason: "BadDeviceToken" };
      return this.failed(second);
    }
    if (this.dead(first)) return { status: "prune", reason: first.status === 410 ? "Unregistered" : first.reason };
    return this.failed(first);
  }

  private failed(a: Attempt): SendOutcome {
    if (a.status === 403 && (a.reason === "ExpiredProviderToken" || a.reason === "InvalidProviderToken")) jwtCache.delete(this.cacheKey);
    return { status: "failed", reason: a.reason || (a.status === 0 ? "network" : `http_${a.status}`) };
  }
}
