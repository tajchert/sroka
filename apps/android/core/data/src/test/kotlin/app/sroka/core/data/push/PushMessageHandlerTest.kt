package app.sroka.core.data.push

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PushMessageHandlerTest {
    private var signedIn = true
    private var enqueued = 0
    private val handler = PushMessageHandler(isSignedIn = { signedIn }, enqueueSync = { enqueued++ })

    @Test fun syncMessageEnqueuesSyncWhenSignedIn() = runBlocking {
        assertTrue(handler.onMessage(mapOf("type" to "sync")))
        assertEquals(1, enqueued)
    }

    @Test fun syncMessageIsIgnoredWhenSignedOut() = runBlocking {
        signedIn = false
        assertFalse(handler.onMessage(mapOf("type" to "sync")))
        assertEquals(0, enqueued)
    }

    @Test fun otherTypesAndEmptyDataAreIgnored() = runBlocking {
        assertFalse(handler.onMessage(mapOf("type" to "promo")))
        assertFalse(handler.onMessage(mapOf("type" to "SYNC")))
        assertFalse(handler.onMessage(mapOf("other" to "sync")))
        assertFalse(handler.onMessage(emptyMap()))
        assertEquals(0, enqueued)
    }
}
