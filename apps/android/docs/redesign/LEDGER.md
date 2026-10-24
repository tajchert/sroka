# Redesign ledger (see RULINGS.md)

| Task | Status | Commit / notes |
|---|---|---|
| T1 theme + mark | todo | |
| T0a core library (pending flag, Resyncing, search) | done | tests green, assembleDebug ok; API in notes below |
| T0b core transfer (import/export) | todo | |
| T2 auth | todo | |
| T3 library list + search + nav | todo | |
| T4 share sheet + tags | todo | |
| T5 reader | todo | |
| T6 settings + import + export | todo | |
| Review + gate | todo | |

## Notes from tasks

### T0a (core library) API
- `enum class PendingChange { SAVE, TAGS, FAVORITE, OTHER }`; `ItemSummary.pendingChange: PendingChange? = null` (newest non-`item.setProgress` pending op of the item: item.add SAVE, item.tag TAGS, item.setFavorite FAVORITE, else OTHER). Also `Item.pendingChange` (default null; only list projections fill it). `testItem(pendingChange = ...)`.
- `SyncPhase.Resyncing(val fraction: Float? = null)`: emitted while a sync runs and `sync_state.full_resync` is set (410 or pass from cursor 0, so also the very first sync). Fraction always null: pull response has no total. `FakeSyncStatusRepository.emitResyncing(fraction)`. SyncStrip/VM `busy` treat it like Syncing.
- `enum SearchScope {ALL, ARCHIVE, FAVORITES}`, `enum MatchIn {TITLE, TEXT, BOTH}`, `data class SearchResult(summary: ItemSummary, matchIn: MatchIn, snippet: String?, highlights: List<IntRange>)` (core/model/Search.kt). `highlights` are ranges into `snippet`. matchIn: TITLE also covers excerpt/site/tag-only matches; snippet null unless body matched.
- `LibraryRepository.search(query: String, scope: SearchScope): Flow<PagingData<SearchResult>>`; blank/symbol-only query gives empty PagingData; newest first. `FakeLibraryRepository.search` (substring over title/excerpt/meta, excerpt acts as body; `lastSearch`).
- No schema change (existing `pending_ops(item_id)` index suffices).
