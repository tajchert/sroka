# Redesign ledger (see RULINGS.md)

| Task | Status | Commit / notes |
|---|---|---|
| T1 theme + mark | done | Brand dark/light schemes, Outfit type, shapes, SrokaMark, ic_stat_sroka; dynamic colour off. Gate: designsystem test+lint, :app:assembleDebug pass. |
| T0a core library (pending flag, Resyncing, search) | todo | |
| T0b core transfer (import/export) | todo | |
| T2 auth | todo | |
| T3 library list + search + nav | todo | |
| T4 share sheet + tags | todo | |
| T5 reader | done | Header + partial row inside WebView HTML (system sans, Outfit not loaded in WebView); app bar collapses via WebView nested scroll; refresh state/snackbars + start-over in ReaderViewModel (new SyncStatusRepository ctor param). |
| T6 settings + import + export | todo | |
| Review + gate | todo | |

## Notes from tasks

- T1: `SrokaTheme(darkTheme, dynamicColor = false /* ignored */, content)`. Extended colours: `MaterialTheme.srokaColors` (`app.sroka.core.designsystem.theme.srokaColors`) with fields `brand, onBrand, warning, warningContainer, progress, progressTrack, readerBody`. Font family val: `OutfitFontFamily` (theme/Type.kt); `SrokaTypography` uses it. Mark: `SrokaMark(modifier, size = 64.dp)` (component/SrokaMark.kt), drawables `app.sroka.core.designsystem.R.drawable.ic_sroka_mark` / `ic_stat_sroka`.
- T1: `shouldUseDynamicColor()` kept in MainActivityViewModel.kt, now always false (ShareActivity still calls it; T4 may drop the call).
- T1: only notification is `core/data/.../sync/SyncNotifications.kt` (uses `android.R.drawable.stat_sys_download`); core:data does not depend on core:designsystem, so NOT switched. T0b/whoever owns it must add the dependency (or copy the drawable) to use `ic_stat_sroka`.
