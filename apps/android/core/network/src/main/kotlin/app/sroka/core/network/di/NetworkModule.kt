package app.sroka.core.network.di

import dagger.Module
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent

/** Provides OkHttpClient, Json and `SrokaApi` (DECISIONS A5). Owner: core:network step. */
@Module
@InstallIn(SingletonComponent::class)
internal object NetworkModule
