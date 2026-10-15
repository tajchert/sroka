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

    fun articleDir(itemId: String) = File(articles, itemId)

    fun thumb(itemId: String) = File(thumbs, "$itemId.webp")

    fun packageZip(itemId: String) = File(downloads, "$itemId.zip")

    /** Removes the package, thumbnail and any partial download of one item. */
    fun deleteItemFiles(itemId: String) {
        articleDir(itemId).deleteRecursively()
        File(articles, "$itemId$TMP_SUFFIX").deleteRecursively()
        File(articles, "$itemId$OLD_SUFFIX").deleteRecursively()
        thumb(itemId).delete()
        packageZip(itemId).delete()
    }

    fun deleteAll() {
        articles.deleteRecursively()
        thumbs.deleteRecursively()
        downloads.deleteRecursively()
    }

    /** Bytes on disk used by packages and thumbnails. */
    fun usageBytes(): Long = sizeOf(articles) + sizeOf(thumbs)

    private fun sizeOf(dir: File): Long =
        if (!dir.exists()) 0 else dir.walkTopDown().filter { it.isFile }.sumOf { it.length() }

    companion object {
        const val TMP_SUFFIX = ".tmp"
        const val OLD_SUFFIX = ".old"
    }
}
