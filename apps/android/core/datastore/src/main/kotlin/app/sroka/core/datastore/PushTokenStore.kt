package app.sroka.core.datastore

import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.emptyPreferences
import androidx.datastore.preferences.core.longPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.first
import java.io.IOException
import javax.inject.Inject

/** The push token the server last accepted for this device and when (throttle state, repo-root D17). */
data class RegisteredPushToken(val token: String, val atMillis: Long)

/** Throttle state for push-token registration, in the user preferences DataStore. Wiped with the account data. */
class PushTokenStore @Inject constructor(
    private val dataStore: DataStore<Preferences>,
) {
    suspend fun last(): RegisteredPushToken? {
        val p = dataStore.data
            .catch { throwable -> if (throwable is IOException) emit(emptyPreferences()) else throw throwable }
            .first()
        val token = p[TOKEN] ?: return null
        val at = p[AT] ?: return null
        return RegisteredPushToken(token, at)
    }

    suspend fun save(token: String, atMillis: Long) {
        dataStore.edit {
            it[TOKEN] = token
            it[AT] = atMillis
        }
    }

    suspend fun clear() {
        dataStore.edit {
            it.remove(TOKEN)
            it.remove(AT)
        }
    }

    private companion object {
        val TOKEN = stringPreferencesKey("push_token")
        val AT = longPreferencesKey("push_token_registered_at")
    }
}
