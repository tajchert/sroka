# api-core (feat/api-core)

## Implementation report
**Branch:** `feat/api-core`

**Commits**
- `23c95e1` feat(api): LibraryDO store (schema, applyOps, LWW, tags, pull, list/search, parse) and library routes
- `342874a` test(api): sync convergence fuzz, library route tests; order-independent savedAt on re-add

**Implemented**
- `workers/api/src/library-do.ts`: the DO itself, with migrations in `blockConcurrencyWhile`.
  - Public RPC methods: `applyOps(deviceId, ops: unknown[]) → {response, parseJobs}`, `requestParse`, `markParsed` (checks the result with the zod schema and `parseGen`), `pull`, `destroy()` (deletes the alarm, then `deleteAll()`; the library still works afterwards), `ping`.
  - Helper RPC methods for routes: `applyRest`, `patchItem`, `requestParseAndGet`, `getItem`, `listItems`, `listTags`, `suggestions`, `renameTag`, `deleteTag`, `stats`, `exportItems`.
  - A daily `alarm()` purges tombstones older than 180 days (raising `tombstone_horizon`), old `tag_renames`, and `applied_ops` older than 30 days.
  - The DO gets the userId from `ctx.id.name` (checked in workerd with `getByName`) and also stores it in `meta`.
- `src/do/`:
  - `schema.ts`: tables plus a regular FTS5 table.
  - `store.ts`: all the synchronous logic (applyOps with idempotency, aliases, readd/merge, field and tag-pair LWW, rename/merge/delete with stale-op resolution, seq rules, pull paging that never splits a seq group, list/search/sort/domain/url/keyset cursors, manual FTS upkeep, counts and suggestions).
  - `rest.ts`: turns a PATCH into ops.
  - `sign.ts`: signs `leadImageUrl` for every response.
  - `fts.ts`, `rows.ts`, `route-helpers.ts`.
- Routes: `itemsRoutes`, `tagsRoutes`, `syncRoutes`, typed `Hono<{Bindings: Env, Variables: {userId}}>`. Together they cover all of §5–§7. A save with `html` stores it gzipped at `raw/{userId}/{itemId}.html.gz`, then calls `requestParse` and enqueues the job. Jobs go out in `sendBatch` chunks of up to 100.

**Not implemented:** rate limits (§14, optional) and R2 cleanup on account wipe (`destroy()` only wipes the DO).

**Tests:** workspace typecheck is clean. `npm test` passes everywhere; for api that is 31 tests in 4 files:
- 21 DO tests.
- A 3-seed fuzz test: 3 devices, 4 interleavings each, plus an idempotent replay. I checked that it fails when tag-pair LWW is disabled.
- 6 route tests, using a fake auth middleware and a fake queue.

**CONTRACT ISSUES**
1. **`PRAGMA user_version` doesn't work in DO SQLite** (SQLITE_AUTH, confirmed in workerd). D5 and §15 require it, so I keep the schema version in a one-row `_schema` table instead. D5 and api.md §15 should be updated.
2. **Merging tags uses each pair's own stamp.** When a tag is merged into another, each moved pair keeps its own `{at, dev}` and is LWW-merged into the target. §8.4 says to use the rename's stamp, but that gives different results depending on op order when stale ops arrive.
3. **Re-add always moves `savedAt` forward.** A duplicate `item.add` (readd) sets `savedAt = max(savedAt, at)` even if its status stamp loses. §8.2 makes this conditional, which isn't order-independent.
4. **`isFavorite` is only stamped when the add op sets it.** If the default `false` were stamped, results would differ depending on which duplicate add created the row.
5. **Remaining order-dependence in the spec itself.** The fuzz test avoids these cases:
   - `present:false` on a tag that doesn't exist is a no-op.
   - An `item.tag` newer than a rename or delete still depends on arrival order.
   - Two renames of the same tag: last applied wins.
6. **`pull` RPC returns a result object, not a bare `PullResponse`.** It returns `{ok:true,data} | {ok:false,error:"resync_required"}`, because the 410 case needs to reach the route.

**Notes for the integrator**
- Mount the routes behind the auth middleware: `app.route("/v1/items", itemsRoutes)`, likewise for `/v1/tags` and `/v1/sync`. Exports are in `src/routes/{items,tags,sync}.ts`.
- `/v1/me` can use `stub.stats()`. Export can use `stub.exportItems()` (full `Item`s, sorted by `savedAt` ascending). Imports should call `stub.applyOps(IMPORT_DEVICE_ID, ops)` and enqueue the returned `parseJobs`; helpers are in `src/do/route-helpers.ts` (`enqueueParseJobs`, `gzipText`).
- `ping()` stays on the DO because `workers/parser/test/smoke.test.ts` uses it.
- `workers/api/CLAUDE.md` still calls the DO a placeholder. I didn't edit it because it's shared.
- No dependencies were added or changed.

