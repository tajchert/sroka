# Sroka HTTP & sync contract (v1)

Source of truth for shapes: `packages/shared/src/*.ts` (zod). This document defines **semantics** the schemas can't express.
If this document and `docs/decisions.md` disagree, decisions.md wins; if this document and the schemas disagree on a *shape*, the schema wins — fix the doc.

Contents: 1 Conventions · 2 Hosts, auth, CORS · 3 Errors · 4 Objects · 5 Items endpoints · 6 Tags endpoints · 7 Sync · 8 Mutation semantics (applyOps) · 9 Parse pipeline interface · 10 Content delivery · 11 Imports/exports · 12 Account, me, config · 13 URL normalization · 14 Limits & rate limits · 15 Storage notes for implementers

---

## 1. Conventions

- JSON bodies, `Content-Type: application/json`, UTF-8. Keys **camelCase**. SQL is snake_case.
- Times: **epoch milliseconds** (integers) everywhere, except the `exp` segment of signed content URLs (unix seconds) and CSV `time_added` (unix seconds, Pocket-compatible).
- IDs: items, tags, jobs, content = **UUIDv7** strings (`uuidv7()` from `@sroka/shared`). User ids are Better Auth ids (opaque `[A-Za-z0-9_-]`, ≤64 chars).
- All `/v1/*` endpoints require auth except `GET /v1/config` (and the unauthenticated `GET /v1/health`).
- Validation: every request is validated with the zod schema named in each section (Hono `zValidator`-style, or `schema.safeParse`). Failures → `400 {error:"invalid_request", message, issues}`.
- Query-string numbers are coerced (`z.coerce`). Unknown query/body keys are ignored (zod strips).
- Optional request header **`X-Sroka-Device: <deviceId>`** on REST mutation endpoints; used as the LWW tie-breaker. Default deviceId `"rest"` (`REST_DEVICE_ID`).

## 2. Hosts, auth, CORS

| Host | Serves | Auth | CORS |
|---|---|---|---|
| `sroka.app` (dev `http://localhost:8787`) | `/` landing, `/app/*` SPA, **and** `/api/auth/*`, `/v1/*` (same-origin for the web app) | Better Auth **cookie** (host-only) | none needed (same origin) |
| `api.sroka.app` (dev: same `localhost:8787`) | `/api/auth/*`, `/v1/*` | **`Authorization: Bearer <token>`** (cookies also accepted) | allow-list below |
| `c.sroka.app` (dev `http://127.0.0.1:8787`) | `/s/…` signed content only | signature in path; cookieless | `Access-Control-Allow-Origin: {APP_ORIGIN}` |

The API Worker picks the behaviour by `new URL(req.url).host`: equal to `new URL(CONTENT_ORIGIN).host` → content route only (everything else 404). Otherwise the normal app (`/api/auth/*`, `/v1/*`, `/app/*` SPA fallback, assets).
In dev, `localhost:8787` acts as both `sroka.app` and `api.sroka.app`.

**CORS for `/api/*` and `/v1/*`** (Hono `cors`): `origin` echoed only if it equals `APP_ORIGIN`, or starts with `chrome-extension://` or `moz-extension://`; otherwise no CORS headers. `allowMethods: GET,POST,PATCH,DELETE,OPTIONS`; `allowHeaders: Content-Type, Authorization, X-Sroka-Device`; `exposeHeaders: set-auth-token, Retry-After, Content-Disposition`; `credentials: false`; `maxAge: 600`. (The MV3 service worker with host_permissions bypasses CORS anyway.)

### 2.1 Auth endpoints (Better Auth, mounted at `/api/auth/*`)

| Call | Body | Result |
|---|---|---|
| `POST /api/auth/email-otp/send-verification-otp` | `{"email":"a@b.c","type":"sign-in"}` | `200 {"success":true}` — same response whether or not the account exists. Dev (`ENVIRONMENT=development`): OTP logged as `[sroka] OTP for a@b.c: 123456`, email not sent. |
| `POST /api/auth/sign-in/email-otp` | `{"email":"a@b.c","otp":"123456"}` | `200 {token, user}`, header **`set-auth-token: <token>`**, plus session cookie. Creates the user if new. Wrong code → `400`/`403` Better Auth error; >5 attempts → code invalidated. |
| `GET /api/auth/get-session` | — | `{session, user}` or `null` |
| `POST /api/auth/sign-out` | `{}` | `200` |

