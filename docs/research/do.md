# Brief: Durable Objects (SQLite), Queues, Static Assets, Routes, Vitest

Today is 2026-10-14. "Verified" means I ran it in a throwaway project at `/private/tmp/claude-501/sroka-research/do-sqlite` with wrangler dev. "Docs" means I read it in the official Cloudflare docs. Anything else is marked unverified.

## Versions (`npm view`)
- wrangler 4.151.0
- hono 4.13.13
- drizzle-orm 0.45.4
- vitest 5.0.4
- @cloudflare/workers-types 5.20261014.1 (or use `wrangler types`, which generates `worker-configuration.d.ts` and `Env`)
- **`@cloudflare/vitest-pool-workers` 0.23.0 is deprecated.** npm says it was renamed to **`@cloudflare/vitest-plugin` 1.4.2**, with peer dependency `vitest ^4.1.0 || ^5.0.0`. Use the plugin.

## 1. DO with SQLite: config and code

```jsonc
{
  "name": "sroka",
  "main": "src/index.ts",
  "compatibility_date": "2026-10-01",
  "compatibility_flags": ["nodejs_compat"],
  "durable_objects": { "bindings": [{ "name": "LIB", "class_name": "Library" }] },
  "migrations": [{ "tag": "v1", "new_sqlite_classes": ["Library"] }]
}
```
Verified: this runs. Later class changes need new tags, for example `renamed_classes` or `deleted_classes`. Never edit an old tag.

```ts
import { DurableObject } from "cloudflare:workers";
export class Library extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.blockConcurrencyWhile(async () => { this.migrate(); });
  }
  add(title: string, body: string) {            // public methods are RPC methods
    return this.ctx.storage.transactionSync(() => {
      const r = this.ctx.storage.sql.exec(
        `INSERT INTO items(title,body) VALUES(?,?) RETURNING id`, title, body).one();
      this.ctx.storage.sql.exec(`INSERT INTO items_fts(rowid,title,body) VALUES(?,?,?)`, r.id, title, body);
      return r.id as number;
    });
  }
  search(q: string) {
    return this.ctx.storage.sql.exec(
      `SELECT i.id,i.title,bm25(items_fts) r FROM items_fts JOIN items i ON i.id=items_fts.rowid
       WHERE items_fts MATCH ? ORDER BY r LIMIT 10`, q).toArray();
  }
}
// Worker side
const stub = env.LIB.getByName(userId);   // verified; or env.LIB.get(env.LIB.idFromName(userId))
await stub.add("t", "b");                 // RPC, typed
```

**Schema migrations.** Keep a `PRAGMA user_version` (or a `_migrations` table). In `blockConcurrencyWhile`, run the pending steps in order, each inside `transactionSync`. Verified: the constructor-time `CREATE TABLE IF NOT EXISTS` plus an fts5 virtual table works. The versioned-migration pattern itself is standard but I did not run it.

**API facts (docs):**
- `sql.exec(query, ...bindings)` returns a cursor with `toArray()`, `one()` (throws on 0 or more than 1 rows), `raw()`, `next()`, `rowsRead`, `rowsWritten`, and `columnNames`.
- With several statements in one `exec`, bindings apply only to the last one.
- `exec` cannot run `BEGIN` or `SAVEPOINT`. Use `transactionSync(cb)` (sync callback only; a throw rolls back).
- `ctx.storage.sql.databaseSize` is a read-only property.
- Consume cursors synchronously with `toArray()` before any `await`. There is no snapshot isolation across awaits.
- **`deleteAll()` deletes the whole SQLite database (SQL and KV), atomically.** For compatibility date 2026-02-24 or later it also deletes the active alarm. Older dates need `deleteAlarm()` or the `delete_all_deletes_alarm` flag.
- PITR is available: `getCurrentBookmark()`, `getBookmarkForTime()`, `onNextSessionRestoreBookmark()` followed by `ctx.abort()`. It covers the last 30 days and is not supported in local dev.

## 2. FTS5: verified
- **FTS5 works in DO SQLite.** The docs list the FTS5 module, fts5vocab, JSON functions and math functions as supported.
- I created an external-content table with `CREATE VIRTUAL TABLE items_fts USING fts5(title, body, content='items', content_rowid='id')`. An insert plus `MATCH` plus `bm25()` returned `[{"id":1,"title":"Hello world","r":-0.000001}]`.
- **Gotcha:** with `content='items'`, FTS5 does not update itself. You must write to `items_fts` yourself on every insert, update and delete. Either add SQL triggers, or use the `'delete'` command form: `INSERT INTO items_fts(items_fts,rowid,title,body) VALUES('delete',...)`. I did the manual insert inside `transactionSync`. Triggers and the delete command are unverified.
- User-supplied search text can break MATCH syntax. Quote it, for example `"term"*`, or sanitize it.

## 3. Alarms (docs-known, not run)
```ts
await this.ctx.storage.setAlarm(Date.now() + 60_000);   // one alarm per DO
async alarm(info?: AlarmInvocationInfo) { /* retried with backoff on throw */ }
```
Related calls are `getAlarm()` and `deleteAlarm()`. Make `alarm()` idempotent.

