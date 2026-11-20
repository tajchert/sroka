/**
 * Silent "sync" push (decisions D17, docs/api.md §17): FCM HTTP v1 for Android, APNs direct for iOS.
 * Credentials are optional secrets; a platform without them is skipped (one warn log per isolate).
 */
import { log } from "@sroka/shared";
import type { Env } from "../env.ts";
import { ApnsSender, resetApnsCache } from "./apns.ts";
import { FcmSender, parseServiceAccount, resetFcmCache } from "./fcm.ts";
import type { Fetch } from "./jwt.ts";
import { type Alive, PUSH_FETCH_TIMEOUT_MS, type PushDevice, type SendOutcome } from "./types.ts";

export type { PushDevice, SendOutcome } from "./types.ts";
export type { Fetch } from "./jwt.ts";

export type PushConfig = Pick<Env, "FCM_SERVICE_ACCOUNT" | "APNS_KEY" | "APNS_KEY_ID" | "APNS_TEAM_ID">;

export interface PushReport {
  fcm: number;
  apns: number;
  pruned: number;
  failed: number;
  skipped: number;
  /** Per device, in input order. */
  outcomes: { device: PushDevice; outcome: SendOutcome }[];
}

const warned = new Set<string>();

function warnMissing(platform: "fcm" | "apns"): void {
  if (warned.has(platform)) return;
  warned.add(platform);
  log.warn("push credentials missing, platform skipped", { event: "push_config_missing", platform });
}

/** Test hook: clears the per-isolate token caches and the missing-config warn flags. */
export function resetPushState(): void {
  warned.clear();
  resetFcmCache();
  resetApnsCache();
}

export class PushSender {
  private readonly fcm: FcmSender | null;
  private readonly apns: ApnsSender | null;

  constructor(
    cfg: PushConfig,
    fetchImpl: Fetch = (input, init) => fetch(input, init),
    now: () => number = Date.now,
    timeoutMs: number = PUSH_FETCH_TIMEOUT_MS,
  ) {
    const sa = parseServiceAccount(cfg.FCM_SERVICE_ACCOUNT);
    this.fcm = sa ? new FcmSender(sa, fetchImpl, now, timeoutMs) : null;
    this.apns =
      cfg.APNS_KEY && cfg.APNS_KEY_ID && cfg.APNS_TEAM_ID
        ? new ApnsSender({ key: cfg.APNS_KEY, keyId: cfg.APNS_KEY_ID, teamId: cfg.APNS_TEAM_ID }, fetchImpl, now, timeoutMs)
        : null;
  }

  private sendOne(d: PushDevice, alive: Alive): Promise<SendOutcome> {
    if (!alive()) return Promise.resolve({ status: "skipped" });
    if (d.platform === "fcm") {
      if (!this.fcm) {
        warnMissing("fcm");
        return Promise.resolve({ status: "skipped" });
      }
      return this.fcm.send(d.token, alive);
    }
    if (!this.apns) {
      warnMissing("apns");
      return Promise.resolve({ status: "skipped" });
    }
    if (!d.apnsEnv || !d.apnsTopic) return Promise.resolve({ status: "prune", reason: "incomplete_row" });
    return this.apns.send(d.token, d.apnsEnv, d.apnsTopic, alive);
  }

  /**
   * Sends one sync push to each device. Never throws. Every provider/OAuth request has a deadline; `alive` is
   * checked before each provider request (a destroyed library stops sending).
   */
  async send(devices: readonly PushDevice[], alive: Alive = () => true): Promise<PushReport> {
    const outcomes = await Promise.all(
      devices.map(async (device) => {
        let outcome: SendOutcome;
        try {
          outcome = await this.sendOne(device, alive);
        } catch {
          outcome = { status: "failed", reason: "exception" };
        }
        return { device, outcome };
      }),
    );
    const report: PushReport = { fcm: 0, apns: 0, pruned: 0, failed: 0, skipped: 0, outcomes };
    for (const { device, outcome } of outcomes) {
      if (outcome.status === "sent") report[device.platform]++;
      else if (outcome.status === "prune") report.pruned++;
      else if (outcome.status === "failed") report.failed++;
      else report.skipped++;
    }
    return report;
  }
}