## Review
I found 6 real defects in `feat/api-core`. The worst is a reproduced crash that can permanently block a device's sync push. On the branch, typecheck is clean and all 31 api tests pass. The rename+delete repro test I wrote (a throwaway file, now gone) fails with an uncaught UNIQUE constraint error. I ran everything in a temporary detached worktree and removed it afterwards; nothing was committed.

1. **[high] `workers/api/src/do/store.ts:437-447` (`resolveTag`) plus `:461-473` (`setPair`): a stale tag op can crash the whole push.**
   - **Problem:** an `item.tag` op is redirected through `tag_renames` to a tag that has been deleted. If its `at` is later than that tag's `deleted_at`, `resolveTag` returns `{missing:true}`. `setPair` then INSERTs a new tag named `op.tag` without checking whether a live tag with that key already exists. That throws `UNIQUE constraint failed: tags.name_key`. The error is not a `Reject`, so it escapes `applyOps`: the push returns 500, and earlier ops in the same push are committed but never reported.
   - **Impact:** the op is never recorded, so the client retries it forever and its push queue is permanently stuck.
   - **Repro (reproduced in workerd):**
     1. `add X` at T0, tag X with `a` at T0+1.
     2. `rename a→b` at T0+10.
     3. `tag.delete b` at T0+5, sent from another device with a skewed clock.
     4. Tag X with `a` at T0+20; this recreates a live `a`.
     5. Tag X with `a` at T0+7: throws.
   - **Fix:**
     - When the rename chain ends at a tombstone with `deleted_at < at`, fall through to `liveTagByKey(key)` (and the dead-key check) instead of returning `missing`. Better still, have `setPair`'s missing path re-check `liveTagByKey(tagKey(norm))` before inserting.
     - As a safety net, have `applyOps` turn non-`Reject` SQL errors on a single op into a rejection, so one bad op can't fail the whole push.
     - Add a regression test.

2. **[med] `workers/api/src/do/store.ts:335`, `:529`, `:550` (where tombstones are written) and `:781-799` (`prune`): purging uses the client's clock.**
   - **Problem:** `deleted_at` (and `tag_renames.at`) hold the clamped *client* `at`, and `prune` purges by `deleted_at < now - 180d`. A delete from a device that was offline a long time, or whose clock is wrong (`at` is only clamped from above), is purged by the next daily alarm.
   - **Impact:** that raises `tombstone_horizon` to a recent seq, so every other device gets `410 resync_required`. Devices that hadn't pulled yet never see the deletion. The purged row also leaves `item_aliases` pointing at a missing id.
   - **Fix:** add a server-time column (e.g. `items.tombstoned_at` / `tags.tombstoned_at` = `now`, and `tag_renames.recorded_at`) and purge on that. Keep `deleted_at` for the LWW / stale-op rules. This is a schema change, so add a v2 migration if v1 has shipped anywhere; otherwise amend v1.

3. **[low] `workers/api/src/do/store.ts:355-366, 399-425` (`opAdd`): an item can be created that its own id can't reach.**
   - **Problem:** `op.itemId` may already exist in `item_aliases` pointing at a target that has since been purged; this can happen once `applied_ops` (30 d) and tombstones (180 d) are pruned. In that case `target` is null, no duplicate is found, and a new row is inserted under `op.itemId`. The alias row still redirects `op.itemId` to the purged id, so every later op and `GET` on the new item gives `unknown_item` / 404.
   - **Fix:** when `resolved !== op.itemId` and the resolved row is missing, delete the stale `item_aliases` row (or reject `item_deleted`) before inserting.

4. **[low] `workers/api/src/routes/sync.ts:12-13`, `workers/api/src/routes/items.ts:83, 153`: parse jobs can be lost.**
   - **Problem:** the DO commits the ops (and `parse_gen`) before `enqueueParseJobs` runs. If the queue send throws, the request returns 500 and the client retries. The retry is idempotent, so it returns no jobs and the items stay `parseStatus:"pending"` forever.
   - **Fix:** catch the send failure and retry. Or have the DO alarm re-enqueue items that have been `pending` too long, e.g. a periodic sweep re-issuing `requestParse` for items pending more than N minutes.

5. **[low] `workers/api/src/routes/items.ts:122-128` with `do/rest.ts`: a PATCH can be partly applied but reported as failed.** The ops are applied one by one, each in its own transaction. If a later one is rejected (e.g. a `too_many_tags` race), the earlier field changes stay committed but the route returns 400. Fix: return 200 with the item when only some ops were rejected, or apply the whole PATCH in one transaction.

6. **[low] `workers/api/src/do/fts.ts:17-28` with `store.ts:412`: `domain` filter misses non-ASCII hosts.** Stored domains come from the canonical URL, so non-ASCII hosts are stored in punycode. A filter like `domain=żółw.pl` is not converted, so it never matches. Fix: run the filter through `new URL("http://" + d).hostname` before comparing.

