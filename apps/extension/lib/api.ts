import type {
  ConfigResponse,
  CreateItemRequest,
  CreateItemResponse,
  Item,
  ListItemsResponse,
  TagSuggestionsResponse,
  TagsResponse,
} from "@sroka/shared";
import { clearCache } from "./badge-cache.ts";
import { clearSession, getDeviceId, getSettings, setSettings } from "./settings.ts";

/** status 0 = network failure. */
export class ApiFailure extends Error {
  constructor(
    public status: number,
    public code: string,
    message?: string,
    public retryAfter?: number,
  ) {
    super(message || code);
  }
  get retryable(): boolean {
    return this.status === 0 || this.status === 429 || this.status >= 500;
  }
  get unauthorized(): boolean {
    return this.status === 401;
  }
}

async function errorFrom(res: Response): Promise<ApiFailure> {
  let code = `http_${res.status}`;
  let message: string | undefined;
  try {
    const b = (await res.json()) as { error?: string; code?: string; message?: string };
    code = b.error || b.code || code;
    message = b.message;
  } catch {
    /* non-JSON */
  }
  const ra = Number(res.headers.get("retry-after") ?? res.headers.get("x-retry-after"));
  return new ApiFailure(res.status, code, message, Number.isFinite(ra) && ra > 0 ? ra : undefined);
}

export interface FetchOpts {
  method?: string;
  body?: unknown;
  auth?: boolean;
}

/** Low-level fetch. Handles bearer, network errors and 401 → signed-out marking. */
export async function rawFetch(path: string, opts: FetchOpts = {}): Promise<Response> {
  const s = await getSettings();
  const headers: Record<string, string> = {};
  if (opts.body !== undefined) headers["content-type"] = "application/json";
  if (opts.auth !== false) {
    if (!s.token) {
      await setSettings({ signedOut: true });
      await clearCache();
      throw new ApiFailure(401, "unauthorized");
    }
    headers.authorization = `Bearer ${s.token}`;
    headers["x-sroka-device"] = await getDeviceId();
  }
  let res: Response;
  try {
    res = await fetch(s.serverUrl + path, {
      method: opts.method ?? (opts.body !== undefined ? "POST" : "GET"),
      headers,
      body: opts.body !== undefined ? JSON.stringify(opts.body) : undefined,
    });
  } catch (e) {
    throw new ApiFailure(0, "network", e instanceof Error ? e.message : "network error");
  }
  if (res.status === 401 && opts.auth !== false) {
    // Mark signed-out; queue and email are kept.
    await setSettings({ signedOut: true });
    await clearCache();
  }
  if (!res.ok) throw await errorFrom(res);
  return res;
}

async function json<T>(path: string, opts?: FetchOpts): Promise<T> {
  return (await rawFetch(path, opts)).json() as Promise<T>;
}

export type SaveBody = Pick<CreateItemRequest, "url" | "title" | "html" | "source" | "tags">;

export const saveItem = (body: SaveBody) => json<CreateItemResponse>("/v1/items", { method: "POST", body });

/** Badge lookup: returns the saved item for this URL, or null. */
export async function lookupUrl(url: string): Promise<Item | null> {
  const r = await json<ListItemsResponse>(`/v1/items?url=${encodeURIComponent(url)}&limit=1`);
  return r.items[0] ?? null;
}

export const patchItem = (id: string, patch: Record<string, unknown>) =>
  json<{ item: Item }>(`/v1/items/${id}`, { method: "PATCH", body: patch }).then((r) => r.item);

export const deleteItem = async (id: string) => {
  await rawFetch(`/v1/items/${id}`, { method: "DELETE" });
};

export const tagSuggestions = (url: string) =>
  json<TagSuggestionsResponse>(`/v1/tags/suggestions?url=${encodeURIComponent(url)}`);

export const listTags = () => json<TagsResponse>("/v1/tags");

export const getConfig = () => json<ConfigResponse>("/v1/config", { auth: false });

export const getMe = () => json<{ user: { email: string } }>("/v1/me");

export async function sendOtp(email: string): Promise<void> {
  await rawFetch("/api/auth/email-otp/send-verification-otp", {
    method: "POST",
    auth: false,
    body: { email, type: "sign-in" },
  });
}

export async function signIn(email: string, otp: string): Promise<void> {
  const res = await rawFetch("/api/auth/sign-in/email-otp", { method: "POST", auth: false, body: { email, otp } });
  const token = res.headers.get("set-auth-token");
  if (!token) throw new ApiFailure(500, "no_token", "Server did not return a session token");
  await setSettings({ token, email, signedOut: false });
  await clearCache();
}

export async function signOut(): Promise<void> {
  try {
    await rawFetch("/api/auth/sign-out", { method: "POST", body: {} });
  } catch {
    /* best effort */
  }
  await clearSession();
}

/** Human message for the UI. */
export function describeError(e: unknown): string {
  if (e instanceof ApiFailure) {
    switch (e.code) {
      case "INVALID_OTP":
        return "That code didn’t work. Check it and try again.";
      case "OTP_EXPIRED":
        return "That code expired. Request a new one.";
      case "TOO_MANY_ATTEMPTS":
        return "Too many wrong codes. Request a new one.";
      case "network":
        return "Can't reach the server.";
    }
    if (e.status === 429) return "Too many requests. Wait a moment.";
    if (e.status === 401) return "Signed out. Sign in again.";
    return e.message || e.code;
  }
  return e instanceof Error ? e.message : "Something went wrong";
}
