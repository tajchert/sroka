package app.sroka.core.network.di

import app.sroka.core.network.HeaderInterceptor
import app.sroka.core.network.NetworkConfig
import app.sroka.core.network.OkHttpSrokaApi
import app.sroka.core.network.SessionProvider
import app.sroka.core.network.SrokaApi
import app.sroka.core.network.UserAgentInterceptor
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import kotlinx.serialization.json.Json
import okhttp3.OkHttpClient
import java.util.concurrent.TimeUnit
import javax.inject.Singleton

/**
 * Provides `SrokaApi` (DECISIONS A5). Requires [SessionProvider] and [NetworkConfig] bindings from
 * core:data / app.
 */
@Module
@InstallIn(SingletonComponent::class)
internal object NetworkModule {

    @Provides
    @Singleton
    fun provideJson(): Json = Json {
        ignoreUnknownKeys = true
        explicitNulls = false
        coerceInputValues = true
    }

    @Provides
    @Singleton
    fun provideSrokaApi(session: SessionProvider, config: NetworkConfig, json: Json): SrokaApi {
        val base = OkHttpClient.Builder()
            .connectTimeout(15, TimeUnit.SECONDS)
            .readTimeout(30, TimeUnit.SECONDS)
            .writeTimeout(30, TimeUnit.SECONDS)
            .build()
        val api = base.newBuilder().addInterceptor(HeaderInterceptor(session, config.userAgent)).build()
        // Same connection pool/dispatcher; longer read timeout for large packages.
        val download = base.newBuilder()
            .readTimeout(120, TimeUnit.SECONDS)
            .addInterceptor(UserAgentInterceptor(config.userAgent))
            .build()
        return OkHttpSrokaApi(api, download, session, json)
    }
}
