/**
 * Request/response schemas for every /v1 endpoint (decisions D1). Human-readable contract: docs/api.md.
 * Query schemas use z.coerce for numbers because query values are strings.
 */
import { z } from "zod";
import { LIMITS } from "./limits.ts";
import {
  ExportFormat,
  ImportFormat,
  Item,
  ItemSort,
  ItemSource,
  ItemState,
  ItemStatus,
  Job,
  Tag,
  TagName,
  TagNames,
  User,
} from "./model.ts";
import { HttpUrl, Title } from "./ops.ts";

// ---------- errors ----------

export const ErrorCode = z.enum([
  "unauthorized", // 401
  "forbidden", // 403
  "invalid_request", // 400 (schema validation; `issues` may be present)
  "invalid_url", // 400
  "not_found", // 404
  "method_not_allowed", // 405 (content route)
  "not_parsed", // 409 content requested before parse finished / failed
  "resync_required", // 410 sync cursor older than tombstone horizon
  "payload_too_large", // 413
  "unsupported_media_type", // 415
  "rate_limited", // 429 (Retry-After header)
  "internal", // 500
]);
export type ErrorCode = z.infer<typeof ErrorCode>;

export const ApiError = z.object({
  error: z.string(),
  message: z.string().optional(),
  issues: z.array(z.object({ path: z.array(z.union([z.string(), z.number()])), message: z.string() })).optional(),
});
export type ApiError = z.infer<typeof ApiError>;

/**
 * Maps a zod validation failure to the 400 body (docs/api.md §3): if the only issue is `invalid_url`
 * (from HttpUrl) → `{error:"invalid_url"}`, else `{error:"invalid_request", message, issues}`.
 */
export function toApiError(err: z.ZodError): ApiError {
  const issues = err.issues.map((i) => ({
    path: i.path.filter((p): p is string | number => typeof p !== "symbol"),
    message: i.message,
  }));
  if (issues.length === 1 && issues[0]!.message === "invalid_url") return { error: "invalid_url" };
  return { error: "invalid_request", message: issues[0]?.message ?? "invalid_request", issues };
}

// ---------- items ----------

/** POST /v1/items */
export const CreateItemRequest = z.object({
  url: HttpUrl,
  title: Title.optional(),
  tags: TagNames.optional(),
  /**
   * Rendered page HTML (document.documentElement.outerHTML), plain string in the JSON body.
   * ≤ LIMITS.maxHtmlBytes UTF-8 bytes (server → 413 payload_too_large). Presence → private content.
   */
  html: z.string().optional(),
  source: ItemSource.optional(),
});
export type CreateItemRequest = z.infer<typeof CreateItemRequest>;

/** 202 for POST /v1/items. `created: false` → URL was already saved (re-add: moved to unread, tags merged). */
export const CreateItemResponse = z.object({ item: Item, created: z.boolean() });
export type CreateItemResponse = z.infer<typeof CreateItemResponse>;

/** GET /v1/items */
export const ListItemsQuery = z.object({
  state: ItemState.default("unread"),
  /** Tag name (case-insensitive). */
  tag: z.string().min(1).max(LIMITS.maxTagLength).optional(),
  /** Search over title, excerpt, site name, tags (FTS5 prefix match per term). */
  q: z.string().trim().min(1).max(LIMITS.maxSearchLength).optional(),
  sort: ItemSort.default("newest"),
  /** Hostname filter; matches host and its subdomains, "www." ignored. */
  domain: z.string().min(1).max(253).optional(),
  /** Exact lookup: any URL; server normalizes and matches canonicalUrl. Ignores `state` (searches all states). */
  url: z.string().min(1).max(LIMITS.maxUrlLength).optional(),
  /** Opaque cursor from a previous nextCursor. */
  cursor: z.string().min(1).max(512).optional(),
  limit: z.coerce.number().int().min(1).max(LIMITS.maxListLimit).default(LIMITS.defaultListLimit),
});
export type ListItemsQuery = z.infer<typeof ListItemsQuery>;

export const ListItemsResponse = z.object({
  items: z.array(Item),
  /** null when there are no more pages. */
  nextCursor: z.string().nullable(),
});
export type ListItemsResponse = z.infer<typeof ListItemsResponse>;

/** GET/PATCH /v1/items/:id, POST /v1/items/:id/refresh */
export const ItemResponse = z.object({ item: Item });
export type ItemResponse = z.infer<typeof ItemResponse>;

/** PATCH /v1/items/:id — every field optional; at least one required. */
export const UpdateItemRequest = z
  .object({
    status: ItemStatus.optional(),
    isFavorite: z.boolean().optional(),
    /** "" resets to parsed title. */
    title: Title.optional(),
    progress: z.number().min(0).max(1).optional(),
    progressAnchor: z.number().int().nonnegative().nullable().optional(),
    /** Replaces the item's tag set (server diffs into item.tag ops). */
    tags: TagNames.optional(),
  })
  .refine((v) => Object.values(v).some((x) => x !== undefined), { message: "empty_patch" });
export type UpdateItemRequest = z.infer<typeof UpdateItemRequest>;

/** GET /v1/items/:id/content */
export const ContentUrlsResponse = z.object({
  /** Signed URL of the sanitized article HTML. */
  articleUrl: z.string(),
  /** Signed directory URL ending in "/" — use as <base href> (relative img/… resolve against it). */
  baseUrl: z.string(),
  /** Signed URL of the offline package zip. */
  packageUrl: z.string(),
  /** Epoch ms when the signature expires. */
  expiresAt: z.number().int(),
});
export type ContentUrlsResponse = z.infer<typeof ContentUrlsResponse>;

