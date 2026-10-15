package app.sroka.core.network

import kotlinx.coroutines.runBlocking
import okhttp3.Interceptor
import okhttp3.Response

/** Adds `Authorization: Bearer`, `X-Sroka-Device` and `User-Agent` (DECISIONS A5). Runs on OkHttp threads. */
internal class HeaderInterceptor(
    private val session: SessionProvider,
    private val userAgent: String,
) : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        val (token, deviceId) = runBlocking { session.token() to session.deviceId() }
        val builder = chain.request().newBuilder()
            .header("User-Agent", userAgent)
            .header("X-Sroka-Device", deviceId)
        if (token != null) builder.header("Authorization", "Bearer $token")
        return chain.proceed(builder.build())
    }
}

/** Download requests go to the content host with a signed URL: only the User-Agent is sent. */
internal class UserAgentInterceptor(private val userAgent: String) : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response =
        chain.proceed(chain.request().newBuilder().header("User-Agent", userAgent).build())
}
