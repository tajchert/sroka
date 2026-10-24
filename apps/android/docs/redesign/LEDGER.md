# Redesign ledger (see RULINGS.md)

| Task | Status | Commit / notes |
|---|---|---|
| T1 theme + mark | done | Brand dark/light schemes, Outfit type, shapes, SrokaMark, ic_stat_sroka; dynamic colour off. Gate: designsystem test+lint, :app:assembleDebug pass. |
| T0a core library (pending flag, Resyncing, search) | done | tests green, assembleDebug ok; API in notes below |
| T0b core transfer (import/export) | done | see notes below |
| T2 auth | done | Email + OTP-box screens; single hidden BasicTextField (NumberPassword, SmsOtpCode), auto-submit on 6th digit; server row = M3 ListItem opening existing dialog |
| T3 library list + search + nav | todo | |
| T4 share sheet + tags | todo | |
| T5 reader | todo | |
| T6 settings + import + export | todo | |
| Review + gate | todo | |

## Notes from tasks

- T1: `SrokaTheme(darkTheme, dynamicColor = false /* ignored */, content)`. Extended colours: `MaterialTheme.srokaColors` (`app.sroka.core.designsystem.theme.srokaColors`) with fields `brand, onBrand, warning, warningContainer, progress, progressTrack, readerBody`. Font family val: `OutfitFontFamily` (theme/Type.kt); `SrokaTypography` uses it. Mark: `SrokaMark(modifier, size = 64.dp)` (component/SrokaMark.kt), drawables `app.sroka.core.designsystem.R.drawable.ic_sroka_mark` / `ic_stat_sroka`.
- T1: `shouldUseDynamicColor()` kept in MainActivityViewModel.kt, now always false (ShareActivity still calls it; T4 may drop the call).
- T1: only notification is `core/data/.../sync/SyncNotifications.kt` (uses `android.R.drawable.stat_sys_download`); core:data does not depend on core:designsystem, so NOT switched. T0b/whoever owns it must add the dependency (or copy the drawable) to use `ic_stat_sroka`.
### T0a (core library) API
- `enum class PendingChange { SAVE, TAGS, FAVORITE, OTHER }`; `ItemSummary.pendingChange: PendingChange? = null` (newest non-`item.setProgress` pending op of the item: item.add SAVE, item.tag TAGS, item.setFavorite FAVORITE, else OTHER). Also `Item.pendingChange` (default null; only list projections fill it). `testItem(pendingChange = ...)`.
- `SyncPhase.Resyncing(val fraction: Float? = null)`: emitted while a sync runs and `sync_state.full_resync` is set (410 or pass from cursor 0, so also the very first sync). Fraction always null: pull response has no total. `FakeSyncStatusRepository.emitResyncing(fraction)`. SyncStrip/VM `busy` treat it like Syncing.
- `enum SearchScope {ALL, ARCHIVE, FAVORITES}`, `enum MatchIn {TITLE, TEXT, BOTH}`, `data class SearchResult(summary: ItemSummary, matchIn: MatchIn, snippet: String?, highlights: List<IntRange>)` (core/model/Search.kt). `highlights` are ranges into `snippet`. matchIn: TITLE also covers excerpt/site/tag-only matches; snippet null unless body matched.
- `LibraryRepository.search(query: String, scope: SearchScope): Flow<PagingData<SearchResult>>`; blank/symbol-only query gives empty PagingData; newest first. `FakeLibraryRepository.search` (substring over title/excerpt/meta, excerpt acts as body; `lastSearch`).
- No schema change (existing `pending_ops(item_id)` index suffices).
### T0b (import/export core)
- Model (`core/model/Transfer.kt`): `ImportFormat(wire)` {POCKET_CSV, POCKET_HTML, INSTAPAPER_CSV, NETSCAPE_HTML}, `ExportFormat(wire, extension)` {CSV, JSON}, `JobStatus` {QUEUED, RUNNING, DONE, FAILED} (`isFinished`), `ImportJob(id, status, format, total: Int?, done, skipped, error, createdAt, updatedAt)`.
- Network: `SrokaApi.createImport(source: File, fileName: String, mimeType: String, format: ImportFormat): ApiResult<JobDto>`, `getImport(id): ApiResult<JobDto>`, `export(format: ExportFormat, dest: File): ApiResult<ExportFileDto(fileName, bytes)>`. Any other `SrokaApi` stub must implement these three.
- Domain `DataTransferRepository`: `startImport(uri: String, format): ImportStartResult` (Started(job) | Failed(ImportError)), `activeImport(): Flow<ImportJob?>`, `dismissImport()`, `export(format): ExportResult` (Ready(path, fileName, bytes) | Failed(ExportError)), `fileInfo(uri): PickedFile?(name, sizeBytes: Long?)`, `MAX_IMPORT_BYTES`.
- Active job is stored in the user-preferences DataStore (key `active_import`, `ImportJobStore`); `LocalDataWiper` clears it on sign-out/delete. Worker `ImportProgressWorker` (unique name `sroka-import-<jobId>`, tagged `sroka`); polling logic is `pollUntilFinished` + `ImportTracker`.
- Notification channel "Imports"; texts in `core/data/.../values/strings_transfer.xml`. `ic_stat_sroka.xml` copied from core:designsystem (c652171) into `core/data/res/drawable` (no module dependency); `SyncNotifications` switched to it too. If the glyph changes in designsystem, copy it again.
- Notes for T6: the UI should request POST_NOTIFICATIONS itself (core:ui `NotificationPermission`); the worker keeps polling without it. Gradle config cache held a stale JDK path in this worktree; I ran with `--no-configuration-cache`.
