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
| Review + fixes | todo | |
| Emulator e2e vs local stack | todo | |
