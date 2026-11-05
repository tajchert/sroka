package app.sroka.telemetry

import android.content.Context
import android.os.Bundle
import app.sroka.BuildConfig
import app.sroka.core.domain.Telemetry
import app.sroka.core.domain.TelemetryEvent
import com.google.firebase.FirebaseApp
import com.google.firebase.analytics.FirebaseAnalytics
import com.google.firebase.crashlytics.FirebaseCrashlytics
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Firebase Analytics + Crashlytics (repo-root D15). Behaves as a no-op when Firebase isn't
 * initialised (the build had no `google-services.json`) and never sends from debug builds.
 * Collection is off by default in the manifest and only enabled through the consent store.
 */
@Singleton
class FirebaseTelemetry @Inject constructor(
    @ApplicationContext context: Context,
) : Telemetry {

    private val ready: Boolean = runCatching { FirebaseApp.getApps(context).isNotEmpty() }.getOrDefault(false)

    private val analytics: FirebaseAnalytics? =
        if (ready) runCatching { FirebaseAnalytics.getInstance(context) }.getOrNull() else null

    private val crashlytics: FirebaseCrashlytics? =
        if (ready) runCatching { FirebaseCrashlytics.getInstance() }.getOrNull() else null

    private var analyticsEnabled = false

    override val isAvailable: Boolean get() = analytics != null

    override fun logEvent(event: TelemetryEvent) {
        if (BuildConfig.DEBUG || !analyticsEnabled) return
        val bundle = Bundle().apply { event.params.forEach { (k, v) -> putString(k, v) } }
        analytics?.logEvent(event.name, bundle)
    }

    override fun setAnalyticsEnabled(enabled: Boolean) {
        val on = enabled && !BuildConfig.DEBUG
        analyticsEnabled = on
        val fa = analytics ?: return
        fa.setAnalyticsCollectionEnabled(on)
        // Consent Mode v2: only analytics_storage can be granted; ad signals stay denied.
        fa.setConsent(
            mapOf(
                FirebaseAnalytics.ConsentType.ANALYTICS_STORAGE to status(on),
                FirebaseAnalytics.ConsentType.AD_STORAGE to FirebaseAnalytics.ConsentStatus.DENIED,
                FirebaseAnalytics.ConsentType.AD_USER_DATA to FirebaseAnalytics.ConsentStatus.DENIED,
                FirebaseAnalytics.ConsentType.AD_PERSONALIZATION to FirebaseAnalytics.ConsentStatus.DENIED,
            ),
        )
    }

    override fun setCrashReportingEnabled(enabled: Boolean) {
        crashlytics?.isCrashlyticsCollectionEnabled = enabled && !BuildConfig.DEBUG
    }

    override fun recordNonFatal(throwable: Throwable) {
        if (BuildConfig.DEBUG) return
        crashlytics?.recordException(throwable)
    }

    private fun status(granted: Boolean) =
        if (granted) FirebaseAnalytics.ConsentStatus.GRANTED else FirebaseAnalytics.ConsentStatus.DENIED
}
