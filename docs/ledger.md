# Progress ledger

| Step | Status | Commit / notes |
|---|---|---|
| Research (auth, email, DO, parser, ext) | done | docs/research/*.md |
| Decisions + CLAUDE.md | done | |
| Foundation: root workspace, packages/shared, docs/api.md | done | d120a37 — deps all installed; react-router pinned 7 (D2); vitest workers need fsModuleCache:false |
| API worker (auth, LibraryDO, /v1, content route) | done | feat/api-platform + feat/api-core merged (c55230c, 8831d2e); docs/handoff/api-*.md |
| Extractor + parser worker | done | feat/parser merged (a26e690); docs/handoff/parser.md |
| Web app | done | feat/web merged (7e50801); docs/handoff/web.md |
| Extension | done | feat/extension merged (114d059); docs/handoff/extension.md |
| Import/export | in progress | separate agent (routes/imports.ts, exports.ts, src/import/**); e2e skips exports while the route is a stub |
| Integration + local e2e | done | fix/integration — dev launcher without routes (wrangler dev URL/Origin rewrite bug), dev-setup, `scripts/e2e-local.sh` all green; docs D3/D5/D6/D8 + api.md contract issues reconciled |
| Cloudflare resources + deploy | todo | |
| Review + fixes | todo | |
| Security hardening (adversarial review) | done | "fix: security hardening" — DO tombstone on destroy, parse budget + refresh coalescing, parseWanted pre-checks, one result per gen, sweep keeps gen, R2 cleanup on delete/re-parse, bounded seq groups, stale tag ops, shared-cache key/partial rules, image memory budget, per-email OTP throttle (`auth_throttle`, migration 0001), session cookie refresh, atomic import reservation, owner-scoped extension queue, Reader re-sign reload, mailto links, weekly parser GC of deleted users' R2 data |

| Observability | done (branch feat/observability) | structured logger (`@sroka/shared` log.ts/metrics.ts), request logging + onError requestId, parser per-job `parse` log, Analytics Engine `METRICS`/`sroka_events`, `/v1/client-errors` + web reporting, `docs/observability.md`. Deploy: enable Analytics Engine in dashboard once; set up alerts per doc |
| Shared-content GC | done (not deployed) | feat/content-gc — LibraryDO content-ref outbox (DO schema v3) → D1 `content_refs` (migration 0002), content row for every public dir, cache-hit touch, weekly cron backfill (operator-started) + GC of unreferenced content after 30 days. Production rollout steps: workers/parser/CLAUDE.md "Shared-content GC" |
| Browser Run fallback + site rules + parse attempts (parser side of D10) | done (not deployed) | feat/render-rules — `BROWSER` binding + budgets (`render_budget`), bot-wall detection, KV site rules (60 s cache), `parse_attempts` rows + extended `parse` metric/log, weekly purge; migration 0003_parse_attempts. Rollout: workers/parser/CLAUDE.md "Browser Run + site rules". Admin API/UI: separate branch |
| Android app (`apps/android`) | done (branch feat/android) | Native Kotlin/Compose client: Room v1 + FTS4 local library, pending-ops outbox + push/pull sync (410 resync), offline article packages via WorkManager with progress, share target, WebView reader, settings. Ledger `apps/android/docs/LEDGER.md`. Open: device e2e vs local stack, review pass, branding |

## Open items
- Shared-content GC deployed 2026-10-15 (migration 0002 applied, backfill started via gc_state). The Sunday cron re-emits refs and sets gc_backfill_done; verify afterwards: `select * from gc_state; select count(*) from content_refs;`
- Legacy public `content/{id}/` dirs written before migration 0002 without a D1 row (partial parses, non-canonical URLs, failed row inserts) are not collected (no R2-listing sweep).
- Account deletion R2 wipe runs once in `waitUntil`; the weekly parser cron (`src/gc.ts`) is the retry. A Workflow/queue-based wipe would be faster.
- FTS rewrite of a huge tag rename still runs in one transaction.

## Deploy (2026-10-15)
- Remote D1 migrations 0000, 0001 applied; secrets BETTER_AUTH_SECRET, CONTENT_URL_SIGNING_KEY set on sroka-api.
- sroka-api deployed with custom domains sroka.app, api.sroka.app, c.sroka.app; sroka-parser deployed (consumers sroka-parse + DLQ, cron `23 4 * * SUN`).
- Apex A records (parking) deleted by owner. Production smoke: landing, /app, SPA deep link, /v1/health, /v1/config, CORS preflight OK.
- RESOLVED: api.sroka.app / c.sroka.app now resolve (Cloudflare NS, 1.1.1.1, 8.8.8.8); /v1/config 200 over https.
- Redeployed sroka-api from main (version 415b1efd) with the `full=1` sync pull flag (50501a7) needed by Android full resync; smoke /v1/config 200, /v1/sync/pull unauthenticated 401.
- OPEN: real email OTP sign-in in production not yet exercised; shared-content GC built on feat/content-gc, not deployed yet.
- 2026-10-16 Paywalls: parser marks teaser saves `partial`/`paywalled` (774d657, deployed); extension auto-captures rendered HTML on paywalled pages (de57db8). Verified live on a Medium member-only article: capture → ok, 6,974 chars.
- 2026-10-23 New landing page (Claude Design 'Sroka Landing' + mobile) and brand icon 6a everywhere (d8eacc0). sroka-api redeployed (version 4d168654); smoke: /, /icon.svg, /app/, /v1/config all 200. Extension zip and Android build need re-publishing to pick up the new icons. OPEN: landing store links (Chrome/App Store/Play) and Privacy/Terms/Contact are placeholders.
