package app.sroka.core.data.content

import java.io.File

/**
 * On-disk layout (DECISIONS A4/A9): packages in `filesDir/articles/{itemId}/`, thumbnails in
 * `filesDir/thumbs/{itemId}.webp`, temporary downloads in `cacheDir/dl/`.
 */
class ContentPaths(filesDir: File, cacheDir: File) {
    val articles: File = File(filesDir, "articles")
    val thumbs: File = File(filesDir, "thumbs")
    val downloads: File = File(cacheDir, "dl")

    fun articleDir(itemId: String) = File(articles, safe(itemId))

    fun thumb(itemId: String) = File(thumbs, "${safe(itemId)}.webp")

    fun packageZip(itemId: String) = File(downloads, "${safe(itemId)}.zip")

    /** Temporary thumbnail download (moved to [thumb] once the item is confirmed to still exist). */
    fun thumbTemp(itemId: String) = File(downloads, "${safe(itemId)}.thumb")

    /** Removes the package, thumbnail and any partial download of one item. No-op for an unsafe id. */
    fun deleteItemFiles(itemId: String) {
        if (!isSafeId(itemId)) return
        articleDir(itemId).deleteRecursively()
        File(articles, "$itemId$TMP_SUFFIX").deleteRecursively()
        File(articles, "$itemId$OLD_SUFFIX").deleteRecursively()
        thumb(itemId).delete()
        packageZip(itemId).delete()
        thumbTemp(itemId).delete()
    }

    fun deleteAll() {
        articles.deleteRecursively()
        thumbs.deleteRecursively()
        downloads.deleteRecursively()
    }

    /** Bytes on disk used by packages and thumbnails. */
    fun usageBytes(): Long = sizeOf(articles) + sizeOf(thumbs)

    /** Free bytes on the volume that holds (or will hold) the article packages. */
    fun usableBytes(): Long {
        var dir: File? = articles
        while (dir != null && !dir.exists()) dir = dir.parentFile
        return dir?.usableSpace ?: Long.MAX_VALUE
    }

    private fun sizeOf(dir: File): Long =
        if (!dir.exists()) 0 else dir.walkTopDown().filter { it.isFile }.sumOf { it.length() }

    private fun safe(itemId: String): String {
        require(isSafeId(itemId)) { "unsafe item id" }
        return itemId
    }

    companion object {
        private val SAFE_ID = Regex("^[A-Za-z0-9_-]{1,64}$")

        /** Item ids come from the server and become path components: only `[A-Za-z0-9_-]{1,64}`. */
        fun isSafeId(id: String): Boolean = SAFE_ID.matches(id)

        const val TMP_SUFFIX = ".tmp"
        const val OLD_SUFFIX = ".old"
    }
}
