package app.sroka.core.datastore

import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.emptyPreferences
import androidx.datastore.preferences.core.stringPreferencesKey
import app.sroka.core.model.newUuidV7
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import java.io.IOException
import java.util.Base64
import javax.inject.Inject
import javax.inject.Singleton

/** Decrypted session as stored on the device. */
data class StoredSession(val token: String, val email: String, val expired: Boolean)

/**
 * Session token (AES-GCM encrypted), signed-in email, `expired` flag and the install's device id
 * (DECISIONS A6). Lives in its own DataStore file, excluded from backup. A token that cannot be
 * decrypted (key lost or invalidated) reads as signed out; local library data is untouched.
 */
@Singleton
class SessionStore @Inject constructor(
    @SessionDataStore private val dataStore: DataStore<Preferences>,
    private val cipher: TokenCipher,
) {
    /** The stored session, or null when signed out / undecryptable. */
    val session: Flow<StoredSession?> = dataStore.data
        .catch { throwable ->
            if (throwable is IOException) emit(emptyPreferences()) else throw throwable
        }
        .map { p -> decode(p) }
        .distinctUntilChanged()

    suspend fun current(): StoredSession? = session.first()

    suspend fun token(): String? = current()?.token

    /** Stores a fresh session (also clears the expired flag). */
    suspend fun save(token: String, email: String) {
        val encrypted = Base64.getEncoder().encodeToString(cipher.encrypt(token.toByteArray(Charsets.UTF_8)))
        dataStore.edit {
            it[TOKEN] = encrypted
            it[EMAIL] = email
            it[EXPIRED] = false
        }
    }

    /** The server rejected the token (401): keep the email so the UI can ask to sign in again. */
    suspend fun markExpired() {
        dataStore.edit { if (it[TOKEN] != null) it[EXPIRED] = true }
    }

    /** Signs out. The device id is kept. */
    suspend fun clear() {
        dataStore.edit {
            it.remove(TOKEN)
            it.remove(EMAIL)
            it.remove(EXPIRED)
        }
    }

    /** `"and_" + uuidv7`, generated once per install and never changed. */
    suspend fun deviceId(): String {
        dataStore.data.catch { if (it is IOException) emit(emptyPreferences()) else throw it }
            .first()[DEVICE_ID]?.let { return it }
        var result = ""
        dataStore.edit {
            result = it[DEVICE_ID] ?: (DEVICE_PREFIX + newUuidV7()).also { id -> it[DEVICE_ID] = id }
        }
        return result
    }

    private fun decode(p: Preferences): StoredSession? {
        val encoded = p[TOKEN] ?: return null
        val email = p[EMAIL] ?: return null
        val bytes = try {
            Base64.getDecoder().decode(encoded)
        } catch (_: IllegalArgumentException) {
            return null
        }
        val token = cipher.decrypt(bytes)?.toString(Charsets.UTF_8) ?: return null
        return StoredSession(token, email, p[EXPIRED] ?: false)
    }

    private companion object {
        const val DEVICE_PREFIX = "and_"
        val TOKEN = stringPreferencesKey("token_enc")
        val EMAIL = stringPreferencesKey("email")
        val EXPIRED = booleanPreferencesKey("expired")
        val DEVICE_ID = stringPreferencesKey("device_id")
    }
}
