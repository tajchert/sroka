package app.sroka.core.model

/** Authentication state of the app (DECISIONS A3). */
sealed interface SessionState {
    data object SignedOut : SessionState

    data class SignedIn(val email: String) : SessionState

    /** The server rejected the token (401). Local data is kept; the user is asked to sign in again. */
    data class Expired(val email: String) : SessionState
}

/** Local preferences (DECISIONS A6). */
data class UserPreferences(
    val themeMode: ThemeMode = ThemeMode.SYSTEM,
    val dynamicColor: Boolean = true,
    val downloadPolicy: DownloadPolicy = DownloadPolicy.WIFI_ONLY,
    val readerTheme: ReaderTheme = ReaderTheme.AUTO,
    /** Reader text scale, clamped to [READER_TEXT_SCALE_MIN]..[READER_TEXT_SCALE_MAX]. */
    val readerTextScale: Float = 1.0f,
    val sortOrder: SortOrder = SortOrder.NEWEST,
    /** Overrides the build's default server; null = default. */
    val serverUrl: String? = null,
) {
    companion object {
        const val READER_TEXT_SCALE_MIN = 0.8f
        const val READER_TEXT_SCALE_MAX = 1.6f
    }
}

/** Outcome of saving a URL locally. */
sealed interface SaveResult {
    /** Saved (or re-added when [alreadySaved]) as item [itemId]. */
    data class Saved(val itemId: String, val alreadySaved: Boolean) : SaveResult

    /** Not an http(s) URL. */
    data object InvalidUrl : SaveResult
}
