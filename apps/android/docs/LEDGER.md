# Android progress ledger

| Step | Status | Notes |
|---|---|---|
| Template copied + adopted (`app.sroka`), baseline build green | done | |
| Foundation (strip Tasks, modules, deps, models, interfaces, fakes, nav skeleton) | done | 18d56ad |
| core:database | done | cd02cd4 — SrokaDatabase v1, FTS4, paging, 25 tests |
| core:network + core:datastore | done | 86e157d — OkHttp SrokaApi, SessionStore (Keystore AES-GCM) |
| core:data (sync, content, workers) | done | 3928914 — repositories, SyncEngine, ContentStore, workers |
| feature:auth + settings | done | b7845cd |
| feature:library + share | done | dcfd352 |
| feature:reader | done | 962282e |
| Integration gate | done | cd28e67, 55c4837 — app on core:data, ShareActivity, session nav, list-detail, brand palette; gate green; emulator launch smoke (sign-in screen, share sheet, minified build send-code) |
| Review + fixes | done | fix(android) commits up to 9eece19 + final gate commit: sync robustness, download hardening (serialized per item, storage-full → STORAGE snackbar, startup reconcile of missing package/thumb files), server-switch sign-out + warning dialog, path-safe ids, reader joins in-flight downloads. Gate green. Open (server, outside apps/android): `full=1` pull flag so a from-0 pass never hits 410 mid-pass (shared PullQuery, workers/api store.pull `!full && cursor>0 && cursor<horizon`, api.md §7.2, DO test). Deferred: recentTags collected only while tag editor open; Settings 'Storage used' excludes DB size; cancel pending background sync after user fetch; user-fetch downloads under the DOWNLOAD unique name |
| Emulator e2e vs local stack | todo | |
