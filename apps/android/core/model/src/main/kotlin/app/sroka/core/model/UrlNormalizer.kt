package app.sroka.core.model

import java.io.ByteArrayOutputStream
import java.net.IDN

/**
 * Port of shared `normalizeUrl` (api.md §13): the canonical URL used for local dedupe. A pure Kotlin
 * re-implementation of the WHATWG URL subset the rules need (core:model has no Android/OkHttp).
 *
 * 1. Only http/https; input trimmed. 2. Scheme + host lowercased, IDN → punycode, trailing host dot
 * removed. 3. Default ports dropped. 4. Userinfo and fragment removed. 5. Tracking params removed.
 * 6. Remaining params stably sorted by name, re-serialized form-urlencoded (space → `+`). 7. Path kept
 * (trailing slash kept; empty → `/`). 8. `www.` kept, scheme not upgraded.
 */
object UrlNormalizer {

    /** Exact-name tracking parameters (compared lower-case); any `utm_*` is also tracking. */
    val TRACKING_PARAMS: Set<String> = setOf(
        "fbclid", "gclid", "dclid", "gbraid", "wbraid", "msclkid", "mc_eid", "mc_cid",
        "igshid", "ref_src", "_hsenc", "_hsmktg", "yclid",
    )

    fun isTrackingParam(name: String): Boolean {
        val n = name.lowercase()
        return n.startsWith("utm_") || n in TRACKING_PARAMS
    }

    /** Canonical form of [input], or null if it is not an absolute http(s) URL. */
    fun normalize(input: String): String? {
        val u = parse(input) ?: return null
        val kept = u.query?.let(::parseQuery).orEmpty()
            .filterNot { isTrackingParam(it.first) }
            .sortedWith { a, b -> a.first.compareTo(b.first) } // sortedWith is stable
        val query = if (kept.isEmpty()) {
            ""
        } else {
            "?" + kept.joinToString("&") { (k, v) -> formEncode(k) + "=" + formEncode(v) }
        }
        val port = u.port?.let { ":$it" }.orEmpty()
        return "${u.scheme}://${u.host}$port${u.path}$query"
    }

    /** True if [s] parses as an absolute http(s) URL with a host. */
    fun isHttpUrl(s: String): Boolean = parse(s) != null

    /** Lower-cased (punycode) host of [url], or null if it is not an http(s) URL. */
    fun hostOf(url: String): String? = parse(url)?.host

    private val TRAILING_PUNCT = Regex("[.,;:!?'\"»”’…]+$")
    private val URL_IN_TEXT = Regex("(?U)https?://[^\\s<>\"'`]+", RegexOption.IGNORE_CASE)
    private val BRACKETS = listOf('(' to ')', '[' to ']', '{' to '}')

    /**
     * First http(s) URL in free text (e.g. share text "Title https://…"), without trailing punctuation
     * or unbalanced closing brackets. Port of shared `extractFirstUrl`.
     */
    fun extractFirstUrl(text: String): String? {
        var s = URL_IN_TEXT.find(text)?.value ?: return null
        while (true) {
            val before = s
            s = s.replace(TRAILING_PUNCT, "")
            for ((open, close) in BRACKETS) {
                if (s.endsWith(close) && s.count { it == close } > s.count { it == open }) s = s.dropLast(1)
            }
            if (s == before) break
        }
        return s.takeIf(::isHttpUrl)
    }

    // ---------------------------------------------------------------------------------------------

    private class Parsed(val scheme: String, val host: String, val port: Int?, val path: String, val query: String?)

    private val SCHEME = Regex("^([A-Za-z][A-Za-z0-9+.\\-]*):(.*)$", RegexOption.DOT_MATCHES_ALL)
    private const val FORBIDDEN_HOST_CHARS = " #%/:<>?@[\\]^|"
    private const val HEX_UPPER = "0123456789ABCDEF"

