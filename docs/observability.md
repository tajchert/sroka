# Observability

Cloudflare-native logs, traces, metrics and alerts for `sroka-api` and `sroka-parser`. Design: `docs/sroka-system-design.md` §16.

## What is wired

| Piece | Where | Notes |
|---|---|---|
| Workers Logs + invocation logs + traces | `observability` in `workers/{api,parser}/wrangler.jsonc` | `enabled`, `head_sampling_rate: 1`, `logs.{enabled,invocation_logs}`, `traces.enabled` |
| Structured logger | `packages/shared/src/log.ts` (`log.info/warn/error/exception`) | one JSON line per call; sensitive keys redacted, emails masked (`j***@example.com`), `Bearer ...` scrubbed |
| Metrics | Analytics Engine dataset `sroka_events`, binding `METRICS` (both Workers) | `packages/shared/src/metrics.ts` `writeMetric` — a missing binding is a no-op |
| Request logging + errors | `workers/api/src/middleware/logging.ts` | `http_request` line per request, `onError` -> `500 {error:"internal", requestId}` |
| Client errors | `POST /v1/client-errors` (docs/api.md §12), `apps/web/src/lib/error-reporting.ts` | window.onerror, unhandledrejection, React error boundary; max 10 per session, deduped |

Never logged: OTPs (except the `ENVIRONMENT=development` console line used by local e2e), secrets, cookies, full tokens, article content/HTML, clear-text emails, URL paths of saved articles (parser logs the domain only).

### Log events (field `event`)

API: `http_request` (api/auth routes always; assets, SPA, `/v1/health` and the content host only if status >= 500 or >= 1.5 s), `unhandled_error`, `client_error`, `otp_send_failed`, `account_delete` (`step`: start / library_destroyed / d1_deleted), `account_r2_wipe_failed`, `import_failed`, `import_upload_failed`, `import_workflow_create_failed`, `queue_send_failed`, `sweep_schedule_failed`, `sync_rejected` (count `byReason`), `do_op_failed`, `do_alarm_sweep`, `do_r2_cleanup_failed`, `config_read_failed`, `stats_failed`.
Parser: `parse` (domain, status, error, source capture|refresh|fetch, durationMs, bytes, images, cacheHit, parserVersion, attempts), `parse_retry` (warn), `dlq` (warn), `mark_parsed_failed`, `dlq_mark_failed`, `gc_sweep`, `gc_throttle_cleanup_failed`, `cache_lookup_failed`, `build_content_failed`.
Common fields: `level`, `msg`, `event`, `requestId` (= `cf-ray`, also in the `x-request-id` response header and in the 500 body), `userHash` (SHA-256 prefix of the user id), `route` (pattern, no ids), `colo`.

### Analytics Engine layout

`blob1` is always the event name; `index1` is the sampling key.

| event | blob2.. | double1.. | index |
|---|---|---|---|
| `parse` | domain, status (ok/partial/failed), error code, source, cache (hit/miss) | durationMs, bytes, images | domain |
| `save` | source, result (ok / reject reason) | | `save` |
| `sync_push` | ok / rejected | ops, applied, rejected | `sync_push` |
| `otp_send` | otp type, ok / failed | | `otp_send` |
| `error` | route, error name | | route |
| `client_error` | path, release | | `client_error` |

## Viewing logs

- Dashboard: Workers & Pages -> `sroka-api` (or `sroka-parser`) -> **Observability** -> *Events* (log search) / *Investigate* (query builder) / *Traces*. Account-wide: Compute -> Workers -> **Observability**.
- Live tail: `npx wrangler tail sroka-api --format pretty` (add `--search "client_error"`, `--status error`, `--sampling-rate 0.1`). Parser: `npx wrangler tail sroka-parser --format pretty`.
- Support flow: the user quotes the `requestId` from the error (it is the cf-ray) -> Observability query `requestId = <id>`.

Query builder examples (Observability -> Investigate -> Add filter; keys are the JSON fields):

- All errors: `level = error`
- One request: `requestId = 8f1c2e3d4a5b6c7d-WAW`
- Parse failures for a site: `event = parse` AND `status = failed` AND `domain = example.com`
- Slow requests: `event = http_request` AND `durationMs > 1500`
- Rejected sync ops: `event = sync_rejected`
- Client JS errors: `event = client_error` (group by `release` or `clientPath`)
- Visualise: Calculation `count`, Group by `route`, filter `level = error`.

## Analytics Engine SQL

Needs an API token with **Account Analytics: Read**. Dataset name = `sroka_events`.

