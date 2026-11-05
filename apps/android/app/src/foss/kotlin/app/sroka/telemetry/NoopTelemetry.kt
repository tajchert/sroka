package app.sroka.telemetry

import app.sroka.core.domain.Telemetry
import app.sroka.core.domain.TelemetryEvent
import dagger.Binds
import dagger.Module
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import javax.inject.Inject
import javax.inject.Singleton

/** The foss flavor carries no telemetry at all (repo-root D15). */
@Singleton
class NoopTelemetry @Inject constructor() : Telemetry {
    override val isAvailable: Boolean = false
    override fun logEvent(event: TelemetryEvent) = Unit
    override fun setAnalyticsEnabled(enabled: Boolean) = Unit
    override fun setCrashReportingEnabled(enabled: Boolean) = Unit
    override fun recordNonFatal(throwable: Throwable) = Unit
}

@Module
@InstallIn(SingletonComponent::class)
internal abstract class TelemetryModule {
    @Binds abstract fun telemetry(impl: NoopTelemetry): Telemetry
}