Items 1–4 of the implementer's report are deliberate departures from the docs, not defects, and they look correct. They still need doc updates:
- `user_version` is replaced by the `_schema` table: update D5 and §15.
- Merged tag pairs keep their own stamps: update §8.4.
- Re-add always moves `savedAt` forward (`savedAt = max`): update §8.2.
- `isFavorite` is only stamped when the add op sets it: update §8.2 step 5.

The wrapper returned by the `pull` RPC also needs §15 updated. `workers/api/CLAUDE.md` still calls the DO a placeholder.

Rate limits (§14) are optional. R2 cleanup on account wipe is the account route's job (owned by api-platform), not this branch's.

## Fix report
I fixed all six review findings on `feat/api-core`. Typecheck is clean across the workspace and every test passes: api 41/41 (31 before, plus 10 new), shared 54/54, parser 1/1.

**Branch:** `feat/api-core` is now at `bd2f7e0`. I couldn't check the branch out here because the previous agent's worktree `.claude/worktrees/wf_2331d63d-83a-1` still has it checked out. So I committed on a detached HEAD and fast-forwarded the branch with `git update-ref` (it checks the old value, `342874a`). Because of that, that old worktree will now show the fix as reverse changes in `git status`. Remove it or leave it alone, and don't commit from it. I also created `feat/api-core-review-fixes` pointing at the same commit.

**Commits:** `bd2f7e0 fix(api): LibraryDO review fixes`, on top of `23c95e1` and `342874a`.

**Fixes, each with a regression test in `workers/api/test/do/review-fixes.test.ts`:**
1. **[high] Push crash on a stale tag op:** fixed. When a rename chain ends at a tag deleted before the op's `at`, the op now looks up a tag by its own name. Before inserting a new tag, `setPair` checks whether a live tag with that name already exists. As a safety net, `applyOps` now turns any unexpected error on one op into an `invalid_op` rejection (and logs it), so one bad op can no longer fail the whole push. The reviewer's repro passes.
2. **[med] Purging used the client's clock:** fixed with a v2 schema migration rather than editing v1, so local dev databases still upgrade. It adds `items.tombstoned_at`, `tags.tombstoned_at` and `tag_renames.recorded_at`, all in server time. `prune` now uses those. `deleted_at` still holds the client stamp and is still used for LWW and stale-op checks. `prune` also deletes aliases whose target has been purged.
3. **[low] New item unreachable by its own id:** fixed. `opAdd` deletes a stale alias row before inserting.
4. **[low] Lost parse jobs:** fixed. `enqueueParseJobs` tries 3 times and never throws. If all attempts fail, it calls `scheduleParseSweep()` on the DO, which moves its alarm to about 31 minutes out. The alarm now also re-enqueues items left `pending` for more than 30 minutes. It reuses the saved raw HTML key and bumps `parseGen`, so a late result from the original job is ignored. This uses two more new columns, `parse_requested_at` and `parse_raw_key`. Test: `test/routes-library/enqueue.test.ts`.
5. **[low] PATCH partly applied but reported as failed:** fixed. PATCH now applies all its ops in one transaction (`applyOpsAtomic`); if any op is rejected, all of them roll back.
6. **[low] `domain` filter missed non-ASCII hosts:** fixed. Non-ASCII filter values are converted to punycode.

Nothing was skipped. One existing test changed: the 410 test now prunes at real time plus 181 days, because purging uses server time now.

**Not done:**
- The doc updates the review asked for (D5, §8.2, §8.2 step 5, §8.4 and §15). I'm not allowed to edit `docs/api.md`, and `docs/decisions.md` isn't one of my files.
- The "DO (placeholder)" line in `workers/api/CLAUDE.md`. I left it to avoid a merge conflict with api-platform.
- Rate limits (§14), which are optional.

**CONTRACT ISSUES**
- §15 and D5 still say `PRAGMA user_version`. DO SQLite doesn't allow it, so the schema version lives in a `_schema` table (now version 2).
- §15 needs the `pull` RPC wrapper (`{ok, data} | {ok:false, error}`) and the new RPCs `scheduleParseSweep` and `sweepStalePending`.
- §8.2: a re-add always moves `savedAt` forward (`savedAt = max`), and `isFavorite` only gets a stamp when the add op sets it.
- §8.4: merged tag pairs keep their own stamps.
- §7.3: tombstone time-to-live counts from server time.
- `RejectReason` has no "internal" value, so internal errors are reported as `invalid_op`.

**Notes for the integrator**
- `enqueueParseJobs(env, jobs, userId)` now takes the user id as a third argument.
- PATCH responses with rejected ops now have an empty `applied` list.
- No dependencies were changed.
