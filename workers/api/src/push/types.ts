import type { ApnsEnvironment, PushPlatform } from "@sroka/shared";

/** One row of the LibraryDO `push_devices` table. */
export interface PushDevice {
  deviceId: string;
  platform: PushPlatform;
  token: string;
  /** APNs only. */
  apnsEnv: ApnsEnvironment | null;
  /** APNs only (bundle id). */
  apnsTopic: string | null;
  /** Row revision at snapshot time; prune/env updates only apply while it is unchanged. */
  updatedAt: number;
}

/** Returns false once the sends should stop (e.g. the library was destroyed meanwhile). */
export type Alive = () => boolean;

/** Per provider/OAuth request deadline (headers + body). */
export const PUSH_FETCH_TIMEOUT_MS = 10_000;

/**
 * Result of one send. `prune` = the token is dead (delete the row). `apnsEnv` on `sent` = delivered only after
 * switching APNs environment (store the new one). `failed` = transient/config problem, keep the row.
 */
export type SendOutcome =
  | { status: "sent"; apnsEnv?: ApnsEnvironment }
  | { status: "prune"; reason: string }
  | { status: "failed"; reason: string }
  | { status: "skipped" };

/** How long a sync push stays useful (FCM ttl / APNs expiration), seconds. */
export const PUSH_TTL_S = 12 * 60 * 60;
