package app.sroka.feature.reader.impl

/**
 * Size-bounded LRU for page bitmaps with leases: an entry is only evicted (and recycled) while nobody
 * holds a lease on it, so a bitmap that is on screen is never recycled under the compositor.
 * [clear] retires everything; leased entries are recycled when their last lease is released.
 */
internal class RefCountedCache<K : Any, V : Any>(
    private val maxBytes: Long,
    private val sizeOf: (V) -> Long,
    private val recycle: (V) -> Unit,
) {
    class Lease<V : Any> internal constructor(internal val entry: Entry<V>) {
        val value: V get() = entry.value
    }

    class Entry<V : Any> internal constructor(val value: V, val bytes: Long) {
        internal var leases = 0
        internal var retired = false
    }

    private val map = LinkedHashMap<K, Entry<V>>(16, 0.75f, true)
    private var bytes = 0L

    val sizeBytes: Long @Synchronized get() = bytes
    val count: Int @Synchronized get() = map.size

    /** Leases the cached value for [key], or null. */
    @Synchronized
    fun acquire(key: K): Lease<V>? = map[key]?.let { entry ->
        entry.leases++
        Lease(entry)
    }

    /** Stores [value] (replacing and retiring an older entry) and returns a lease on it. */
    @Synchronized
    fun put(key: K, value: V): Lease<V> {
        map.remove(key)?.let { bytes -= it.bytes; retire(it) }
        val entry = Entry(value, sizeOf(value)).also { it.leases = 1 }
        map[key] = entry
        bytes += entry.bytes
        trim()
        return Lease(entry)
    }

    @Synchronized
    fun release(lease: Lease<V>) {
        val entry = lease.entry
        if (entry.leases > 0) entry.leases--
        if (entry.retired && entry.leases == 0) recycle(entry.value)
    }

    @Synchronized
    fun clear() {
        map.values.toList().forEach { retire(it) }
        map.clear()
        bytes = 0
    }

    private fun retire(entry: Entry<V>) {
        if (!entry.retired) {
            entry.retired = true
            if (entry.leases == 0) recycle(entry.value)
        }
    }

    private fun trim() {
        if (bytes <= maxBytes) return
        val it = map.entries.iterator()
        while (bytes > maxBytes && it.hasNext()) {
            val (_, entry) = it.next()
            if (entry.leases > 0) continue
            it.remove()
            bytes -= entry.bytes
            entry.retired = true
            recycle(entry.value)
        }
    }
}
