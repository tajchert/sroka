package app.sroka.core.datastore

import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.emptyPreferences
import app.sroka.core.model.Consent
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.map
import java.io.IOException
import javax.inject.Inject

/**
 * Telemetry consent (repo-root D15) in the user preferences DataStore. Analytics is tri-state
 * (absent = not asked yet), crash reports default to on.
 */
class ConsentStore @Inject constructor(
    private val dataStore: DataStore<Preferences>,
) {
    val consent: Flow<Consent> = dataStore.data
        .catch { throwable ->
            if (throwable is IOException) emit(emptyPreferences()) else throw throwable
        }
        .map { p -> Consent(analytics = p[ANALYTICS], crashReports = p[CRASH_REPORTS] ?: true) }

    suspend fun setAnalytics(enabled: Boolean) = dataStore.edit { it[ANALYTICS] = enabled }

    suspend fun setCrashReports(enabled: Boolean) = dataStore.edit { it[CRASH_REPORTS] = enabled }

    private companion object {
        val ANALYTICS = booleanPreferencesKey("consent_analytics")
        val CRASH_REPORTS = booleanPreferencesKey("consent_crash_reports")
    }
}
