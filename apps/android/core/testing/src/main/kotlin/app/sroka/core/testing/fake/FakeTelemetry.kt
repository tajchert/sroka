package app.sroka.core.testing.fake

import app.sroka.core.domain.ConsentRepository
import app.sroka.core.domain.Telemetry
import app.sroka.core.domain.TelemetryEvent
import app.sroka.core.model.Consent
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.update

/** Records telemetry calls. */
class FakeTelemetry(override val isAvailable: Boolean = true) : Telemetry {
    val events = mutableListOf<TelemetryEvent>()
    val eventNames: List<String> get() = events.map { it.name }
    var analyticsEnabled: Boolean? = null
        private set
    var crashReportingEnabled: Boolean? = null
        private set
    val nonFatals = mutableListOf<Throwable>()

    override fun logEvent(event: TelemetryEvent) {
        events += event
    }

    override fun setAnalyticsEnabled(enabled: Boolean) {
        analyticsEnabled = enabled
    }

    override fun setCrashReportingEnabled(enabled: Boolean) {
        crashReportingEnabled = enabled
    }

    override fun recordNonFatal(throwable: Throwable) {
        nonFatals += throwable
    }
}

/** In-memory [ConsentRepository]. */
class FakeConsentRepository(initial: Consent = Consent()) : ConsentRepository {
    val consentFlow = MutableStateFlow(initial)
    override val consent: Flow<Consent> = consentFlow

    override suspend fun setAnalytics(enabled: Boolean) = consentFlow.update { it.copy(analytics = enabled) }

    override suspend fun setCrashReports(enabled: Boolean) = consentFlow.update { it.copy(crashReports = enabled) }
}
