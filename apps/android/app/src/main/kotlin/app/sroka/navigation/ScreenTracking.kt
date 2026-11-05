package app.sroka.navigation

import androidx.navigation3.runtime.NavKey
import app.sroka.core.domain.TelemetryScreen
import app.sroka.feature.auth.api.AuthKey
import app.sroka.feature.library.api.LibraryKey
import app.sroka.feature.library.api.SearchKey
import app.sroka.feature.library.api.TagItemsKey
import app.sroka.feature.library.api.TagsKey
import app.sroka.feature.reader.api.ReaderKey
import app.sroka.feature.settings.api.ExportKey
import app.sroka.feature.settings.api.ImportKey
import app.sroka.feature.settings.api.SettingsChoiceKey
import app.sroka.feature.settings.api.SettingsKey

/** The D15 `screen_name` for the screen on top of the back stack (route pattern only, never ids or tag names). */
internal fun NavKey.telemetryScreen(): TelemetryScreen? = when (this) {
    AuthKey -> TelemetryScreen.SIGN_IN
    is LibraryKey -> TelemetryScreen.LIBRARY
    is ReaderKey -> TelemetryScreen.READER
    is SearchKey -> TelemetryScreen.SEARCH
    TagsKey, is TagItemsKey -> TelemetryScreen.TAGS
    SettingsKey, is SettingsChoiceKey -> TelemetryScreen.SETTINGS
    ImportKey -> TelemetryScreen.IMPORT
    ExportKey -> TelemetryScreen.EXPORT
    else -> null
}
