package app.sroka.core.model

import java.security.SecureRandom

/**
 * UUIDv7 (RFC 9562), port of shared `uuidv7`: 48-bit unix ms, version 7, 12-bit counter, variant,
 * random tail. Monotonic within the process, so ids sort lexicographically in creation order.
 */
fun newUuidV7(nowMillis: Long = System.currentTimeMillis()): String = UuidV7.next(nowMillis)

/** Unix-ms timestamp encoded in a UUIDv7, or null if [id] is not a v7 UUID. */
fun uuidV7Time(id: String): Long? {
    if (!UUID_RE.matches(id) || id[14] != '7') return null
    return (id.substring(0, 8) + id.substring(9, 13)).toLong(16)
}

private val UUID_RE = Regex("^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", RegexOption.IGNORE_CASE)

private object UuidV7 {
    private val random = SecureRandom()
    private var lastMs = -1L
    private var counter = 0

    @Synchronized
    fun next(now: Long): String {
        var ms = now
        if (ms <= lastMs) {
            ms = lastMs
            counter++
            if (counter > 0xfff) {
                ms = lastMs + 1
                counter = random.nextInt(0x800)
            }
        } else {
            counter = random.nextInt(0x800)
        }
        lastMs = ms

        val b = ByteArray(16)
        random.nextBytes(b)
        for (i in 0..5) b[i] = (ms ushr (8 * (5 - i))).toByte()
        b[6] = (0x70 or ((counter ushr 8) and 0x0f)).toByte()
        b[7] = (counter and 0xff).toByte()
        b[8] = (0x80 or (b[8].toInt() and 0x3f)).toByte()

        val sb = StringBuilder(36)
        for (i in 0 until 16) {
            val v = b[i].toInt() and 0xff
            sb.append(HEX[v ushr 4]).append(HEX[v and 0x0f])
            if (i == 3 || i == 5 || i == 7 || i == 9) sb.append('-')
        }
        return sb.toString()
    }

    private val HEX = "0123456789abcdef".toCharArray()
}
