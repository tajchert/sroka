package app.sroka.core.datastore

import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** Reversible fake cipher; [broken] simulates a lost/invalidated Keystore key. */
private class FakeCipher : TokenCipher {
    var broken = false
    override fun encrypt(plain: ByteArray) = plain.reversedArray()
    override fun decrypt(data: ByteArray) = if (broken) null else data.reversedArray()
}

class SessionStoreTest {
    @get:Rule
    val tmp = TemporaryFolder()

    private val scope = TestScope(UnconfinedTestDispatcher())
    private val file by lazy { tmp.newFile("session.preferences_pb") }
    private val dataStore by lazy {
        PreferenceDataStoreFactory.create(scope = scope.backgroundScope) { file }
    }
    private val cipher = FakeCipher()
    private val store by lazy { SessionStore(dataStore, cipher) }

    @Test
    fun signedOutByDefault() = scope.runTest {
        assertNull(store.current())
        assertNull(store.token())
    }

    @Test
    fun saveRoundTripsAndStoresCiphertext() = scope.runTest {
        store.save("abc.def==", "a@b.c")
        assertEquals(StoredSession("abc.def==", "a@b.c", false), store.current())
        val raw = dataStore.data.let { f -> f.first() }[stringPreferencesKey("token_enc")]!!
        assertNotEquals("abc.def==", raw)
    }

    @Test
    fun markExpiredKeepsEmailAndSaveClearsFlag() = scope.runTest {
        store.save("t", "a@b.c")
        store.markExpired()
        assertTrue(store.current()!!.expired)
        store.save("t2", "a@b.c")
        assertFalse(store.current()!!.expired)
    }

    @Test
    fun markExpiredWhenSignedOutIsNoOp() = scope.runTest {
        store.markExpired()
        assertNull(store.current())
    }

    @Test
    fun undecryptableTokenReadsAsSignedOut() = scope.runTest {
        store.save("t", "a@b.c")
        cipher.broken = true
        assertNull(store.current())
    }

    @Test
    fun garbageTokenReadsAsSignedOut() = scope.runTest {
        dataStore.edit {
            it[stringPreferencesKey("token_enc")] = "!!!not base64!!!"
            it[stringPreferencesKey("email")] = "a@b.c"
        }
        assertNull(store.current())
    }

    @Test
    fun clearSignsOutButKeepsDeviceId() = scope.runTest {
        val id = store.deviceId()
        store.save("t", "a@b.c")
        store.clear()
        assertNull(store.current())
        assertEquals(id, store.deviceId())
    }

    @Test
    fun deviceIdIsStableAndWellFormed() = scope.runTest {
        val id = store.deviceId()
        assertTrue(id.startsWith("and_"))
        assertTrue(Regex("^[A-Za-z0-9_.:-]{1,64}$").matches(id))
        assertEquals(id, store.deviceId())
        assertEquals(id, SessionStore(dataStore, cipher).deviceId())
    }
}
