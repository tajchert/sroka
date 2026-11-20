package app.sroka.push

import app.sroka.core.domain.PushRegistrar
import dagger.Binds
import dagger.Module
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent

@Module
@InstallIn(SingletonComponent::class)
internal abstract class PushModule {
    @Binds abstract fun pushRegistrar(impl: FirebasePushRegistrar): PushRegistrar
}
