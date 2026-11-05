package app.sroka.telemetry

import app.sroka.core.domain.Telemetry
import dagger.Binds
import dagger.Module
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent

@Module
@InstallIn(SingletonComponent::class)
internal abstract class TelemetryModule {
    @Binds abstract fun telemetry(impl: FirebaseTelemetry): Telemetry
}
