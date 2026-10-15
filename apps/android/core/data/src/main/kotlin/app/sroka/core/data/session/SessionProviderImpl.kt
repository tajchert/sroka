package app.sroka.core.data.session

import app.sroka.core.data.AppBuildInfo
import app.sroka.core.datastore.SessionStore
import app.sroka.core.datastore.UserPreferencesDataSource
import app.sroka.core.network.SessionProvider
import kotlinx.coroutines.flow.first
import javax.inject.Inject
import javax.inject.Singleton

/** Feeds core:network from the datastore (token, device id) and settings (server URL). */
@Singleton
internal class SessionProviderImpl @Inject constructor(
    private val sessionStore: SessionStore,
    private val preferences: UserPreferencesDataSource,
    private val buildInfo: AppBuildInfo,
) : SessionProvider {
    override suspend fun token(): String? = sessionStore.token()

    override suspend fun deviceId(): String = sessionStore.deviceId()

    override suspend fun baseUrl(): String =
        (preferences.userPreferences.first().serverUrl ?: buildInfo.defaultServerUrl).trimEnd('/')
}
