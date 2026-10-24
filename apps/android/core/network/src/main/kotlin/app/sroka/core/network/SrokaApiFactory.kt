package app.sroka.core.network

import kotlinx.serialization.json.Json
import okhttp3.OkHttpClient

/**
 * Builds a [SrokaApi] outside Hilt (e.g. tests in other modules against MockWebServer). Production code
 * gets the singleton from `NetworkModule`.
 */
object SrokaApiFactory {
    fun create(
        session: SessionProvider,
        config: NetworkConfig,
        json: Json = Json { ignoreUnknownKeys = true; explicitNulls = false; coerceInputValues = true },
        client: OkHttpClient = OkHttpClient(),
    ): SrokaApi = OkHttpSrokaApi(
        client = client.newBuilder().addInterceptor(HeaderInterceptor(session, config.userAgent)).build(),
        downloadClient = client.newBuilder().addInterceptor(UserAgentInterceptor(config.userAgent)).build(),
        session = session,
        json = json,
        uploadClient = client.newBuilder().addInterceptor(HeaderInterceptor(session, config.userAgent))
            .writeTimeout(120, java.util.concurrent.TimeUnit.SECONDS).readTimeout(120, java.util.concurrent.TimeUnit.SECONDS).build(),
    )
}
