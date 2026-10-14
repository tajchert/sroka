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
