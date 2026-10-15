package app.sroka.core.data

import app.sroka.core.data.content.PackageInstaller
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class PackageInstallerTest {
    @get:Rule val tmp = TemporaryFolder()

    private val installer = PackageInstaller()
    private val articles by lazy { tmp.newFolder("articles") }

    private fun zip(entries: Map<String, ByteArray>) = tmp.newFile().also { it.writeBytes(TestPackages.zip(entries)) }

    @Test fun installsValidPackage() {
        val result = installer.install(TestPackages.validZip(tmp.newFile(), "<p>Hello</p>"), articles, "i1")
        assertTrue(result is PackageInstaller.Result.Installed)
        assertEquals("<p>Hello</p>", File(articles, "i1/article.html").readText())
        assertTrue(File(articles, "i1/img/a.webp").isFile)
        assertFalse(File(articles, "i1.tmp").exists())
    }

    @Test fun rejectsParentTraversal() {
        val result = installer.install(zip(mapOf("../evil.txt" to byteArrayOf(1))), articles, "i1")
        assertEquals(PackageInstaller.Result.Invalid("unsafe_path"), result)
        assertFalse(File(articles, "evil.txt").exists())
        assertFalse(File(tmp.root, "evil.txt").exists())
    }

    @Test fun rejectsAbsoluteAndNestedTraversal() {
        assertEquals(PackageInstaller.Result.Invalid("unsafe_path"), installer.install(zip(mapOf("/etc/x" to byteArrayOf(1))), articles, "i1"))
        assertEquals(PackageInstaller.Result.Invalid("unsafe_path"), installer.install(zip(mapOf("img/../../x" to byteArrayOf(1))), articles, "i1"))
        assertEquals(PackageInstaller.Result.Invalid("unsafe_path"), installer.install(zip(mapOf("a\\..\\x" to byteArrayOf(1))), articles, "i1"))
    }

    @Test fun enforcesEntryAndSizeCaps() {
        val many = (0..5).associate { "f$it" to byteArrayOf(1) }
        assertEquals(PackageInstaller.Result.Invalid("too_many_entries"), PackageInstaller(maxEntries = 3).install(zip(many), articles, "i1"))
        val big = mapOf("big" to ByteArray(10_000))
        assertEquals(PackageInstaller.Result.Invalid("too_large"), PackageInstaller(maxTotalBytes = 1_000).install(zip(big), articles, "i1"))
    }

    @Test fun shaMismatchKeepsPreviousPackage() {
        installer.install(TestPackages.validZip(tmp.newFile(), "<p>old</p>"), articles, "i1")
        val bad = TestPackages.validZip(tmp.newFile(), "<p>new</p>", corruptSha = true)
        assertEquals(PackageInstaller.Result.Invalid("sha256_mismatch"), installer.install(bad, articles, "i1"))
        assertEquals("<p>old</p>", File(articles, "i1/article.html").readText())
        assertFalse(File(articles, "i1.tmp").exists())
    }

    @Test fun safeRelativePath() {
        assertEquals("img/a.webp", PackageInstaller.safeRelativePath("img/a.webp"))
        assertNull(PackageInstaller.safeRelativePath("./a"))
        assertNull(PackageInstaller.safeRelativePath("C:/a"))
        assertNull(PackageInstaller.safeRelativePath("a//b"))
    }

    @Test fun unsafeItemIdIsRejectedBeforeTouchingTheDisk() {
        val outside = File(tmp.root, "datastore").also { it.mkdirs(); File(it, "keep").writeText("x") }
        val pkg = TestPackages.validZip(tmp.newFile(), "<p>x</p>")
        for (bad in listOf("..", "../datastore", "a/b", "")) {
            assertEquals(PackageInstaller.Result.Invalid("unsafe_id"), installer.install(pkg, articles, bad))
        }
        assertTrue(File(outside, "keep").exists())
        assertEquals(0, articles.list()!!.size)
    }

    @Test fun ioFailureIsTransientNotInvalid() {
        // `articles` is a regular file: creating the tmp directory fails like a full disk would.
        val notADir = tmp.newFile("articles-file")
        val result = installer.install(TestPackages.validZip(tmp.newFile(), "<p>x</p>"), notADir, "i1")
        assertEquals(PackageInstaller.Result.IoError, result)
    }
}
