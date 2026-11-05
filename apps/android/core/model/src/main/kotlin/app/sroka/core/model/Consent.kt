package app.sroka.core.model

/**
 * Telemetry consent (repo-root D15), stored per device and never synced.
 *
 * @property analytics usage analytics opt-in; null = the user has not been asked yet (treated as off).
 * @property crashReports crash reporting; on by default, with an opt-out.
 */
data class Consent(
    val analytics: Boolean? = null,
    val crashReports: Boolean = true,
) {
    val analyticsEnabled: Boolean get() = analytics == true
}
