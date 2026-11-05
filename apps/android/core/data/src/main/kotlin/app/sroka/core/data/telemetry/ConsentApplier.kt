package app.sroka.core.data.telemetry

import app.sroka.core.common.di.ApplicationScope
import app.sroka.core.domain.ConsentRepository
import app.sroka.core.domain.Telemetry
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import java.util.concurrent.atomic.AtomicBoolean
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Applies the stored consent (repo-root D15) to [Telemetry] at start and on every change:
 * analytics only after an explicit opt-in (not asked = off), crash reports unless opted out.
 * Call [start] once from `Application.onCreate`.
 */
@Singleton
class ConsentApplier @Inject constructor(
    private val consent: ConsentRepository,
    private val telemetry: Telemetry,
    @ApplicationScope private val scope: CoroutineScope,
) {
    private val started = AtomicBoolean(false)

    fun start() {
        if (!started.compareAndSet(false, true)) return
        consent.consent
            .distinctUntilChanged()
            .onEach {
                telemetry.setAnalyticsEnabled(it.analyticsEnabled)
                telemetry.setCrashReportingEnabled(it.crashReports)
            }
            .launchIn(scope)
    }
}
