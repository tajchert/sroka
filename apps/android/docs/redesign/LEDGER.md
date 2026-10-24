# Redesign ledger (see RULINGS.md)

| Task | Status | Commit / notes |
|---|---|---|
| T1 theme + mark | done | Brand dark/light schemes, Outfit type, shapes, SrokaMark, ic_stat_sroka; dynamic colour off. Gate: designsystem test+lint, :app:assembleDebug pass. |
| T0a core library (pending flag, Resyncing, search) | done | tests green, assembleDebug ok; API in notes below |
| T0b core transfer (import/export) | todo | |
| T2 auth | todo | |
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
