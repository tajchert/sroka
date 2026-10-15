package app.sroka.core.data

/**
 * Build-time values that only `:app` knows. `:app` must `@Provides` one instance
 * (e.g. `AppBuildInfo(BuildConfig.DEFAULT_SERVER_URL, BuildConfig.VERSION_NAME)`).
 */
data class AppBuildInfo(
    /** Server used when the user has not set a custom one (DECISIONS A5). */
    val defaultServerUrl: String,
    /** `versionName`, sent as `User-Agent: Sroka-Android/<versionName>`. */
    val versionName: String,
)
