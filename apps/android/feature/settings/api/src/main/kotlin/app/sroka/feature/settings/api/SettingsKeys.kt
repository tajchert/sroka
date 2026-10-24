package app.sroka.feature.settings.api

import androidx.navigation3.runtime.NavKey
import kotlinx.serialization.Serializable

/** Settings screen (downloads, storage, appearance, account). */
@Serializable
data object SettingsKey : NavKey

/** Import from Pocket, Instapaper or a browser bookmarks file. */
@Serializable
data object ImportKey : NavKey

/** Export the library as CSV or JSON. */
@Serializable
data object ExportKey : NavKey

/** Settings that open as a single-choice page (or the server form) in the detail pane on wide windows. */
@Serializable
enum class SettingsChoiceKind { Theme, ReaderTheme, TextSize, Offline, Server }

/** A [SettingsChoiceKind] page in the detail pane (two-pane only; phones use dialogs). */
@Serializable
data class SettingsChoiceKey(val kind: SettingsChoiceKind) : NavKey
