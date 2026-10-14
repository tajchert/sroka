package app.sroka.core.network.di

import app.sroka.core.network.TaskNetworkDataSource
import app.sroka.core.network.fake.FakeTaskNetworkDataSource
import dagger.Binds
import dagger.Module
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import javax.inject.Singleton

/** Runnable demo source. Replace this binding when adding a product backend. */
@Module
@InstallIn(SingletonComponent::class)
abstract class NetworkDataSourceModule {
    @Binds
    @Singleton
    abstract fun bindsTaskNetworkDataSource(impl: FakeTaskNetworkDataSource): TaskNetworkDataSource
}
