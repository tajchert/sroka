package app.sroka.core.domain

import app.sroka.core.model.Consent
import kotlinx.coroutines.flow.Flow

/** Local telemetry consent (repo-root D15). */
interface ConsentRepository {

    /** Current consent; emits immediately (defaults when nothing is stored). */
    val consent: Flow<Consent>

    /** Records the analytics decision (also dismisses the first-run prompt). */
    suspend fun setAnalytics(enabled: Boolean)

    suspend fun setCrashReports(enabled: Boolean)
}
