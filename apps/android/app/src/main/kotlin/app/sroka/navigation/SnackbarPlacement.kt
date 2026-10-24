package app.sroka.navigation

import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/** Initial list pane width (the 360dp divider anchor, R13). */
internal val ListPaneWidth: Dp = 360.dp

/** FAB height (56dp) plus its two 16dp margins. */
internal val FabClearance: Dp = 88.dp

/**
 * Where the app-level snackbar sits (R14.8). Two-pane: start-aligned at the bottom of the list pane
 * (the host box already starts after the rail). Phone: bottom centre above the FAB, as before.
 */
internal data class SnackbarPlacement(val startAligned: Boolean, val width: Dp?, val bottomClearance: Dp)

internal fun snackbarPlacement(twoPane: Boolean, railShown: Boolean, hasFab: Boolean): SnackbarPlacement =
    if (twoPane) {
        SnackbarPlacement(startAligned = true, width = ListPaneWidth, bottomClearance = 0.dp)
    } else {
        SnackbarPlacement(startAligned = false, width = null, bottomClearance = if (hasFab && !railShown) FabClearance else 0.dp)
    }