    private fun parse(input: String): Parsed? {
        val cleaned = input.trim().filterNot { it == '\t' || it == '\n' || it == '\r' }
        val m = SCHEME.matchEntire(cleaned) ?: return null
        val scheme = m.groupValues[1].lowercase()
        if (scheme != "http" && scheme != "https") return null
        val rest = m.groupValues[2].trimStart('/', '\\')

        val authEnd = rest.indexOfFirst { it == '/' || it == '\\' || it == '?' || it == '#' }
            .let { if (it < 0) rest.length else it }
        val authority = rest.substring(0, authEnd)
        val hostPort = authority.substring(authority.lastIndexOf('@') + 1)

        val rawHost: String
        val rawPort: String
        if (hostPort.startsWith("[")) {
            val close = hostPort.indexOf(']')
            if (close < 0) return null
            rawHost = hostPort.substring(0, close + 1)
            val after = hostPort.substring(close + 1)
            if (after.isNotEmpty() && !after.startsWith(":")) return null
            rawPort = after.removePrefix(":")
        } else {
            val colon = hostPort.lastIndexOf(':')
            rawHost = if (colon < 0) hostPort else hostPort.substring(0, colon)
            rawPort = if (colon < 0) "" else hostPort.substring(colon + 1)
        }

        val host = normalizeHost(rawHost) ?: return null
        val port = if (rawPort.isEmpty()) {
            null
        } else {
            if (!rawPort.all { it in '0'..'9' }) return null
            val p = rawPort.toIntOrNull()?.takeIf { it <= 65535 } ?: return null
            p.takeUnless { (scheme == "http" && it == 80) || (scheme == "https" && it == 443) }
        }

        val noFragment = rest.substring(authEnd).substringBefore('#')
        val qIndex = noFragment.indexOf('?')
        val rawPath = if (qIndex < 0) noFragment else noFragment.substring(0, qIndex)
        val query = if (qIndex < 0) null else noFragment.substring(qIndex + 1)
        return Parsed(scheme, host, port, normalizePath(rawPath), query)
    }

    private fun normalizeHost(raw: String): String? {
        if (raw.isEmpty()) return null
        if (raw.startsWith("[")) return raw.lowercase()
        val decoded = percentDecode(raw)
        if (decoded.any { it in FORBIDDEN_HOST_CHARS || it.code < 0x20 || it.code == 0x7f }) return null
        val ascii = try {
            IDN.toASCII(decoded.trimEnd('.'), IDN.ALLOW_UNASSIGNED)
        } catch (_: IllegalArgumentException) {
            return null
        }
        return ascii.lowercase().takeIf { it.isNotEmpty() }
    }

    private fun normalizePath(raw: String): String {
        if (raw.isEmpty()) return "/"
        val segments = raw.replace('\\', '/').removePrefix("/").split('/')
        val out = ArrayList<String>()
        segments.forEachIndexed { i, seg ->
            val last = i == segments.lastIndex
            when (seg.lowercase()) {
                ".", "%2e" -> if (last) out.add("")
                "..", ".%2e", "%2e.", "%2e%2e" -> {
                    out.removeLastOrNull()
                    if (last) out.add("")
                }
                else -> out.add(seg)
            }
        }
        return "/" + out.joinToString("/") { percentEncodePath(it) }
    }

    private fun percentEncodePath(s: String): String {
        val sb = StringBuilder()
        for (b in s.toByteArray(Charsets.UTF_8)) {
            val c = b.toInt() and 0xff
            if (c < 0x20 || c > 0x7e || c.toChar() in " \"#<>?`{}") sb.appendHex(c) else sb.append(c.toChar())
        }
        return sb.toString()
    }

    private fun parseQuery(q: String): List<Pair<String, String>> =
        q.split('&').filter { it.isNotEmpty() }.map { part ->
            val eq = part.indexOf('=')
            val name = if (eq < 0) part else part.substring(0, eq)
            val value = if (eq < 0) "" else part.substring(eq + 1)
            percentDecode(name.replace('+', ' ')) to percentDecode(value.replace('+', ' '))
        }

    private fun percentDecode(s: String): String {
        if ('%' !in s) return s
        val bytes = s.toByteArray(Charsets.UTF_8)
        val out = ByteArrayOutputStream(bytes.size)
        var i = 0
        while (i < bytes.size) {
            val b = bytes[i]
            if (b == '%'.code.toByte() && i + 2 <= bytes.lastIndex) {
                val hi = Character.digit(bytes[i + 1].toInt(), 16)
                val lo = Character.digit(bytes[i + 2].toInt(), 16)
                if (hi >= 0 && lo >= 0) {
                    out.write(hi * 16 + lo)
                    i += 3
                    continue
                }
            }
            out.write(b.toInt())
            i++
        }
        return out.toString(Charsets.UTF_8.name())
    }

    /** application/x-www-form-urlencoded byte serializer (as `URLSearchParams.toString()`). */
    private fun formEncode(s: String): String {
        val sb = StringBuilder()
        for (b in s.toByteArray(Charsets.UTF_8)) {
            val c = b.toInt() and 0xff
            val ch = c.toChar()
            when {
                ch in 'a'..'z' || ch in 'A'..'Z' || ch in '0'..'9' || ch in "*-._" -> sb.append(ch)
                c == 0x20 -> sb.append('+')
                else -> sb.appendHex(c)
            }
        }
        return sb.toString()
    }

    private fun StringBuilder.appendHex(c: Int) {
        append('%').append(HEX_UPPER[c ushr 4]).append(HEX_UPPER[c and 0x0f])
    }
}

/** First http(s) URL in free text; see [UrlNormalizer.extractFirstUrl]. */
fun extractFirstUrl(text: String): String? = UrlNormalizer.extractFirstUrl(text)
