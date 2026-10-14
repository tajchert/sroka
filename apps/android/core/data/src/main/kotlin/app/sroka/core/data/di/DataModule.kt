package app.sroka.core.data.di

import dagger.Module
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent

/**
 * Binds the core:domain interfaces to their implementations (@Binds), plus SyncEngine/ContentStore
 * wiring. Owner: core:data step. While this is being built, :app binds temporary implementations in
 * `app/src/main/kotlin/app/sroka/di/TemporaryBindings.kt` and does not depend on this module.
 */
@Module
@InstallIn(SingletonComponent::class)
internal abstract class DataModule