// ---------- tags ----------

/** GET /v1/tags — all live tags with counts (count of non-deleted items), sorted by name. */
export const TagsResponse = z.object({ tags: z.array(Tag.required({ count: true })) });
export type TagsResponse = z.infer<typeof TagsResponse>;

/** GET /v1/tags/suggestions?url= */
export const TagSuggestionsQuery = z.object({ url: z.string().max(LIMITS.maxUrlLength).optional() });
export const TagSuggestionsResponse = z.object({
  /** Up to 10 tag names most recently applied (any item). */
  recent: z.array(z.string()),
  /** Up to 10 tag names by item count, excluding ones already in `recent`. */
  frequent: z.array(z.string()),
  /** Tags already on the item with this URL (if saved), else []. */
  current: z.array(z.string()),
});
export type TagSuggestionsResponse = z.infer<typeof TagSuggestionsResponse>;

/** PATCH /v1/tags/:id */
export const RenameTagRequest = z.object({ name: TagName });
export const TagResponse = z.object({ tag: Tag.required({ count: true }) });
export type TagResponse = z.infer<typeof TagResponse>;

// ---------- client error reporting ----------

const clip = (max: number) => z.string().transform((s) => s.slice(0, max));

/** POST /v1/client-errors (no auth): web client runtime errors. Over-long fields are truncated, not rejected. */
export const ClientErrorRequest = z.object({
  message: clip(1000).pipe(z.string().min(1)),
  /** Truncated to 4 KB. */
  stack: clip(4096).optional(),
  /** Location pathname only (no query/hash). */
  url: clip(300).optional(),
  userAgent: clip(300).optional(),
  /** Build/release identifier of the web app. */
  release: clip(64).optional(),
});
export type ClientErrorRequest = z.infer<typeof ClientErrorRequest>;

// ---------- config / me / account ----------

/** GET /v1/config (KV key "config", defaults merged). Public: auth NOT required. */
export const ConfigResponse = z.object({
  /** Web app origin (env APP_ORIGIN, not from KV), e.g. "https://sroka.app" — extension opens `${appOrigin}/app/`. */
  appOrigin: z.string(),
  minVersions: z.object({
    android: z.string().nullable(),
    ios: z.string().nullable(),
    extension: z.string().nullable(),
  }),
  features: z.record(z.string(), z.boolean()),
  limits: z.object({
    maxOpsPerPush: z.number().int(),
    maxHtmlBytes: z.number().int(),
    maxImportBytes: z.number().int(),
  }),
});
export type ConfigResponse = z.infer<typeof ConfigResponse>;

/** GET /v1/me */
export const MeResponse = z.object({
  user: User,
  stats: z.object({ unread: z.number().int(), archived: z.number().int(), favorites: z.number().int(), tags: z.number().int() }),
});
export type MeResponse = z.infer<typeof MeResponse>;

/** DELETE /v1/account — body must confirm. */
export const DeleteAccountRequest = z.object({ confirm: z.literal("DELETE") });
export const DeleteAccountResponse = z.object({ deleted: z.literal(true) });

// ---------- imports / exports ----------

/** POST /v1/imports multipart/form-data fields (file is validated separately as a File/Blob). */
export const ImportFormFields = z.object({ format: ImportFormat });
export const JobResponse = z.object({ job: Job });
export type JobResponse = z.infer<typeof JobResponse>;

/** GET /v1/exports?format= → file download (not JSON). */
export const ExportQuery = z.object({ format: ExportFormat.default("json") });

/** One row in the JSON export. */
export const ExportItem = z.object({
  url: z.string(),
  title: z.string().nullable(),
  status: ItemStatus,
  isFavorite: z.boolean(),
  tags: z.array(z.string()),
  savedAt: z.number().int(),
  archivedAt: z.number().int().nullable(),
  excerpt: z.string().nullable(),
  siteName: z.string().nullable(),
  wordCount: z.number().int().nullable(),
  progress: z.number(),
});
export const ExportJson = z.object({
  format: z.literal("sroka-export"),
  version: z.literal(1),
  exportedAt: z.number().int(),
  items: z.array(ExportItem),
});
export type ExportJson = z.infer<typeof ExportJson>;

/** Pocket-compatible CSV header used by GET /v1/exports?format=csv. */
export const EXPORT_CSV_COLUMNS = ["title", "url", "time_added", "tags", "status", "favorite"] as const;

// ---------- list cursor (opaque to clients; helper for the API worker) ----------

/** Keyset cursor: last row's sort key + id. Encoded as base64url JSON. */
export interface ListCursor {
  /** Sort value of the last row (savedAt for newest/oldest, wordCount for shortest/longest). */
  k: number | null;
  id: string;
}

export function encodeListCursor(c: ListCursor): string {
  return btoa(JSON.stringify(c)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function decodeListCursor(s: string): ListCursor | null {
  try {
    const json = atob(s.replace(/-/g, "+").replace(/_/g, "/"));
    const v = JSON.parse(json) as unknown;
    if (v && typeof v === "object" && "id" in v && typeof v.id === "string" && "k" in v &&
        (v.k === null || typeof v.k === "number")) {
      return { k: v.k, id: v.id };
    }
    return null;
  } catch {
    return null;
  }
}
