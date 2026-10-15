package app.sroka.core.common

import javax.inject.Inject
import javax.inject.Singleton

/** Wall clock seam so time-dependent code (ops `at`, eviction, uuidv7) is testable. */
fun interface Clock {
    /** Epoch milliseconds. */
    fun now(): Long
}

/** [Clock] backed by [System.currentTimeMillis]. */
@Singleton
class SystemClock @Inject constructor() : Clock {
    override fun now(): Long = System.currentTimeMillis()
}
