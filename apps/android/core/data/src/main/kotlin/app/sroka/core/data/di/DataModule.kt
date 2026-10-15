package app.sroka.core.data.di

import android.content.Context
import app.sroka.core.data.AppBuildInfo
import app.sroka.core.data.content.ContentPaths
import app.sroka.core.data.content.ContentStoreImpl
import app.sroka.core.data.repository.AccountRepositoryImpl
import app.sroka.core.data.repository.AuthRepositoryImpl
import app.sroka.core.data.repository.LibraryRepositoryImpl
import app.sroka.core.data.repository.SettingsRepositoryImpl
import app.sroka.core.data.repository.TagRepositoryImpl
import app.sroka.core.data.session.SessionProviderImpl
import app.sroka.core.data.sync.SyncControllerImpl
import app.sroka.core.data.sync.SyncStatusRepositoryImpl
import app.sroka.core.domain.AccountRepository
import app.sroka.core.domain.AuthRepository
import app.sroka.core.domain.ContentStore
import app.sroka.core.domain.LibraryRepository
import app.sroka.core.domain.SettingsRepository
import app.sroka.core.domain.SyncController
import app.sroka.core.domain.SyncStatusRepository
import app.sroka.core.domain.TagRepository
import app.sroka.core.network.NetworkConfig
import app.sroka.core.network.SessionProvider
import dagger.Binds
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import javax.inject.Singleton

/**
 * Binds every core:domain interface to its implementation, plus what core:network needs
 * ([SessionProvider], [NetworkConfig]). Requires `:app` to provide [AppBuildInfo].
 */
@Module
@InstallIn(SingletonComponent::class)
internal abstract class DataModule {
    @Binds abstract fun library(impl: LibraryRepositoryImpl): LibraryRepository
    @Binds abstract fun tags(impl: TagRepositoryImpl): TagRepository
    @Binds abstract fun syncController(impl: SyncControllerImpl): SyncController
    @Binds abstract fun syncStatus(impl: SyncStatusRepositoryImpl): SyncStatusRepository
    @Binds abstract fun content(impl: ContentStoreImpl): ContentStore
    @Binds abstract fun auth(impl: AuthRepositoryImpl): AuthRepository
    @Binds abstract fun settings(impl: SettingsRepositoryImpl): SettingsRepository
    @Binds abstract fun account(impl: AccountRepositoryImpl): AccountRepository
    @Binds abstract fun sessionProvider(impl: SessionProviderImpl): SessionProvider

    companion object {
        @Provides
        @Singleton
        fun contentPaths(@ApplicationContext context: Context): ContentPaths =
            ContentPaths(context.filesDir, context.cacheDir)

        @Provides
        fun networkConfig(buildInfo: AppBuildInfo): NetworkConfig =
            NetworkConfig(userAgent = "Sroka-Android/${buildInfo.versionName}")
    }
}