OTP: 6 digits, expires in 300 s, 5 attempts, stored hashed. Sessions 90 days, rolling (refreshed at most daily).
Extension/native: store the `set-auth-token` value verbatim (it contains `.` and may contain `=`; don't URL-encode) and send `Authorization: Bearer <value>`.

### 2.2 `/v1` auth middleware

`auth.api.getSession({headers})` → `userId = session.user.id`. No session → `401 {"error":"unauthorized"}`. Clients: on 401 keep local data, ask the user to sign in again.

## 3. Errors

Body: `{"error": "<code>", "message"?: "<human text>", "issues"?: [{path, message}]}` (`ApiError`).

| Status | `error` | When |
|---|---|---|
| 400 | `invalid_request` | schema validation failed (`issues` present) or semantic problem (`message` e.g. `too_many_tags`, `empty_patch`, `bad_cursor`) |
| 400 | `invalid_url` | URL not http(s) / not normalizable |
| 401 | `unauthorized` | no/invalid session |
| 403 | `forbidden` | content route: bad signature or expired (`message`: `bad_signature`/`expired`/`malformed`) |
| 404 | `not_found` | unknown or deleted item/tag/job, unknown route |
| 405 | `method_not_allowed` | content route non-GET/HEAD |
| 409 | `not_parsed` | `GET /v1/items/:id/content` while `contentId` is null |
| 410 | `resync_required` | sync pull cursor older than tombstone horizon |
| 413 | `payload_too_large` | body/html/import file above limits |
| 415 | `unsupported_media_type` | import not multipart / unknown file type |
| 429 | `rate_limited` | with `Retry-After: <seconds>` |
| 500 | `internal` | unexpected; logged |

## 4. Objects

### 4.1 Item (`Item` in model.ts)

```json
{
  "id": "01929b1e-6f1c-7a2b-9c3d-4e5f60718293",
  "url": "https://example.com/post?utm_source=x",
  "canonicalUrl": "https://example.com/post",
  "title": "How magpies think",
  "excerpt": "Corvids are …",
  "siteName": "Example",
  "author": "Jane Doe",
  "lang": "en",
  "leadImageUrl": "https://c.sroka.app/s/1760486400/AbC…xyz/p/0192f3c4-…/thumb.webp",
  "wordCount": 2310,
  "readingMinutes": 10,
  "contentId": "0192f3c4-1111-7222-8333-444455556666",
  "contentPrivate": false,
  "parseStatus": "ok",
  "parseError": null,
  "status": "unread",
  "isFavorite": false,
  "progress": 0.42,
  "progressAnchor": 17,
  "savedAt": 1760400723120,
  "archivedAt": null,
  "lastReadAt": 1760400802000,
  "source": "extension",
  "tags": ["birds", "science"],
  "seq": 18410
}
```

- `title` on the wire = user title (set via `item.setTitle`/PATCH) if any, else parsed title, else the provisional title given at save time, else `null`. Clients fall back to `canonicalUrl`/domain for display.
- `leadImageUrl`: signed URL (section 10) of `{contentDir}/{leadImageKey}`, freshly signed in every response (24 h TTL), `null` if no thumbnail.
- `parseStatus`: `pending` (queued/working) → `ok` | `partial` (content usable but poor; offer "Open original") | `failed` (`parseError` = short reason like `http_404`, `timeout`, `not_html`, `extract_failed`, `too_large`, `blocked_url`). `contentId` non-null ⇔ content readable (`ok` or `partial`).
- `progress` 0..1, `progressAnchor` paragraph index (0-based, counting block elements in article.html) or null.
- `status` `unread|archived`; `archivedAt` set when archived, null when unread.
- `source`: `share|extension|web|import|email|api` or null.
- `tags`: names, sorted case-insensitively.
- `seq`: last change sequence (section 7).

### 4.2 Tag

`{"id":"0192…","name":"Machine learning","count":12,"seq":18399}` — `count` only in `GET /v1/tags`, `PATCH /v1/tags/:id` (and `TagResponse`), not in sync pull.
Tag names: NFC, trimmed, whitespace collapsed (`normalizeTagName`), 1–64 chars, **case-insensitively unique** per user. The stored casing is the one from the creating op (or latest rename).

### 4.3 Job

```json
{"id":"0192…","kind":"import","status":"running","format":"pocket_csv","total":5012,"done":1200,"skipped":3,
 "error":null,"createdAt":1760400723120,"updatedAt":1760400730000}
```
`status`: `queued → running → done | failed`. `done` counts processed rows (created + duplicates + skipped). `total` null until the file is parsed.

## 5. Items endpoints

All mutations are translated server-side into sync ops (`at = Date.now()`, deviceId from `X-Sroka-Device` or `"rest"`) and applied through the same `applyOps` path as `/v1/sync/push` (section 8).

### 5.1 `POST /v1/items` — quick save (web, extension)
Request `CreateItemRequest`:
```json
{"url":"https://example.com/post?utm_source=x","title":"Optional page title","tags":["birds"],"source":"extension",
 "html":"<!doctype html><html>…</html>"}
```
- `html` (optional): `document.documentElement.outerHTML` as a **plain JSON string** (not gzipped). Max `LIMITS.maxHtmlBytes` = 5 MiB of UTF-8; whole body max 6 MiB (check `Content-Length` first) → `413 payload_too_large`. Presence ⇒ captured/private content.
- Server: new `itemId = uuidv7()`, op `item.add` (`onDuplicate:"readd"`, `source` default `"api"`). If the canonical URL already exists → the existing item is re-added (Pocket semantics, section 8.3) and returned with `created:false`.
- If `html` given: gzip it (`CompressionStream("gzip")`), `CONTENT.put("raw/{userId}/{itemId}.html.gz")` (itemId = the resulting item's id, i.e. the existing one for duplicates), enqueue `ParseJob {userId,itemId,url,rawKey,force:true}`.
- Without `html`: enqueue `ParseJob {userId,itemId,url}` only if the item is new, or it is a duplicate whose `parseStatus` is `failed`.
- Response **`202 {"item": Item, "created": true|false}`** (`CreateItemResponse`). Item has `parseStatus:"pending"` when newly queued.
- Errors: 400 `invalid_url`, 400 `invalid_request`, 413.

### 5.2 `GET /v1/items` — list / search / lookup
Query `ListItemsQuery`: `state` (`unread`*default*|`archived`|`favorites`|`all`), `tag`, `q`, `sort` (`newest`*default*|`oldest`|`shortest`|`longest`), `domain`, `url`, `cursor`, `limit` (1–100, default 30).

- Never returns deleted items.
- `state`: unread → `status='unread'`; archived → `status='archived'`; favorites → `isFavorite` (any status); all → everything.
- `tag`: items where the tag (case-insensitive name) is present. Unknown tag → empty list.
- `q`: FTS5 over title, excerpt, siteName, tags. Each whitespace-separated term is quoted and prefix-matched (`"term"*`), terms ANDed; FTS syntax characters in user input are neutralized (never 400/500 for odd input). Ordering still follows `sort`.
- `domain`: matches the item host or any subdomain; leading `www.` ignored on both sides (`displayDomain`). E.g. `domain=nytimes.com` matches `www.nytimes.com`, `cooking.nytimes.com`.
- `url`: **exact lookup** — server `normalizeUrl(url)` and matches `canonicalUrl` among live items, ignoring `state`/`tag`/`q`/`domain`. Returns 0 or 1 item, `nextCursor:null`. Invalid URL → `400 invalid_url`. (Extension badge.)
- `sort`: newest = `savedAt DESC, id DESC`; oldest = `savedAt ASC, id ASC`; shortest = `wordCount ASC NULLS LAST, id ASC`; longest = `wordCount DESC NULLS LAST, id DESC`.
- Paging: keyset. `nextCursor` = opaque (`encodeListCursor({k: sortValueOfLastRow, id})`), `null` when no more rows. A cursor is only valid with the same filters/sort; undecodable → `400 invalid_request` (`message:"bad_cursor"`).
- Response `200 ListItemsResponse` `{"items":[Item…],"nextCursor":"eyJrIjoxNzYwNDAw…"|null}`.

### 5.3 `GET /v1/items/:id`
`200 {"item": Item}` · `404` if unknown or deleted.

### 5.4 `PATCH /v1/items/:id`
Body `UpdateItemRequest` (≥1 field): `{"status":"archived"}`, `{"isFavorite":true}`, `{"title":"My title"}` (`""` = reset to parsed title), `{"progress":0.5,"progressAnchor":12}`, `{"tags":["a","b"]}` (**replaces** the tag set).
Mapping: status → `item.setStatus`; isFavorite → `item.setFavorite`; title → `item.setTitle`; progress/progressAnchor → `item.setProgress` (if only `progressAnchor` given, progress keeps its current value); tags → diff against current tags: `item.tag present:false` for removed names, `present:true` for added names (case-insensitive compare).
Response `200 {"item": Item}` (after applying). `404` unknown/deleted; `400 invalid_request` (`message:"too_many_tags"` if >100).

### 5.5 `DELETE /v1/items/:id`
Op `item.delete`. `204` (no body). `404` if unknown or already deleted.

### 5.6 `POST /v1/items/:id/refresh`
Op `item.refresh` (sets `parseStatus:"pending"`, enqueues `ParseJob{userId,itemId,url,force:true}`; the URL is refetched publicly — previously captured HTML is not reused). `202 {"item": Item}`. `404`.

### 5.7 `GET /v1/items/:id/content`
`200 ContentUrlsResponse`:
```json
{"articleUrl":"https://c.sroka.app/s/1760486400/Zm9v…/p/0192f3c4-…/article.html",
 "baseUrl":"https://c.sroka.app/s/1760486400/Zm9v…/p/0192f3c4-…/",
 "packageUrl":"https://c.sroka.app/s/1760486400/Zm9v…/p/0192f3c4-…/package.zip",
 "expiresAt":1760486400000}
```
Scope `p` when `contentPrivate=false`, `u.{userId}` otherwise. `409 {"error":"not_parsed"}` when `contentId` is null (pending/failed). `404` unknown/deleted.
Web reader: `fetch(articleUrl)` → text → `<iframe sandbox="allow-popups allow-popups-to-escape-sandbox" srcdoc>` with injected `<base href="{baseUrl}" target="_blank">`, CSP meta, theme CSS (D7).

## 6. Tags endpoints

### 6.1 `GET /v1/tags`
`200 {"tags":[{"id":"…","name":"birds","count":12,"seq":18399}, …]}` — all live tags (including count 0), sorted by name case-insensitively. `count` = live items with the pair present.

### 6.2 `GET /v1/tags/suggestions?url=`
`200 {"recent":["birds","to-cook"],"frequent":["science"],"current":["birds"]}`
- `recent`: up to 10 distinct names ordered by the most recent `item_tags.at` with `present=1`.
- `frequent`: up to 10 names by `count` desc (ties by name), excluding names in `recent`.
- `current`: tags of the live item whose canonical URL equals `normalizeUrl(url)`; `[]` if not saved / no url / invalid url (never 400).

### 6.3 `PATCH /v1/tags/:id` `{"name":"Machine learning"}`
Op `tag.rename {from: <current name>, to: name}`. If another live tag already has that name (case-insensitively) the tags are **merged** into the existing one (section 8.6). `200 {"tag": Tag-with-count}` (the surviving tag). `404` unknown/deleted tag.

### 6.4 `DELETE /v1/tags/:id`
Op `tag.delete {tag: <name>}`; removes the tag from all items. `204`. `404`.

## 7. Sync (native apps; any client may use it)

### 7.1 `POST /v1/sync/push`
Request (`PushRequest`): `{"deviceId":"dev_0192…","ops":[Op, …]}` — `deviceId` `^[A-Za-z0-9_.:-]{1,64}$`, ≤500 ops (more → `400 invalid_request`). Op shapes (`Op` union in ops.ts), every op has `opId` (≤64 chars, uuidv7 recommended) and `at` (client epoch ms):

```json
{"opId":"…a1","type":"item.add","itemId":"<uuidv7>","at":1760400723120,"url":"https://example.com/post?utm_source=x",
 "title":"Optional","tags":["travel"],"source":"share","savedAt":1760400723120,"status":"unread","isFavorite":false,"onDuplicate":"readd"}
{"opId":"…a2","type":"item.setStatus","itemId":"…","status":"archived","at":…}
{"opId":"…a3","type":"item.setFavorite","itemId":"…","value":true,"at":…}
{"opId":"…a4","type":"item.setProgress","itemId":"…","progress":0.42,"anchor":17,"at":…}
{"opId":"…a5","type":"item.tag","itemId":"…","tag":"to-cook","present":true,"at":…}
{"opId":"…a6","type":"item.setTitle","itemId":"…","title":"My title","at":…}
{"opId":"…a7","type":"tag.rename","from":"ml","to":"machine-learning","at":…}
{"opId":"…a8","type":"tag.delete","tag":"old","at":…}
{"opId":"…a9","type":"item.delete","itemId":"…","at":…}
{"opId":"…b0","type":"item.refresh","itemId":"…","at":…}
```
(`item.add` fields after `source` are optional; `savedAt/status/isFavorite` apply only when a new item is created.)

Response `200 PushResponse`:
```json
{"applied":["…a1","…a2"],"rejected":[{"opId":"…a9","reason":"unknown_item"}],
 "aliases":{"<client itemId>":"<existing itemId>"},"cursor":18423}
```
Processing rules:
1. The body is validated as `{deviceId, ops: unknown[] ≤500}`; then **each op individually** with `Op.safeParse`. An invalid op → `rejected {opId: op.opId ?? "", reason:"invalid_op"}`; the rest still apply.
2. Ops are applied **in array order**, each in its own `transactionSync`.
3. **Idempotency:** if `opId` is in `applied_ops`, the op is not re-applied and is reported in `applied` (and, for an aliased `item.add`, the alias is reported again — `applied_ops` stores the alias target).
4. Applied ops (including LWW losers and no-ops) are recorded in `applied_ops(op_id, applied_at, alias)`. **Rejected ops are not recorded** (a retry re-evaluates them).
5. Aliases: an `item.add` whose URL matches a different live item yields `aliases[clientId] = existingId`; later ops **in the same push** that reference `clientId` are rewritten to `existingId`. Clients must also rewrite pending local ops and merge the local row.
6. Reject reasons (`RejectReason`): `invalid_op`, `unknown_item` (itemId never seen and not aliased), `item_deleted` (item is tombstoned — delete wins), `unknown_tag` (rename/delete of a missing tag name), `invalid_url`, `too_many_tags`. Clients drop rejected ops (after reconciling via pull).
7. `cursor` = `meta.seq` after the push. Clients should still pull from their previous cursor to receive the canonical rows they changed.

### 7.2 `GET /v1/sync/pull?cursor=&limit=`
Query `PullQuery`: `cursor` (int ≥0, default 0), `limit` (1–1000, default 500).
Response `200 PullResponse`:
```json
{"cursor":18423,"hasMore":false,
 "items":[Item…],"tags":[{"id":"…","name":"travel","seq":18399}],
 "deleted":{"items":["<itemId>"],"tags":["<tagId>"]}}
```
- Returns all item and tag rows with `seq > cursor`, ordered by `seq` ascending, at most `limit` rows **in total** (items + tags + tombstones). Live rows go into `items`/`tags`; tombstoned rows go into `deleted.items`/`deleted.tags` (ids only).
- `cursor` in the response = seq of the last returned row if `hasMore`, else the current `meta.seq`. Repeat until `hasMore:false`. First sync: `cursor=0`.
- `410 {"error":"resync_required"}` if `0 < cursor < meta.tombstone_horizon` (the highest seq of any purged tombstone). The client then merges pending ops, pushes them, and pulls from 0.
- Item rows include signed `leadImageUrl` (24 h); clients needing content call `GET /v1/items/:id/content`.

### 7.3 seq rules (for the DO implementer)
- `meta.seq` starts at 0. **Each op that changes anything increments `meta.seq` exactly once** and stamps every row it changed (item, tag) with that value. LWW losers/no-ops don't increment.
- An `item_tags` pair change bumps the **item's** seq (its `tags` array changed). Creating a tag bumps the tag's seq too.
- Tag rename bumps the tag and every live item carrying it. Tag delete tombstones the tag and bumps every item that carried it.
- `markParsed`, `item.refresh`, import batches bump the affected item(s) like any change.
- Tombstones (`deleted_at` set) keep their row with the new seq; purged after 180 days by the DO alarm, raising `meta.tombstone_horizon` to the max purged seq.

## 8. Mutation semantics (`applyOps`, LibraryDO)

`at` is first clamped: `at = clampAt(op.at, now)` (≤ now + 5 min). Stamp = `{at, dev: deviceId}`.

### 8.1 LWW
Per-field clocks in `items.clock` JSON (`ItemClock`): `title`, `status`, `isFavorite`, `progress` (progress + anchor + lastReadAt together). Incoming stamp wins iff `at > cur.at`, or `at == cur.at && dev > cur.dev` (string compare), or equal stamp (later-applied wins) — `applyLww()`. Losing ops are **applied** (no change, no seq bump).
`item_tags` pairs: LWW on `at` only (`present` + `at` columns): incoming wins iff `at >= pair.at`.

### 8.2 `item.add`
1. `canonical = normalizeUrl(url)` (fail → reject `invalid_url`), `hash = urlHash(canonical)`.
2. If `itemId` exists: tombstoned → reject `item_deleted`; live → treat as duplicate of itself (step 4 without alias).
3. Else if a live item `Y` has `url_hash = hash` → duplicate of `Y`, alias `itemId → Y.id` (step 4).
4. Duplicate handling: `onDuplicate:"readd"` (default): with stamp on `status`: if it wins → `status=unread`, `archivedAt=null`, `savedAt=max(savedAt, at)`; union `tags` (each as `item.tag present:true` with the op stamp); provisional `title` only if the item has no title. `onDuplicate:"merge"`: only union tags. (Re-queue parsing per 5.1.)
5. Else insert a new live item: `id=itemId`, `url`, `canonical_url`, `url_hash`, `title` = provisional title or null, `status = op.status ?? "unread"`, `archivedAt = status==archived ? at : null`, `isFavorite = op.isFavorite ?? false`, `savedAt = op.savedAt ?? at`, `source = op.source ?? null`, `parse_status="pending"`, `clock` = `{status, isFavorite}` stamped (and `title` NOT stamped — the provisional title can be replaced by the parser), tags added, FTS row inserted. The caller (REST handler / push handler) enqueues a `ParseJob` for every newly created item (push: `ParseJob{userId,itemId,url}`; up to 100 per `sendBatch`).
6. A URL whose only matching item is tombstoned creates a **new** item (re-save after delete).

### 8.3 Other item ops (target must be live; unknown → `unknown_item`, tombstoned → `item_deleted`)
- `item.setStatus`: LWW `status`; archived → `archivedAt = at`; unread → `archivedAt = null`.
- `item.setFavorite`: LWW `isFavorite`.
- `item.setProgress`: LWW `progress`; sets `progress`, `progressAnchor = anchor ?? null`, `lastReadAt = at`.
- `item.setTitle`: LWW `title`; stores the **user title** (`""` → null = fall back to parsed/provisional). Parser never overwrites a user title.
- `item.tag`: find live tag by name (NOCASE). Missing + `present:true` → create tag (`id=uuidv7()`, name as given). Missing + `present:false` → applied no-op. Pair LWW (8.1). Adding beyond 100 present tags → `too_many_tags`.
- `item.delete`: tombstone (`deleted_at = at`), delete FTS row; item_tags rows kept (not returned). Unknown → `unknown_item`; already deleted → applied no-op. **Delete wins**: all later ops on it are rejected `item_deleted`.
- `item.refresh`: `parse_status=pending`, `parse_error=null`; caller enqueues `ParseJob{…, force:true}`.

### 8.4 Tag ops
- `tag.rename {from,to}`: `from` missing → `unknown_tag`. Same tag (case-insensitive equal) → change casing. `to` names another live tag → **merge**: every present pair of `from` becomes present on `to` (stamp `at`), then `from` is tombstoned. Otherwise rename in place. No LWW on tag names (last applied wins).
- `tag.delete {tag}`: missing → `unknown_tag`. Tombstone the tag, set all its pairs `present=0, at`. A later `item.tag` with that name creates a new tag (new id).

### 8.5 FTS
`items_fts(title, excerpt, site_name, tags)` keyed by an integer rowid mapped to item id (e.g. an `items.rowid`/`fts_rowid` column). Updated manually on add, title/parse/tag changes, delete.

## 9. Parse pipeline interface (api ↔ parser)

- Queue `sroka-parse` message = `ParseJob` (parse.ts): `{userId, itemId, url, rawKey?, force?}`. Producer: `env.PARSE_QUEUE.send(job)` / `sendBatch`.
- `rawKey` = `raw/{userId}/{itemId}.html.gz` (gzip of the captured HTML). Present ⇒ parse that HTML (base URL = `url`), result is **private** (`contentPrivate:true`, R2 `private/{userId}/{contentId}/…`), never written to or read from the shared D1 cache.
- No `rawKey` and no `force` ⇒ parser may reuse D1 `content` row with same `url_hash` + `PARSER_VERSION`, `status != failed`, `parsed_at` within 7 days.
- Result → RPC on the user's DO: `env.LIBRARY.getByName(userId).markParsed(itemId, result: ParseResult) → Promise<{ok: boolean}>`. `ok:false` when the item is unknown or deleted (parser may then skip ref-counting). `ParseResult` fields: `status ok|partial|failed`, `contentId?`, `contentPrivate`, `title, excerpt, siteName, author, lang, wordCount, readingMinutes` (nullable), `leadImageKey?` (path relative to the content dir, normally `"thumb.webp"`), `error?`, `parserVersion`.
- `markParsed` sets those columns (parsed `title` only replaces the stored non-user title when non-null), `parse_status`, `parse_error = error ?? null`, bumps seq, updates FTS. A `failed` result clears nothing else (keeps an earlier `contentId` if any).
- DLQ consumer (`sroka-parse-dlq`) calls `markParsed(itemId, {status:"failed", contentPrivate:false, title:null, excerpt:null, siteName:null, author:null, lang:null, wordCount:null, readingMinutes:null, error:"parse_failed", parserVersion: PARSER_VERSION})`.
- R2 layout per content dir (`r2Keys.contentDir`): `article.html`, `text.txt`, `img/{sha256}.webp`, `thumb.webp`, `package.zip` (manifest.json + article.html + img/*; `PackageManifest`).

## 10. Content delivery (signed URLs, D7)

URL: `{CONTENT_ORIGIN}/s/{exp}/{sig}/{scope}/{contentId}/{file}`
- `exp` unix seconds; default `defaultExp()` = now + 24 h rounded **up** to the hour.
- `scope` = `p` (R2 `content/{contentId}/`) or `u.{userId}` (R2 `private/{userId}/{contentId}/`).
- `sig` = base64url (no padding, 43 chars) of HMAC-SHA256(`CONTENT_URL_SIGNING_KEY`, `"{exp}/{scope}/{contentId}"`). Covers the directory, so relative `img/…` in article.html work.
- `file`: 1–4 segments of `[A-Za-z0-9_-][A-Za-z0-9._-]*` (no `..`), e.g. `article.html`, `img/ab12….webp`, `package.zip`, `thumb.webp`.
- Build with `buildContentUrls` / `buildContentUrl`; verify with `verifyContentPath(secret, pathname)` → `{ok, r2Key, isPrivate, …}`.

Route (content host only): `GET`/`HEAD` only (else `405`). Malformed → `403 forbidden message:malformed`; bad signature → `403 bad_signature`; expired → `403 expired`; R2 miss → `404`. Success headers:
- `Content-Type` by extension: `.html` `text/html; charset=utf-8`, `.txt` `text/plain; charset=utf-8`, `.webp` `image/webp`, `.zip` `application/zip`, `.json` `application/json`, else R2 `httpMetadata.contentType` or `application/octet-stream`.
- `Access-Control-Allow-Origin: {APP_ORIGIN}`, `X-Content-Type-Options: nosniff`, `Content-Security-Policy: default-src 'none'; img-src 'self' data:; style-src 'unsafe-inline'; sandbox`.
- Public: `Cache-Control: public, max-age=86400, immutable`. Private: `Cache-Control: private, no-store`.
- `ETag` from R2; honour `If-None-Match` (304) where cheap. `Content-Length` set.

## 11. Imports & exports

### 11.1 `POST /v1/imports` (multipart/form-data)
Fields: `file` (File, ≤20 MiB → else 413), `format` = `pocket_csv | pocket_html | instapaper_csv | netscape_html`. Not multipart → 415.
Response **`202 {"job": Job}`**; poll `GET /v1/imports/:id` → `200 {"job": Job}` (404 if not the caller's job) until `done`/`failed`.
Server: store file at `uploads/{userId}/{jobId}`, create D1 `jobs` row (`kind:"import"`), process in `ctx.waitUntil` (parse file → rows → `item.add` ops with deviceId `"import"`, `source:"import"`, `onDuplicate:"merge"`, `savedAt` from file, `status`, `isFavorite`, `tags`; applied in DO batches of ≤200 via applyOps; update `jobs.done` after each batch; then enqueue ParseJobs for newly created items, newest first, ≤100 per `sendBatch`). Invalid URLs are counted in `skipped`. Max 50 000 rows.
Formats:
- `pocket_csv`: header `title,url,time_added,tags,status` (`time_added` unix s, `tags` `|`-separated, `status` `unread`|`archive`). A `.zip` containing one or more such CSVs (Pocket's 2025 export) is also accepted for this format (detect by `PK\x03\x04` magic; unzip with fflate).
- `pocket_html`: `ril_export.html` — `<h1>Unread</h1><ul><li><a href="URL" time_added="SECS" tags="a,b">Title</a>` … `<h1>Read Archive</h1>` → archived.
- `instapaper_csv`: header `URL,Title,Selection,Folder,Timestamp[,Tags]`; Folder `Unread` → unread, `Archive` → archived, `Starred` → favorite (unread), any other folder → unread + tag = folder name; `Tags` (if present) is a JSON array string.
- `netscape_html`: `<DT><A HREF="URL" ADD_DATE="SECS" TAGS="a,b">Title</A>` → unread; folder (`<H3>`) names are ignored.

### 11.2 `GET /v1/exports?format=csv|json`
Direct download (no job in this build). All live items, newest first. `Content-Disposition: attachment; filename="sroka-export-YYYY-MM-DD.{csv|json}"`.
- `csv` (`text/csv; charset=utf-8`): header `title,url,time_added,tags,status,favorite` (Pocket-compatible + favorite): `time_added` unix seconds, `tags` joined with `|`, `status` `unread|archive`, `favorite` `0|1`. RFC 4180 quoting.
- `json` (`application/json`): `ExportJson` `{"format":"sroka-export","version":1,"exportedAt":…, "items":[ExportItem…]}`.

## 12. Account, me, config

- `GET /v1/me` → `200 MeResponse` `{"user":{"id","email","name","emailVerified","createdAt"},"stats":{"unread":12,"archived":340,"favorites":8,"tags":21}}`.
- `DELETE /v1/account` body `{"confirm":"DELETE"}` (else 400) → `200 {"deleted":true}`. Server: DO `destroy()` (`ctx.storage.deleteAll()`), delete R2 prefixes `private/{userId}/`, `raw/{userId}/`, `uploads/{userId}/` (list+delete, may continue in `waitUntil`), D1 `jobs` rows, Better Auth user (sessions, accounts, verifications). Shared `content/` is left for GC. Client then signs out locally.
- `GET /v1/config` (**no auth**) → `200 ConfigResponse` = KV `CONFIG` key `"config"` (JSON) merged over defaults:
  `{"minVersions":{"android":null,"ios":null,"extension":null},"features":{"imports":true,"exports":true,"browserRender":false,"highlights":false,"realtime":false},"limits":{"maxOpsPerPush":500,"maxHtmlBytes":5242880,"maxImportBytes":20971520}}`. `Cache-Control: public, max-age=300`.
- `GET /v1/health` (no auth) → `200 {"ok":true}`.

## 13. URL normalization (`normalizeUrl`)

1. Only `http:`/`https:` → else `invalid_url`. Input trimmed.
2. Scheme + host lowercased (WHATWG URL; IDN → punycode); trailing dot on host removed.
3. Default ports dropped (`:80` http, `:443` https).
4. Userinfo removed. Fragment removed.
5. Tracking params removed (name case-insensitive): `utm_*`, `fbclid`, `gclid`, `dclid`, `gbraid`, `wbraid`, `msclkid`, `mc_eid`, `mc_cid`, `igshid`, `ref_src`, `_hsenc`, `_hsmktg`, `yclid`.
6. Remaining params sorted by name (stable for repeated names); empty query removed; re-serialized with `URLSearchParams` (space → `+`).
7. Path kept as-is — **trailing slashes are not stripped** (`/a` ≠ `/a/`); empty path → `/`.
8. `www.` is kept; `http` is not upgraded.
`url_hash = sha256_hex(canonical)`. Example: `HTTPS://Example.COM:443/Path?utm_source=x&b=2&a=1#top` → `https://example.com/Path?a=1&b=2`.

## 14. Limits & rate limits

| Limit | Value |
|---|---|
| ops per push | 500 |
| pull page | default 500, max 1000 |
| list page | default 30, max 100 |
| URL length | 4096 |
| title length | 1000 |
| tag name | 1–64 chars; ≤100 tags per item |
| search `q` | ≤200 chars |
| `html` in save | 5 MiB (body 6 MiB) |
| import file | 20 MiB, 50 000 rows |
| clock skew clamp | now + 5 min |
| tombstone retention | 180 days |
| applied_ops retention | 30 days |
| signed URL TTL | 24 h (rounded up to the hour) |

Rate limits (clients must handle `429` + `Retry-After` with backoff): Better Auth global 100 req/min/IP (`storage:"database"`), email-OTP plugin 3/min per IP+path. `/v1` per-user soft limits (MAY be enforced via DO counters): `POST /v1/items` 120/min, `POST /v1/sync/push` 60/min, `POST /v1/imports` 10/day.

## 15. Storage notes for implementers

- **LibraryDO** schema = design §7.1 plus: `items.user_title TEXT` (user override; wire `title = user_title ?? title`), `items.domain TEXT` (host without `www.`, for the `domain` filter), an integer key for FTS (`fts_rowid INTEGER` unique, or use the implicit `rowid`), `applied_ops.alias TEXT`, `meta` keys `seq`, `tombstone_horizon`. `item_tags` index on `(tag_id)`. Migrations via `PRAGMA user_version`.
- **D1** `jobs` = design §7.2 plus `format TEXT`, `skipped INTEGER NOT NULL DEFAULT 0`. `content` as in design §7.2.
- DO public RPC surface used by others: `applyOps(deviceId, ops: Op[]) → PushResponse`, `pull(cursor, limit) → PullResponse` (lead image URLs signed by the API layer or the DO with env secrets), `markParsed(itemId, ParseResult) → {ok}`, `destroy()`. List/get/tags/suggestions/stats/export helpers are internal to `workers/api`.
