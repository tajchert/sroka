package app.sroka.core.database.di

import dagger.Module
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent

/**
 * Provides `SrokaDatabase` (file `sroka.db`, DECISIONS A4) and its DAOs.
 * Owner: core:database step. Never add destructive migrations.
 */
@Module
@InstallIn(SingletonComponent::class)
internal object DatabaseModule
