package app.sroka.feature.reader.impl

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RefCountedCacheTest {
    private class Page(val bytes: Long) {
        var recycled = false
    }

    private fun cache(max: Long) = RefCountedCache<Int, Page>(max, { it.bytes }, { it.recycled = true })

    @Test
    fun evictsLeastRecentlyUsedUnleasedAndRecycles() {
        val c = cache(250)
        val a = Page(100); val b = Page(100); val d = Page(100)
        c.release(c.put(0, a))
        c.release(c.put(1, b))
        c.release(c.acquire(0)!!) // touch 0: 1 is now the eldest
        c.release(c.put(2, d))
        assertTrue(b.recycled)
        assertFalse(a.recycled)
        assertNull(c.acquire(1))
        assertEquals(200L, c.sizeBytes)
    }

    @Test
    fun leasedEntriesAreNeverEvicted() {
        val c = cache(150)
        val a = Page(100); val b = Page(100)
        val leaseA = c.put(0, a)
        c.release(c.put(1, b))
        assertFalse(a.recycled)
        assertNotNull(c.acquire(0))
        c.release(leaseA)
    }

    @Test
    fun clearRecyclesIdleNowAndLeasedOnRelease() {
        val c = cache(1_000)
        val idle = Page(10); val busy = Page(10)
        c.release(c.put(0, idle))
        val lease = c.put(1, busy)
        c.clear()
        assertTrue(idle.recycled)
        assertFalse(busy.recycled)
        c.release(lease)
        assertTrue(busy.recycled)
        assertEquals(0, c.count)
    }

    @Test
    fun replacingAnEntryRetiresTheOldOne() {
        val c = cache(1_000)
        val old = Page(10); val new = Page(20)
        c.release(c.put(0, old))
        c.release(c.put(0, new))
        assertTrue(old.recycled)
        assertEquals(20L, c.sizeBytes)
    }
}
