package app.sroka.core.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class UuidV7Test {
    private val format = Regex("^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")

    @Test
    fun hasVersionVariantAndTimestamp() {
        // Larger than any other test timestamp: the generator is process-wide monotonic.
        val now = 4_000_000_000_123L
        val id = newUuidV7(now)
        assertTrue(id, format.matches(id))
        assertEquals(now, uuidV7Time(id))
    }

    @Test
    fun isMonotonicWithinTheSameMillisecond() {
        val now = 1_900_000_000_000L
        val ids = List(5000) { newUuidV7(now) }
        assertEquals(ids.sorted(), ids)
        assertEquals(ids.size, ids.toSet().size)
    }

    @Test
    fun clockGoingBackwardsStaysMonotonic() {
        val a = newUuidV7(2_000_000_000_000L)
        val b = newUuidV7(1_000_000_000_000L)
        assertTrue(b > a)
    }
}
