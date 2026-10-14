import { ext } from "./chrome.ts";

export const DEFAULT_SERVER = "https://api.sroka.app";

export interface Settings {
  serverUrl: string;
  captureHtml: boolean;
  token: string | null;
  email: string | null;
  signedOut: boolean;
}

export function normalizeServerUrl(input: string): string | null {
  try {
    const u = new URL(input.trim());
    if (u.protocol !== "https:" && u.protocol !== "http:") return null;
    return u.origin;
  } catch {
    return null;
  }
}

export async function getSettings(): Promise<Settings> {
  const r = (await ext().storage.local.get(["serverUrl", "captureHtml", "token", "email", "signedOut"])) as Partial<Settings>;
  return {
    serverUrl: r.serverUrl || DEFAULT_SERVER,
    captureHtml: r.captureHtml === true,
    token: r.token || null,
    email: r.email || null,
    signedOut: r.signedOut === true || !r.token,
  };
}

export async function setSettings(patch: Partial<Settings>): Promise<void> {
  await ext().storage.local.set(patch);
}

export async function clearSession(): Promise<void> {
  await ext().storage.local.remove(["token", "email"]);
  await ext().storage.local.set({ signedOut: true });
}

/** Per-install device id for the X-Sroka-Device LWW tie-breaker. */
export async function getDeviceId(): Promise<string> {
  const r = await ext().storage.local.get("deviceId");
  if (typeof r.deviceId === "string") return r.deviceId;
  const id = `ext-${crypto.randomUUID()}`;
  await ext().storage.local.set({ deviceId: id });
  return id;
}
