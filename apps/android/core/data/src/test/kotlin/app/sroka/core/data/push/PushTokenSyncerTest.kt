package app.sroka.core.data.push

import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import app.sroka.core.common.Clock
import app.sroka.core.data.DataTestBase
import app.sroka.core.datastore.PushTokenStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import app.sroka.core.network.NetworkConfig
import app.sroka.core.network.SessionProvider
import app.sroka.core.network.SrokaApiFactory
import mockwebserver3.MockResponse
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.util.concurrent.TimeUnit

/** Real session + api against MockWebServer; the throttle state sits in a temp DataStore file. */
internal class PushTokenSyncerTest : DataTestBase() {
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private lateinit var store: PushTokenStore
    private lateinit var syncer: PushTokenSyncer

    @Before
    fun setUpSyncer() {
        store = PushTokenStore(PreferenceDataStoreFactory.create(scope = scope) { tmp.root.resolve("prefs.preferences_pb") })
        val provider = object : SessionProvider {
            override suspend fun token() = sessionStore.token()
            override suspend fun deviceId() = "and_test"
            override suspend fun baseUrl() = server.url("/").toString().trimEnd('/')
        }
        val api = SrokaApiFactory.create(provider, NetworkConfig("Sroka-Android/test"))
        syncer = PushTokenSyncer(api, sessionStore, store, Clock { now })
    }

    @After
    fun tearDownSyncer() = scope.cancel()

    private fun ok() = server.enqueue(MockResponse.Builder().code(204).build())

    @Test fun firstRegistrationPutsTheTokenAndRemembersIt() = runBlocking {
        ok()
        assertTrue(syncer.sync("tok1"))
        val req = server.takeRequest()
        assertEquals("PUT", req.method)
        assertEquals("/v1/push-token", req.url.encodedPath)
        assertEquals("""{"platform":"fcm","token":"tok1"}""", req.body!!.utf8())
        assertEquals("tok1", store.last()?.token)
        assertEquals(now, store.last()?.atMillis)
    }

    @Test fun unchangedTokenWithinSevenDaysIsNotPutAgain() = runBlocking {
        ok()
        assertTrue(syncer.sync("tok1"))
        now += TimeUnit.DAYS.toMillis(7) - 1
        assertFalse(syncer.sync("tok1"))
        assertEquals(1, server.requestCount)
    }

    @Test fun unchangedTokenIsRefreshedAfterSevenDays() = runBlocking {
        ok()
        ok()
        assertTrue(syncer.sync("tok1"))
        now += TimeUnit.DAYS.toMillis(7)
        assertTrue(syncer.sync("tok1"))
        assertEquals(2, server.requestCount)
        assertEquals(now, store.last()?.atMillis)
    }

    @Test fun changedTokenIsPutImmediately() = runBlocking {
        ok()
        ok()
        syncer.sync("tok1")
        now += 1_000
        assertTrue(syncer.sync("tok2"))
        assertEquals("tok2", store.last()?.token)
    }

    @Test fun failedPutIsNotRememberedSoItRetries() = runBlocking {
        server.enqueue(MockResponse.Builder().code(500).build())
        ok()
        assertFalse(syncer.sync("tok1"))
        assertNull(store.last())
        assertTrue(syncer.sync("tok1"))
        assertEquals(2, server.requestCount)
    }

    @Test fun signedOutOrExpiredDoesNothing() = runBlocking {
        sessionStore.markExpired()
        assertFalse(syncer.sync("tok1"))
        sessionStore.clear()
        assertFalse(syncer.sync("tok1"))
        assertFalse(syncer.sync(" "))
        assertEquals(0, server.requestCount)
    }

    @Test fun removeDeletesOnTheServerAndClearsThrottleState() = runBlocking {
        ok()
        ok()
        syncer.sync("tok1")
        syncer.remove()
        val put = server.takeRequest()
        val delete = server.takeRequest()
        assertEquals("DELETE", delete.method)
        assertEquals("/v1/push-token", delete.url.encodedPath)
        assertNull(store.last())
        assertEquals("PUT", put.method)
    }

    @Test fun removeClearsThrottleStateEvenWhenOffline() = runBlocking {
        ok()
        syncer.sync("tok1")
        server.enqueue(MockResponse.Builder().code(500).build())
        syncer.remove()
        assertNull(store.last())
    }
}
