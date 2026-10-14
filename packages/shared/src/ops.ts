import { z } from "zod";
import { LIMITS } from "./limits.ts";
import { EpochMs, Item, ItemSource, ItemStatus, Tag, TagName, TagNames } from "./model.ts";
import { isHttpUrl } from "./url.ts";

/**
 * Client-generated op id (uuidv7 recommended). Idempotency key is (deviceId, opId): applied_ops is keyed
 * on both, so ids only need to be unique per device.
 */
export const OpId = z.string().min(1).max(64);
/** Device id (client-generated, stable per install, e.g. "dev_<uuidv7>"). Used as LWW tie-breaker. */
export const DeviceId = z.string().min(1).max(64).regex(/^[A-Za-z0-9_.:-]+$/);

export const HttpUrl = z
  .string()
  .trim()
  .min(1)
  .max(LIMITS.maxUrlLength)
  .refine(isHttpUrl, { message: "invalid_url" });

export const Title = z.string().trim().max(LIMITS.maxTitleLength);

const base = { opId: OpId, at: EpochMs };

export const ItemAddOp = z.object({
  ...base,
  type: z.literal("item.add"),
  itemId: z.uuid(),
  url: HttpUrl,
  title: Title.optional(),
  tags: TagNames.optional(),
  source: ItemSource.optional(),
  /** Original save time (imports keep Pocket time_added). Defaults to `at`. Only used when a NEW item is created. */
  savedAt: EpochMs.optional(),
  /** Initial status for a NEW item (imports). Default "unread". Ignored on duplicates. */
  status: ItemStatus.optional(),
  /** Initial favorite flag for a NEW item (imports). Default false. Ignored on duplicates. */
  isFavorite: z.boolean().optional(),
  /**
   * Behaviour when the canonical URL already exists as a live item:
   *  "readd" (default, Pocket semantics): move back to unread, fresh savedAt, union tags, alias.
   *  "merge" (imports): only union tags, alias; status/savedAt untouched.
   */
  onDuplicate: z.enum(["readd", "merge"]).optional(),
});

export const ItemSetStatusOp = z.object({
  ...base,
  type: z.literal("item.setStatus"),
  itemId: z.uuid(),
  status: ItemStatus,
});

export const ItemSetFavoriteOp = z.object({
  ...base,
  type: z.literal("item.setFavorite"),
  itemId: z.uuid(),
  value: z.boolean(),
});

export const ItemSetProgressOp = z.object({
  ...base,
  type: z.literal("item.setProgress"),
  itemId: z.uuid(),
  progress: z.number().min(0).max(1),
  anchor: z.number().int().nonnegative().nullable().optional(),
});

export const ItemTagOp = z.object({
  ...base,
  type: z.literal("item.tag"),
  itemId: z.uuid(),
  tag: TagName,
  present: z.boolean(),
});

export const ItemSetTitleOp = z.object({
  ...base,
  type: z.literal("item.setTitle"),
  itemId: z.uuid(),
  /** Empty string resets to the parsed title (stored as null user title). */
  title: Title,
});

export const TagRenameOp = z.object({
  ...base,
  type: z.literal("tag.rename"),
  from: TagName,
  to: TagName,
});

export const TagDeleteOp = z.object({
  ...base,
  type: z.literal("tag.delete"),
  tag: TagName,
});

export const ItemDeleteOp = z.object({
  ...base,
  type: z.literal("item.delete"),
  itemId: z.uuid(),
});

export const ItemRefreshOp = z.object({
  ...base,
  type: z.literal("item.refresh"),
  itemId: z.uuid(),
});

export const Op = z.discriminatedUnion("type", [
  ItemAddOp,
  ItemSetStatusOp,
  ItemSetFavoriteOp,
  ItemSetProgressOp,
  ItemTagOp,
  ItemSetTitleOp,
  TagRenameOp,
  TagDeleteOp,
  ItemDeleteOp,
  ItemRefreshOp,
]);
export type Op = z.infer<typeof Op>;
export type OpType = Op["type"];
export type OpOf<T extends OpType> = Extract<Op, { type: T }>;
/** Op as accepted by a client before schema transforms (e.g. untrimmed tags). */
export type OpInput = z.input<typeof Op>;

export const RejectReason = z.enum([
  /** Op failed schema validation (only when the request as a whole is valid). */
  "invalid_op",
  /** itemId not known (and no alias). */
  "unknown_item",
  /** Item is tombstoned (delete wins over concurrent edits). */
  "item_deleted",
  /** tag.rename/tag.delete for a tag name that does not exist. */
  "unknown_tag",
  /** item.add with a URL that does not normalize. */
  "invalid_url",
  /** item would exceed LIMITS.maxTagsPerItem. */
  "too_many_tags",
]);
export type RejectReason = z.infer<typeof RejectReason>;

export const PushRequest = z.object({
  deviceId: DeviceId,
  /**
   * Ops are validated one by one on the server: a malformed op is rejected with "invalid_op"
   * while the rest are applied. The array itself must be ≤ LIMITS.maxOpsPerPush.
   */
  ops: z.array(z.unknown()).max(LIMITS.maxOpsPerPush),
});
export type PushRequest = { deviceId: string; ops: OpInput[] };

export const PushResponse = z.object({
  /** opIds applied (including idempotent replays and LWW losers — both are "done" for the client). */
  applied: z.array(z.string()),
  rejected: z.array(z.object({ opId: z.string(), reason: RejectReason })),
  /** client itemId → existing server itemId for duplicate item.add (same canonical URL). */
  aliases: z.record(z.string(), z.string()),
  /** meta.seq after applying (pull from your previous cursor to receive your own changes). */
  cursor: z.number().int().nonnegative(),
});
export type PushResponse = z.infer<typeof PushResponse>;

export const PullQuery = z.object({
  cursor: z.coerce.number().int().nonnegative().default(0),
  limit: z.coerce.number().int().min(1).max(LIMITS.maxPullLimit).default(LIMITS.defaultPullLimit),
});
export type PullQuery = z.infer<typeof PullQuery>;

export const PullResponse = z.object({
  cursor: z.number().int().nonnegative(),
  hasMore: z.boolean(),
  items: z.array(Item),
  tags: z.array(Tag),
  deleted: z.object({ items: z.array(z.string()), tags: z.array(z.string()) }),
});
export type PullResponse = z.infer<typeof PullResponse>;

/** deviceId the server uses for ops synthesized from REST convenience endpoints. */
export const REST_DEVICE_ID = "rest";
/** deviceId the server uses for ops synthesized by imports. */
export const IMPORT_DEVICE_ID = "import";
/** Optional request header carrying the client deviceId on REST mutation endpoints (LWW tie-breaker). */
export const DEVICE_HEADER = "X-Sroka-Device";
