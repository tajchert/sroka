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

## Open items
- Shared public content GC: `content.ref_count` is never decremented (item delete, re-parse, account delete) and no cron collects `content/{id}/` dirs or superseded rows. Needs DO-reported content changes (or a DO scan) before a ref_count==0 rule is safe.
- Account deletion R2 wipe runs once in `waitUntil`; the weekly parser cron (`src/gc.ts`) is the retry. A Workflow/queue-based wipe would be faster.
- FTS rewrite of a huge tag rename still runs in one transaction.

## Deploy (2026-10-15)
- Remote D1 migrations 0000, 0001 applied; secrets BETTER_AUTH_SECRET, CONTENT_URL_SIGNING_KEY set on sroka-api.
- sroka-api deployed with custom domains sroka.app, api.sroka.app, c.sroka.app; sroka-parser deployed (consumers sroka-parse + DLQ, cron `23 4 * * SUN`).
- Apex A records (parking) deleted by owner. Production smoke: landing, /app, SPA deep link, /v1/health, /v1/config, CORS preflight OK.
- OPEN: api.sroka.app / c.sroka.app return NXDOMAIN at the authoritative NS although the Worker custom domains are attached (edge serves them fine via --resolve). Need proxied DNS records (AAAA 100::) or a dashboard re-attach.
- OPEN: real email OTP sign-in in production not yet exercised; shared-content GC (ref_count decrement) not built.
