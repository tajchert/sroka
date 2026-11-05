package app.sroka.telemetry

import app.sroka.core.domain.Telemetry
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent

/** The foss flavor carries no telemetry at all (repo-root D15). */
@Module
@InstallIn(SingletonComponent::class)
internal object TelemetryModule {
    @Provides
    fun telemetry(): Telemetry = Telemetry.None
}
