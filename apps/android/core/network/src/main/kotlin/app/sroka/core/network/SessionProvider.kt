package app.sroka.core.network

/** Supplied by core:data (backed by the datastore); keeps core:network independent of storage. */
interface SessionProvider {
    /** Bearer token, or null when signed out. */
    suspend fun token(): String?

    suspend fun deviceId(): String

    /** Server base URL without trailing slash, e.g. `https://api.sroka.app`. */
    suspend fun baseUrl(): String
}

/** Static client identity; provided by the app/data layer (e.g. `Sroka-Android/1.0`). */
data class NetworkConfig(val userAgent: String)
