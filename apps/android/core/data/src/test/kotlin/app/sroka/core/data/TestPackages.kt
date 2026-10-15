package app.sroka.core.data

import java.io.ByteArrayOutputStream
import java.io.File
import java.security.MessageDigest
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

/** Builds article packages like packages/extractor `buildPackage`. */
object TestPackages {
    fun zip(entries: Map<String, ByteArray>): ByteArray {
        val out = ByteArrayOutputStream()
        ZipOutputStream(out).use { z ->
            for ((name, bytes) in entries) {
                z.putNextEntry(ZipEntry(name))
                z.write(bytes)
                z.closeEntry()
            }
        }
        return out.toByteArray()
    }

    fun packageBytes(html: String, corruptSha: Boolean = false): ByteArray {
        val article = html.toByteArray()
        val img = byteArrayOf(1, 2, 3, 4)
        val articleSha = if (corruptSha) "0".repeat(64) else sha(article)
        val manifest = """{"format":1,"contentId":"c","parserVersion":1,"files":[""" +
            """{"path":"article.html","sha256":"$articleSha","bytes":${article.size}},""" +
            """{"path":"img/a.webp","sha256":"${sha(img)}","bytes":4}]}"""
        return zip(linkedMapOf("manifest.json" to manifest.toByteArray(), "article.html" to article, "img/a.webp" to img))
    }

    fun validZip(file: File, html: String, corruptSha: Boolean = false): File =
        file.also { it.writeBytes(packageBytes(html, corruptSha)) }

    private fun sha(b: ByteArray) = MessageDigest.getInstance("SHA-256").digest(b).joinToString("") { "%02x".format(it) }
}