```sh
export CF_ACCOUNT_ID=...; export CF_API_TOKEN=...
sql() { curl -s "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID/analytics_engine/sql" \
  -H "Authorization: Bearer $CF_API_TOKEN" --data "$1"; }

# Parse success rate by domain, last 7 days (worst first, min 5 jobs)
sql "SELECT blob2 AS domain, SUM(_sample_interval) AS jobs,
       SUM(IF(blob3 = 'failed', _sample_interval, 0)) AS failed,
       round(100 * SUM(IF(blob3 = 'failed', 0, _sample_interval)) / SUM(_sample_interval), 1) AS success_pct
     FROM sroka_events
     WHERE blob1 = 'parse' AND timestamp > NOW() - INTERVAL '7' DAY
     GROUP BY domain HAVING jobs >= 5 ORDER BY success_pct ASC LIMIT 25 FORMAT JSON"

# Top parse error codes
sql "SELECT blob4 AS error, SUM(_sample_interval) AS n FROM sroka_events
     WHERE blob1 = 'parse' AND blob3 = 'failed' AND timestamp > NOW() - INTERVAL '7' DAY
     GROUP BY error ORDER BY n DESC LIMIT 20 FORMAT JSON"

# Parse p50/p95 duration (ms)
sql "SELECT quantileWeighted(0.5, double1, _sample_interval) AS p50, quantileWeighted(0.95, double1, _sample_interval) AS p95
     FROM sroka_events WHERE blob1 = 'parse' AND blob6 = 'miss' AND timestamp > NOW() - INTERVAL '1' DAY FORMAT JSON"

# Errors per route, last 24 h
sql "SELECT blob2 AS route, blob3 AS error, SUM(_sample_interval) AS n FROM sroka_events
     WHERE blob1 = 'error' AND timestamp > NOW() - INTERVAL '1' DAY GROUP BY route, error ORDER BY n DESC FORMAT JSON"

# OTP send failures per hour
sql "SELECT toStartOfInterval(timestamp, INTERVAL '1' HOUR) AS hour, SUM(_sample_interval) AS failed
     FROM sroka_events WHERE blob1 = 'otp_send' AND blob3 = 'failed' AND timestamp > NOW() - INTERVAL '3' DAY
     GROUP BY hour ORDER BY hour FORMAT JSON"

# Saves by source
sql "SELECT blob2 AS source, SUM(_sample_interval) AS saves FROM sroka_events
     WHERE blob1 = 'save' AND blob3 = 'ok' AND timestamp > NOW() - INTERVAL '7' DAY GROUP BY source FORMAT JSON"
```

Grafana can use the same SQL API (ClickHouse-style datasource) for dashboards.

## Recommended alerts (dashboard steps)

1. **Worker error rate.** Dashboard -> Notifications (account home -> *Notifications*) -> **Add** -> product *Workers* -> **Workers Usage / Error rate** (name it `sroka-api errors`) -> choose Worker `sroka-api`, threshold e.g. error rate > 2% over 5 min -> add recipients (email / webhook / Slack) -> Save. Repeat for `sroka-parser`.
2. **Log-based alert (Observability).** Workers & Pages -> `sroka-api` -> Observability -> Investigate -> filter `level = error` -> *Create alert* (or save the query, then Notifications -> Add -> *Workers Observability*), condition `count > 10 in 5 min`. Suggested queries: `event = unhandled_error`; `event = otp_send_failed` (any in 15 min); `event = queue_send_failed`; `event = dlq`.
3. **Queue DLQ backlog.** Notifications -> Add -> product *Queues* -> **Queue backlog** (or *Queue consumer errors*) -> select queue `sroka-parse-dlq`, threshold backlog > 0 for 15 min (the DLQ consumer normally drains it, so a persistent backlog means the DLQ consumer is failing) and a second one on `sroka-parse` with backlog > 500 messages or oldest message age > 10 min.
4. **Parse failure rate.** Not a native alert: run the "parse success rate" SQL above from a scheduled job (cron or Grafana alert rule), alert when `success_pct` for all domains drops below ~85%.
5. Optional: Workers **Issues** (Observability -> Issues) groups errors automatically (`observability.issues` can be enabled in wrangler.jsonc if not on by default).

## Config notes

- `head_sampling_rate: 1` logs everything; lower it (e.g. 0.1) in `observability.logs` if Workers Logs volume/cost grows (invocation logs count too).
- Deploy: bindings + dataset are created on first `wrangler deploy` (Analytics Engine must be enabled once in the dashboard: Workers & Pages -> Analytics Engine -> Enable).
- Local dev / tests: no `METRICS` data is stored locally; `writeMetric` is a no-op when the binding is missing.
