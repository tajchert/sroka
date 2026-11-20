package app.sroka.push

import app.sroka.core.domain.PushRegistrar
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent

/** The foss flavor has no push (repo-root D17): the hourly periodic sync is the only background trigger. */
@Module
@InstallIn(SingletonComponent::class)
internal object PushModule {
    @Provides
    fun pushRegistrar(): PushRegistrar = PushRegistrar.None
}
