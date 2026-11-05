package app.sroka.core.domain

/**
 * Analytics and crash reporting seam (repo-root D15). The `play` flavor implements it with
 * Firebase, the `foss` flavor (and debug builds) with a no-op.
 *
 * Only [TelemetryEvent] values can be logged, so their parameters are limited to the enums below:
 * never URLs, titles, search text, tag names, file names or ids.
 */
interface Telemetry {

    /** False when this build carries no telemetry at all; the consent prompt and switches are hidden. */
    val isAvailable: Boolean

    fun logEvent(event: TelemetryEvent)

    /** Usage analytics collection + Consent Mode: analytics_storage granted/denied, ad_* always denied. */
    fun setAnalyticsEnabled(enabled: Boolean)

    fun setCrashReportingEnabled(enabled: Boolean)

    /** Records a handled error. The throwable's message must not contain user content. */
    fun recordNonFatal(throwable: Throwable)
}

enum class TelemetryScreen(val value: String) {
    SIGN_IN("sign_in"),
    LIBRARY("library"),
    READER("reader"),
    SEARCH("search"),
    TAGS("tags"),
    SETTINGS("settings"),
    IMPORT("import"),
    EXPORT("export"),
    SHARE("share"),
}

enum class TelemetrySource(val value: String) {
    SHARE("share"),
    PDF("pdf"),
    DRAG("drag"),
    IMPORT("import"),
}

enum class ItemKind(val value: String) {
    ARTICLE("article"),
    PDF("pdf"),
}

enum class ExportFormat(val value: String) {
    CSV("csv"),
    JSON("json"),
}

/** GA4 events (snake_case names; params only from the enums above). */
sealed class TelemetryEvent(val name: String, val params: Map<String, String> = emptyMap()) {
    class ScreenView(screen: TelemetryScreen) : TelemetryEvent("screen_view", mapOf("screen_name" to screen.value))
    data object Login : TelemetryEvent("login", mapOf("method" to "email_otp"))
    class SaveItem(source: TelemetrySource, kind: ItemKind) :
        TelemetryEvent("save_item", mapOf("source" to source.value, "kind" to kind.value))
    class OpenItem(kind: ItemKind) : TelemetryEvent("open_item", mapOf("kind" to kind.value))
    data object ArchiveItem : TelemetryEvent("archive_item")
    data object UnarchiveItem : TelemetryEvent("unarchive_item")
    class FavoriteItem(on: Boolean) : TelemetryEvent("favorite_item", mapOf("on" to on.toString()))
    data object DeleteItem : TelemetryEvent("delete_item")
    data object AddTag : TelemetryEvent("add_tag")
    data object SearchUsed : TelemetryEvent("search_used")
    class ImportStart(source: TelemetrySource = TelemetrySource.IMPORT) :
        TelemetryEvent("import_start", mapOf("source" to source.value))
    class Export(format: ExportFormat) : TelemetryEvent("export", mapOf("format" to format.value))
}
