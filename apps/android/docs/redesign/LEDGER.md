# Redesign ledger (see RULINGS.md)

| Task | Status | Commit / notes |
|---|---|---|
| T1 theme + mark | done | Brand dark/light schemes, Outfit type, shapes, SrokaMark, ic_stat_sroka; dynamic colour off. Gate: designsystem test+lint, :app:assembleDebug pass. |
| T0a core library (pending flag, Resyncing, search) | done | tests green, assembleDebug ok; API in notes below |
| T0b core transfer (import/export) | todo | |
| T2 auth | todo | |
| T3 library list + search + nav | done | see Notes (T3) |
| T4 share sheet + tags | todo | |
| T5 reader | todo | |
| T6 settings + import + export | todo | |
| Review + gate | todo | |

## Notes from tasks

- T1: `SrokaTheme(darkTheme, dynamicColor = false /* ignored */, content)`. Extended colours: `MaterialTheme.srokaColors` (`app.sroka.core.designsystem.theme.srokaColors`) with fields `brand, onBrand, warning, warningContainer, progress, progressTrack, readerBody`. Font family val: `OutfitFontFamily` (theme/Type.kt); `SrokaTypography` uses it. Mark: `SrokaMark(modifier, size = 64.dp)` (component/SrokaMark.kt), drawables `app.sroka.core.designsystem.R.drawable.ic_sroka_mark` / `ic_stat_sroka`.
- T1: `shouldUseDynamicColor()` kept in MainActivityViewModel.kt, now always false (ShareActivity still calls it; T4 may drop the call).
- T1: only notification is `core/data/.../sync/SyncNotifications.kt` (uses `android.R.drawable.stat_sys_download`); core:data does not depend on core:designsystem, so NOT switched. T0b/whoever owns it must add the dependency (or copy the drawable) to use `ic_stat_sroka`.
- T3: new nav key `SearchKey(tab)` (feature/library/api) -> `search/SearchRoute` (full screen, nav bar hidden); `libraryEntries(onOpenSearch, onCloseSearch)` wired in SrokaNavHost. Search opens with the chip of the originating tab (Archive/Favourites tabs preselect theirs), debounce 250 ms.
- T3: SyncStrip.kt deleted; `list/StatusCards.kt` has pure `selectStatusCard(SyncStatus, needsSignIn)` (SignIn card first, then Resync > Offline > Downloading). Routine sync/errors show no card; fetch failures still surface via snackbar. The old "Fetch new articles" app-bar button is removed: pull-to-refresh is the only manual fetch trigger.
- T3: sort menu has no place in the mock; kept as a sort icon inside the search pill (sort order is not in Settings). Swipe start-to-end (favourite) removed per R6; favourite toggling stays in the long-press sheet. Tag-scoped lists keep a plain TopAppBar (back + title + sort), no search pill. Row tag chips and progress line dropped (not in R6).
- T3: no unfilled Rounded icons exist in material-icons-extended, so nav unselected = Icons.Outlined.*, selected = Icons.Rounded.*. Library strings switched to British "Favourites"; app `nav_favorites` too.
- T3: ListScreen tests now `@Config(sdk=[35])`. Not touched: TagEditor.kt, save/**, tags/** (they still use old Filled/Outlined icons).
### T0a (core library) API
- `enum class PendingChange { SAVE, TAGS, FAVORITE, OTHER }`; `ItemSummary.pendingChange: PendingChange? = null` (newest non-`item.setProgress` pending op of the item: item.add SAVE, item.tag TAGS, item.setFavorite FAVORITE, else OTHER). Also `Item.pendingChange` (default null; only list projections fill it). `testItem(pendingChange = ...)`.
- `SyncPhase.Resyncing(val fraction: Float? = null)`: emitted while a sync runs and `sync_state.full_resync` is set (410 or pass from cursor 0, so also the very first sync). Fraction always null: pull response has no total. `FakeSyncStatusRepository.emitResyncing(fraction)`. SyncStrip/VM `busy` treat it like Syncing.
- `enum SearchScope {ALL, ARCHIVE, FAVORITES}`, `enum MatchIn {TITLE, TEXT, BOTH}`, `data class SearchResult(summary: ItemSummary, matchIn: MatchIn, snippet: String?, highlights: List<IntRange>)` (core/model/Search.kt). `highlights` are ranges into `snippet`. matchIn: TITLE also covers excerpt/site/tag-only matches; snippet null unless body matched.
- `LibraryRepository.search(query: String, scope: SearchScope): Flow<PagingData<SearchResult>>`; blank/symbol-only query gives empty PagingData; newest first. `FakeLibraryRepository.search` (substring over title/excerpt/meta, excerpt acts as body; `lastSearch`).
- No schema change (existing `pending_ops(item_id)` index suffices).