## 4. Calling a DO from a different Worker (for the parser worker)
In the caller's wrangler config, point at the Worker that exports the class:
```jsonc
"durable_objects": { "bindings": [{ "name": "LIB", "class_name": "Library", "script_name": "sroka" }] }
```
- The owning Worker keeps the `migrations` block. The caller has none.
- RPC works across scripts, so you can call `stub.add()` directly. This is unverified here.
- Docs: under `wrangler dev`, a binding with an explicit `script_name` uses persistent data, and Wrangler warns about it. Writes then hit that data.
- Run both Workers in one dev session with `wrangler dev -c wrangler.jsonc -c ../parser/wrangler.jsonc`. This is unverified.
- Alternative: use a Worker service binding with `WorkerEntrypoint` RPC. The parser then does not need DO access, and the main Worker calls the parser. This is usually simpler (unverified).

## 5. Queues

Create the queues first: `npx wrangler queues create sroka-parse` and `sroka-parse-dlq`.

Producer in the main Worker:
```jsonc
"queues": { "producers": [{ "queue": "sroka-parse", "binding": "PARSE_Q" }] }
```
Consumer, in the separate parser Worker's wrangler config. Docs say each producer and consumer Worker has its own config:
```jsonc
"queues": { "consumers": [{
  "queue": "sroka-parse", "max_batch_size": 10, "max_batch_timeout": 5,
  "max_retries": 3, "dead_letter_queue": "sroka-parse-dlq", "max_concurrency": 4 }] }
```
- Defaults per docs: `max_batch_size` 10, `max_batch_timeout` 5 seconds, `max_retries` 3. Without a DLQ, messages that keep failing are eventually discarded.
- The DLQ is created automatically if missing, per docs. It is safer to create it explicitly.
- `max_concurrency` caps parallel consumer invocations. `retry_delay` exists but I did not confirm it in the docs. Check the Wrangler configuration reference.
- Handler shape (standard, unverified here): `async queue(batch: MessageBatch<T>, env) { for (const m of batch.messages) { try { ...; m.ack() } catch { m.retry({delaySeconds: 30}) } } }`.
- Queue-level settings are changed with `wrangler queues update <name> --delivery-delay-secs N --message-retention-period-secs N`. Retention is 60 to 1209600 seconds, default 345600.

## 6. Static assets for the SPA: verified
```jsonc
"assets": {
  "directory": "./apps/web/dist",
  "binding": "ASSETS",
  "not_found_handling": "single-page-application",
  "run_worker_first": ["/api/*"]
}
```
- Verified in dev: `/api/*` reached the Worker, and `/foo/bar` returned `index.html` with 200.
- `run_worker_first` as an array needs wrangler 4.20 or later, so 4.151 is fine. Negation is supported, for example `["/api/*", "!/api/docs/*"]`.
- With a compatibility date of 2025-04-01 or later, navigation requests (`Sec-Fetch-Mode: navigate`) skip the Worker unless a pattern matches. Non-navigation `fetch()` calls still invoke the Worker.
- If the API lives only on `api.sroka.app`, the SPA host does not need `run_worker_first`. Using `/api/*` gives a same-origin API on `sroka.app`, which is simpler for cookies. In the same Worker, `c.sroka.app` and `api.sroka.app` still reach the Worker, because `run_worker_first` only affects paths.

## 7. Domains in one Worker (docs)
```jsonc
"routes": [
  { "pattern": "sroka.app",     "custom_domain": true },
  { "pattern": "api.sroka.app", "custom_domain": true },
  { "pattern": "c.sroka.app",   "custom_domain": true }
]
```
- The `sroka.app` zone must be an active zone on the account.
- Custom domains take exact hostnames only, with no wildcards and no paths in the pattern.
- Deploy fails if the hostname already has a CNAME DNS record. Delete the record first.
- Branch on `new URL(req.url).hostname` in Hono, or use `app.route` with a host check.
- Account selection: log in with `wrangler login` as mtajchert@gmail.com, or set `account_id` in the config. Unverified, since I did not deploy.

## 8. Vitest (docs)
```
npm i -D vitest@^5 @cloudflare/vitest-plugin
```
```ts
// vitest.config.ts
import { cloudflareTest } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";
export default defineConfig({
  plugins: [cloudflareTest({ wrangler: { configPath: "./wrangler.jsonc" } })],
});
```
- The `miniflare:` option overrides bindings from the wrangler config.
- Tests import `env` and `exports` from `cloudflare:workers`, and `createExecutionContext` / `waitOnExecutionContext` from `cloudflare:test`.
- Integration style: `await exports.default.fetch("http://example.com/x")`.
- `test/tsconfig.json` should use `"types": ["@cloudflare/vitest-plugin/types"]`, `"moduleResolution": "bundler"`, and include the file generated by `wrangler types`.
- The old `defineWorkersConfig` / `@cloudflare/vitest-pool-workers/config` API is deprecated with the old package. Do not use it.
- DO testing: use `env.LIB.getByName("x")` and call RPC methods directly. This is unverified here.

## Gotchas summary
- Never `await` between cursor creation and `toArray()`.
- `transactionSync` callbacks must stay synchronous.
- Do not edit old migration tags.
- `deleteAll()` is destructive. It wipes the user's entire library, including FTS tables.
- External-content FTS5 needs manual syncing.
- Under `wrangler dev`, cross-script DO bindings are read-only by default unless `script_name` is explicit, and Wrangler warns when it is.
- Use `@cloudflare/vitest-plugin`, not the deprecated pool package.
