package app.sroka.core.data.content

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.File
import java.io.IOException
import java.security.MessageDigest
import java.util.zip.ZipInputStream

/**
 * Safely unpacks an article package (`package.zip`: `manifest.json`, `article.html`, `img/…`) into
 * `articles/{itemId}/` (DECISIONS A9):
 * - rejects absolute paths, `..`/`.` segments, backslashes, drive letters and anything resolving outside
 *   the target directory (zip-slip);
 * - caps the number of entries and the total uncompressed bytes (counted while writing, not trusted
 *   from headers);
 * - verifies every `manifest.files[].sha256`;
 * - swaps the new directory in by rename, so a failure leaves any previous package untouched.
 */
internal class PackageInstaller(
    private val maxTotalBytes: Long = MAX_TOTAL_BYTES,
    private val maxEntries: Int = MAX_ENTRIES,
) {
    sealed interface Result {
        data class Installed(val bytes: Long) : Result
        data class Invalid(val reason: String) : Result
    }

    fun install(zip: File, articlesDir: File, itemId: String): Result {
        articlesDir.mkdirs()
        val tmp = File(articlesDir, itemId + ContentPaths.TMP_SUFFIX)
        tmp.deleteRecursively()
        return try {
            if (!tmp.mkdirs()) throw IOException("mkdir")
            unzip(zip, tmp)
            verify(tmp)
            val target = File(articlesDir, itemId)
            swap(tmp, target, File(articlesDir, itemId + ContentPaths.OLD_SUFFIX))
            Result.Installed(target.walkTopDown().filter { it.isFile }.sumOf { it.length() })
        } catch (e: InvalidPackageException) {
            tmp.deleteRecursively()
            Result.Invalid(e.message ?: "invalid_package")
        } catch (e: IOException) {
            tmp.deleteRecursively()
            Result.Invalid("io_error")
        }
    }

    private fun unzip(zip: File, dir: File) {
        val root = dir.canonicalFile
        var entries = 0
        var total = 0L
        val seen = HashSet<String>()
        ZipInputStream(zip.inputStream().buffered()).use { zis ->
            val buffer = ByteArray(BUFFER)
            while (true) {
                val entry = zis.nextEntry ?: break
                if (++entries > maxEntries) invalid("too_many_entries")
                val name = safeRelativePath(entry.name) ?: invalid("unsafe_path")
                if (!seen.add(name.lowercase())) invalid("duplicate_entry")
                val out = File(root, name).canonicalFile
                if (!out.path.startsWith(root.path + File.separator)) invalid("unsafe_path")
                if (entry.isDirectory) {
                    out.mkdirs()
                    continue
                }
                out.parentFile?.mkdirs()
                out.outputStream().buffered().use { os ->
                    while (true) {
                        val n = zis.read(buffer)
                        if (n < 0) break
                        total += n
                        if (total > maxTotalBytes) invalid("too_large")
                        os.write(buffer, 0, n)
                    }
                }
            }
        }
        if (entries == 0) invalid("empty")
    }

    private fun verify(dir: File) {
        val manifestFile = File(dir, MANIFEST)
        if (!manifestFile.isFile) invalid("no_manifest")
        val manifest = try {
            JSON.decodeFromString(Manifest.serializer(), manifestFile.readText())
        } catch (e: IllegalArgumentException) {
            invalid("bad_manifest")
        }
        if (manifest.files.none { it.path == ARTICLE }) invalid("no_article")
        for (f in manifest.files) {
            val path = safeRelativePath(f.path) ?: invalid("unsafe_path")
            val file = File(dir, path)
            if (!file.isFile) invalid("missing_file")
            if (!sha256Hex(file).equals(f.sha256, ignoreCase = true)) invalid("sha256_mismatch")
        }
    }

    private fun swap(tmp: File, target: File, old: File) {
        old.deleteRecursively()
        if (target.exists() && !target.renameTo(old)) throw IOException("rename old")
        if (!tmp.renameTo(target)) {
            old.renameTo(target)
            throw IOException("rename new")
        }
        old.deleteRecursively()
    }

    @Serializable
    private data class Manifest(val files: List<ManifestFile> = emptyList())

    @Serializable
    private data class ManifestFile(val path: String, val sha256: String)

    private class InvalidPackageException(reason: String) : Exception(reason)

    companion object {
        const val MAX_TOTAL_BYTES = 50L * 1024 * 1024
        const val MAX_ENTRIES = 200
        const val MANIFEST = "manifest.json"
        const val ARTICLE = "article.html"
        private const val BUFFER = 64 * 1024
        private val JSON = Json { ignoreUnknownKeys = true }

        private fun invalid(reason: String): Nothing = throw InvalidPackageException(reason)

        /** Relative path with `/` separators, or null if it could escape the target directory. */
        fun safeRelativePath(name: String): String? {
            if (name.isEmpty() || name.length > 512) return null
            if (name.startsWith("/") || name.contains('\\') || name.contains(':') || name.contains('\u0000')) return null
            val segments = name.trimEnd('/').split('/')
            if (segments.any { it.isEmpty() || it == "." || it == ".." }) return null
            return segments.joinToString("/")
        }

        fun sha256Hex(file: File): String {
            val digest = MessageDigest.getInstance("SHA-256")
            file.inputStream().buffered().use { input ->
                val buffer = ByteArray(BUFFER)
                while (true) {
                    val n = input.read(buffer)
                    if (n < 0) break
                    digest.update(buffer, 0, n)
                }
            }
            return digest.digest().joinToString("") { "%02x".format(it) }
        }
    }
}
