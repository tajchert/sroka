/** LibraryDO `push_devices` (schema v7, decisions D17, api.md §17). */
import type { ApnsEnvironment, PushTokenRequest } from "@sroka/shared";
import type { PushDevice } from "../push/types.ts";

/** Max registered phones per library; the least recently updated rows beyond it are dropped. */
export const MAX_PUSH_DEVICES = 10;

type Row = { device_id: string; platform: string; token: string; apns_env: string | null; apns_topic: string | null; updated_at: number };

/**
 * Upsert keyed by device id; the same token under another device id is dropped (reinstall / id reset). APNs tokens
 * are hex and stored lowercase so casing can't bypass the dedupe. `updated_at` strictly increases per row: it is the
 * revision that guards prune/env updates from a send that started before this registration.
 */
export function putPushDevice(storage: DurableObjectStorage, deviceId: string, req: PushTokenRequest, now: number): void {
  const sql = storage.sql;
  const token = req.platform === "apns" ? req.token.toLowerCase() : req.token;
  const apnsEnv = req.platform === "apns" ? req.apnsEnvironment : null;
  const apnsTopic = req.platform === "apns" ? req.apnsTopic : null;
  storage.transactionSync(() => {
    sql.exec("DELETE FROM push_devices WHERE token = ? AND device_id <> ?", token, deviceId);
    sql.exec(
      `INSERT INTO push_devices (device_id, platform, token, apns_env, apns_topic, updated_at) VALUES (?, ?, ?, ?, ?, ?)
       ON CONFLICT(device_id) DO UPDATE SET platform = excluded.platform, token = excluded.token, apns_env = excluded.apns_env,
         apns_topic = excluded.apns_topic, updated_at = MAX(excluded.updated_at, push_devices.updated_at + 1)`,
      deviceId,
      req.platform,
      token,
      apnsEnv,
      apnsTopic,
      now,
    );
    sql.exec(
      `DELETE FROM push_devices WHERE device_id IN (
         SELECT device_id FROM push_devices ORDER BY updated_at DESC, device_id DESC LIMIT -1 OFFSET ?)`,
      MAX_PUSH_DEVICES,
    );
  });
}

export function deletePushDevice(storage: DurableObjectStorage, deviceId: string): void {
  storage.sql.exec("DELETE FROM push_devices WHERE device_id = ?", deviceId);
}

export function hasPushDevices(storage: DurableObjectStorage): boolean {
  return storage.sql.exec("SELECT 1 AS x FROM push_devices LIMIT 1").toArray().length > 0;
}

export function listPushDevices(storage: DurableObjectStorage): PushDevice[] {
  return storage.sql
    .exec<Row>("SELECT device_id, platform, token, apns_env, apns_topic, updated_at FROM push_devices ORDER BY device_id")
    .toArray()
    .map((r) => ({
      deviceId: r.device_id,
      platform: r.platform === "apns" ? "apns" : "fcm",
      token: r.token,
      apnsEnv: r.apns_env === "sandbox" || r.apns_env === "production" ? r.apns_env : null,
      apnsTopic: r.apns_topic,
      updatedAt: Number(r.updated_at),
    }));
}

/** Deletes a dead token — only if the row is unchanged since the snapshot (the phone may have re-registered during the send). */
export function prunePushDevice(storage: DurableObjectStorage, d: PushDevice): void {
  storage.sql.exec("DELETE FROM push_devices WHERE device_id = ? AND token = ? AND updated_at = ?", d.deviceId, d.token, d.updatedAt);
}

/** APNs environment fallback succeeded: remember the environment that works (same snapshot guard as prune). */
export function setPushApnsEnv(storage: DurableObjectStorage, d: PushDevice, env: ApnsEnvironment): void {
  storage.sql.exec("UPDATE push_devices SET apns_env = ? WHERE device_id = ? AND token = ? AND updated_at = ?", env, d.deviceId, d.token, d.updatedAt);
}
