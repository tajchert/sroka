package app.sroka.core.ui.adaptive

import androidx.compose.runtime.Immutable
import androidx.compose.runtime.staticCompositionLocalOf

/**
 * Window-derived layout facts for navigation entries. NavDisplay keeps entry content while the back
 * stack is unchanged, so plain values captured when entries are declared go stale on resize or
 * fold/unfold. The app provides the live value around NavDisplay; entries read it in composition.
 *
 * @param twoPane the window shows list and detail side by side
 * @param railShown the navigation rail is visible (it hosts the save-link FAB and the avatar)
 */
@Immutable
data class PaneLayout(val twoPane: Boolean = false, val railShown: Boolean = false)

val LocalPaneLayout = staticCompositionLocalOf { PaneLayout() }
