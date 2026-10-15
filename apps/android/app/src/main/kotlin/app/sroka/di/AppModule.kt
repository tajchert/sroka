package app.sroka.di

import app.sroka.BuildConfig
import app.sroka.core.data.AppBuildInfo
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import javax.inject.Singleton

/** Build-time values only `:app` knows, consumed by core:data (DECISIONS A5). */
@Module
@InstallIn(SingletonComponent::class)
internal object AppModule {
    @Provides
    @Singleton
    fun buildInfo(): AppBuildInfo = AppBuildInfo(
        defaultServerUrl = BuildConfig.DEFAULT_SERVER_URL,
        versionName = BuildConfig.VERSION_NAME,
    )
}
