/** Typed same-origin API client for /v1 and /api/auth (docs/api.md). */
import {
  ContentUrlsResponse,
  CreateItemResponse,
  ItemResponse,
  JobResponse,
  ListItemsResponse,
  MeResponse,
  TagResponse,
  TagsResponse,
  type ExportFormat,
  type ImportFormat,
  type Item,
  type ItemSort,
  type ItemState,
  type UpdateItemRequest,
} from "@sroka/shared";

export class ApiRequestError extends Error {
  constructor(
    public status: number,
    public code: string,
    message?: string,
    public retryAfter?: number,
  ) {
    super(message || code);
    this.name = "ApiRequestError";
  }
}

type Schema<T> = { parse(data: unknown): T };

interface ReqOpts<T> {
  method?: string;
  query?: Record<string, string | number | undefined | null>;
  body?: unknown;
  form?: FormData;
  schema?: Schema<T>;
}

let onUnauthorized: (() => void) | null = null;
export function setUnauthorizedHandler(fn: (() => void) | null): void {
  onUnauthorized = fn;
}

export function buildQuery(query?: ReqOpts<unknown>["query"]): string {
  if (!query) return "";
  const sp = new URLSearchParams();
  for (const [k, v] of Object.entries(query)) {
    if (v === undefined || v === null || v === "") continue;
    sp.set(k, String(v));
  }
  const s = sp.toString();
  return s ? `?${s}` : "";
}

function parseRetryAfter(res: Response): number | undefined {
  const raw = res.headers.get("X-Retry-After") ?? res.headers.get("Retry-After");
  if (!raw) return undefined;
  const n = Number(raw);
  return Number.isFinite(n) ? n : undefined;
}

async function request<T = void>(path: string, opts: ReqOpts<T> = {}): Promise<T> {
  const headers: Record<string, string> = { Accept: "application/json", "X-Sroka-Device": "web" };
  let body: BodyInit | undefined;
  if (opts.form) body = opts.form;
  else if (opts.body !== undefined) {
    headers["Content-Type"] = "application/json";
    body = JSON.stringify(opts.body);
  }
  const res = await fetch(path + buildQuery(opts.query), {
    method: opts.method ?? "GET",
    headers,
    body,
    credentials: "same-origin",
  });
  if (!res.ok) {
    let data: { error?: string; code?: string; message?: string } = {};
    try {
      data = (await res.json()) as typeof data;
    } catch {
      /* non-JSON error body */
    }
    const code = data.error ?? data.code ?? (res.status === 429 ? "rate_limited" : `http_${res.status}`);
    if (res.status === 401 && path.startsWith("/v1/") && path !== "/v1/me") onUnauthorized?.();
    throw new ApiRequestError(res.status, code, data.message, parseRetryAfter(res));
  }
  if (res.status === 204) return undefined as T;
  const text = await res.text();
  const json: unknown = text ? JSON.parse(text) : null;
  return opts.schema ? opts.schema.parse(json) : (json as T);
}

export interface ItemsQuery {
  state?: ItemState;
  tag?: string;
  q?: string;
  sort?: ItemSort;
  domain?: string;
  cursor?: string;
  limit?: number;
}

export const api = {
  // --- auth (Better Auth) ---
  sendOtp: (email: string) =>
    request("/api/auth/email-otp/send-verification-otp", { method: "POST", body: { email, type: "sign-in" } }),
  verifyOtp: (email: string, otp: string) =>
    request("/api/auth/sign-in/email-otp", { method: "POST", body: { email, otp } }),
  signOut: () => request("/api/auth/sign-out", { method: "POST", body: {} }),

  // --- account ---
  me: () => request("/v1/me", { schema: MeResponse }),
  /** Session probe via /v1/me; null on 401. */
  async meOrNull() {
    try {
      return await api.me();
    } catch (e) {
      if (e instanceof ApiRequestError && e.status === 401) return null;
      throw e;
    }
  },
  deleteAccount: () => request("/v1/account", { method: "DELETE", body: { confirm: "DELETE" } }),

  // --- items ---
  listItems: (query: ItemsQuery) => request("/v1/items", { query: { ...query }, schema: ListItemsResponse }),
  createItem: (url: string, tags?: string[]) =>
    request("/v1/items", {
      method: "POST",
      body: { url, source: "web", ...(tags?.length ? { tags } : {}) },
      schema: CreateItemResponse,
    }),
  getItem: async (id: string): Promise<Item> => (await request(`/v1/items/${id}`, { schema: ItemResponse })).item,
  updateItem: async (id: string, patch: UpdateItemRequest): Promise<Item> =>
    (await request(`/v1/items/${id}`, { method: "PATCH", body: patch, schema: ItemResponse })).item,
  deleteItem: (id: string) => request(`/v1/items/${id}`, { method: "DELETE" }),
  refreshItem: async (id: string): Promise<Item> =>
    (await request(`/v1/items/${id}/refresh`, { method: "POST", body: {}, schema: ItemResponse })).item,
  getContent: (id: string) => request(`/v1/items/${id}/content`, { schema: ContentUrlsResponse }),

  // --- tags ---
  listTags: async () => (await request("/v1/tags", { schema: TagsResponse })).tags,
  renameTag: async (id: string, name: string) =>
    (await request(`/v1/tags/${id}`, { method: "PATCH", body: { name }, schema: TagResponse })).tag,
  deleteTag: (id: string) => request(`/v1/tags/${id}`, { method: "DELETE" }),

  // --- import / export ---
  async createImport(file: File, format: ImportFormat) {
    const form = new FormData();
    form.set("format", format);
    form.set("file", file);
    return (await request("/v1/imports", { method: "POST", form, schema: JobResponse })).job;
  },
  getImport: async (id: string) => (await request(`/v1/imports/${id}`, { schema: JobResponse })).job,
  exportUrl: (format: ExportFormat) => `/v1/exports?format=${format}`,

  /** Article HTML from the signed content URL (cross-origin, cookieless). */
  async fetchArticle(articleUrl: string): Promise<string> {
    const res = await fetch(articleUrl, { credentials: "omit" });
    if (!res.ok) throw new ApiRequestError(res.status, `http_${res.status}`);
    return res.text();
  },
};

/** Human message for a sign-in failure (api.md section 2.1). */
export function describeAuthError(err: unknown): string {
  if (err instanceof ApiRequestError) {
    if (err.status === 429) {
      return err.retryAfter
        ? `Too many attempts. Try again in ${err.retryAfter} seconds.`
        : "Too many attempts. Wait a moment and try again.";
    }
    switch (err.code) {
      case "INVALID_OTP":
        return "That code is not right. Check the email and try again.";
      case "OTP_EXPIRED":
        return "That code has expired. Request a new one.";
      case "TOO_MANY_ATTEMPTS":
        return "Too many wrong codes. Request a new code to continue.";
      case "invalid_request":
      case "INVALID_EMAIL":
        return "Enter a valid email address.";
    }
    return err.message === err.code ? "Something went wrong. Try again." : err.message;
  }
  return "Could not reach Sroka. Check your connection and try again.";
}

/** Parse-poll delay (api.md section 5.1): 2s, 4s, 8s ... capped at 30s; give up after 5 minutes. */
export const POLL_GIVE_UP_MS = 5 * 60 * 1000;
export function pollDelay(attempt: number): number {
  return Math.min(2000 * 2 ** attempt, 30_000);
}
