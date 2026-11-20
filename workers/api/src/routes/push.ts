/** /v1/push-token — silent sync push registration (docs/api.md §17, decisions D17). Behind the auth middleware. */
import { DEVICE_HEADER, DeviceId, PushTokenRequest, REST_DEVICE_ID } from "@sroka/shared";
import { Hono } from "hono";
import { type LibraryAppEnv, type LibraryContext, apiError, library, readJson, validationError } from "../do/route-helpers.ts";

export const pushRoutes = new Hono<LibraryAppEnv>();

/** The phone's stable `X-Sroka-Device` id; null when missing, invalid or the generic REST id. */
function pushDeviceId(c: LibraryContext): string | null {
  const h = c.req.header(DEVICE_HEADER);
  return h && h !== REST_DEVICE_ID && DeviceId.safeParse(h).success ? h : null;
}

const noDevice = (c: LibraryContext) => apiError(c, 400, "validation", "device header required");

pushRoutes.put("/push-token", async (c) => {
  const deviceId = pushDeviceId(c);
  if (!deviceId) return noDevice(c);
  const parsed = PushTokenRequest.safeParse(await readJson(c));
  if (!parsed.success) return validationError(c, parsed.error);
  await library(c).putPushToken(deviceId, parsed.data, Date.now());
  return c.body(null, 204);
});

pushRoutes.delete("/push-token", async (c) => {
  const deviceId = pushDeviceId(c);
  if (!deviceId) return noDevice(c);
  await library(c).deletePushToken(deviceId);
  return c.body(null, 204);
});
