import { getConfig } from "./api.ts";
import { DEFAULT_SERVER, getSettings } from "./settings.ts";

const DEFAULT_APP_ORIGIN = "https://sroka.app";

/** Web app origin from `GET /v1/config`; offline, fall back to sroka.app (default server) or the custom server's origin (D8: same origin). */
export async function appOrigin(): Promise<string> {
  try {
    return (await getConfig()).appOrigin;
  } catch {
    const { serverUrl } = await getSettings();
    return serverUrl === DEFAULT_SERVER ? DEFAULT_APP_ORIGIN : serverUrl;
  }
}

/** Opens the web app (or a path inside it) in a new tab. */
export async function openApp(path = ""): Promise<void> {
  await chrome.tabs.create({ url: `${await appOrigin()}/app/${path}` });
}
