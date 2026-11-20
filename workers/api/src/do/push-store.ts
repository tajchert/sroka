/** LibraryDO `push_devices` (schema v7, decisions D17, api.md §17). */
import type { ApnsEnvironment, PushTokenRequest } from "@sroka/shared";
import type { PushDevice } from "../push/types.ts";

/** Max registered phones per library; the least recently updated rows beyond it are dropped. */
export const MAX_PUSH_DEVICES = 10;

type Row = { device_id: string; platform: string; token: string; apns_env: string | null; apns_topic: string | null };

/** Upsert keyed by device id; the same token under another device id is dropped (reinstall / id reset). */
export function putPushDevice(storage: DurableObjectStorage, deviceId: string, req: PushTokenRequest, now: number): void {
  const sql = storage.sql;
  const apnsEnv = req.platform === "apns" ? req.apnsEnvironment : null;
  const apnsTopic = req.platform === "apns" ? req.apnsTopic : null;
  storage.transactionSync(() => {
    sql.exec("DELETE FROM push_devices WHERE token = ? AND device_id <> ?", req.token, deviceId);
    sql.exec(
      `INSERT INTO push_devices (device_id, platform, token, apns_env, apns_topic, updated_at) VALUES (?, ?, ?, ?, ?, ?)
       ON CONFLICT(device_id) DO UPDATE SET platform = excluded.platform, token = excluded.token, apns_env = excluded.apns_env,
         apns_topic = excluded.apns_topic, updated_at = excluded.updated_at`,
      deviceId,
      req.platform,
      req.token,
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
    .exec<Row>("SELECT device_id, platform, token, apns_env, apns_topic FROM push_devices ORDER BY device_id")
    .toArray()
    .map((r) => ({
      deviceId: r.device_id,
      platform: r.platform === "apns" ? "apns" : "fcm",
      token: r.token,
      apnsEnv: r.apns_env === "sandbox" || r.apns_env === "production" ? r.apns_env : null,
      apnsTopic: r.apns_topic,
    }));
}

/** Deletes a dead token — only if the row still holds it (the phone may have re-registered during the send). */
export function prunePushDevice(storage: DurableObjectStorage, deviceId: string, token: string): void {
  storage.sql.exec("DELETE FROM push_devices WHERE device_id = ? AND token = ?", deviceId, token);
}

/** APNs environment fallback succeeded: remember the environment that works for this token. */
export function setPushApnsEnv(storage: DurableObjectStorage, deviceId: string, token: string, env: ApnsEnvironment): void {
  storage.sql.exec("UPDATE push_devices SET apns_env = ? WHERE device_id = ? AND token = ?", env, deviceId, token);
}
