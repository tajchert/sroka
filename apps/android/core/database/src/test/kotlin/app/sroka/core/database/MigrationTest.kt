package app.sroka.core.database

import android.content.Context
import androidx.room3.Room
import androidx.sqlite.driver.AndroidSQLiteDriver
import androidx.sqlite.execSQL
import androidx.test.core.app.ApplicationProvider
import app.sroka.core.model.ItemKind
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.File

/**
 * v1 -> v2 on a real file: the v1 database is built from the exported `schemas/…/1.json`, then opened
 * through Room with [MIGRATION_1_2] (Room validates the resulting schema against v2).
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class MigrationTest {
    private val context get() = ApplicationProvider.getApplicationContext<Context>()

    private fun schema(version: Int): JsonObject {
        val file = File("schemas/app.sroka.core.database.SrokaDatabase/$version.json")
        return Json.parseToJsonElement(file.readText()).jsonObject["database"]!!.jsonObject
    }

    private fun createV1(file: File) = createAt(file, 1)

    private fun createAt(file: File, version: Int) = runBlocking {
        val db = schema(version)
        val driver = AndroidSQLiteDriver()
        val connection = driver.open(file.absolutePath)
        try {
            val statements = mutableListOf<String>()
            for (entity in db["entities"]!!.jsonArray) {
                val e = entity.jsonObject
                val table = e["tableName"]!!.jsonPrimitive.content
                statements += e["createSql"]!!.jsonPrimitive.content.replace("\${TABLE_NAME}", table)
                (e["indices"] as? JsonArray)?.forEach {
                    statements += it.jsonObject["createSql"]!!.jsonPrimitive.content.replace("\${TABLE_NAME}", table)
                }
            }
            db["setupQueries"]!!.jsonArray.forEach { statements += it.jsonPrimitive.content }
            statements.forEach { connection.execSQL(it) }
            connection.execSQL("PRAGMA user_version = $version")
            connection.execSQL(
                "INSERT INTO items (id, url, canonical_url, content_private, parse_status, status, is_favorite, progress, saved_at, fts_rowid, title) " +
                    "VALUES ('old', 'https://example.com/a', 'https://example.com/a', 0, 'OK', 'UNREAD', 0, 0, 5, 1, 'Old article')",
            )
            connection.execSQL("INSERT INTO sync_state (id, cursor, full_resync) VALUES (1, 207, 0)")
        } finally {
            connection.close()
        }
    }

    @Test fun migratesV1ToV2KeepingRowsAsArticles() = runBlocking {
        val file = context.getDatabasePath("migration-test.db").apply { parentFile?.mkdirs(); delete() }
        createV1(file)
        val db = Room.databaseBuilder<SrokaDatabase>(context, file.absolutePath)
            .setDriver(AndroidSQLiteDriver())
            .addMigrations(*ALL_MIGRATIONS)
            .build()
        try {
            val detail = db.itemDao().getItem("old")!!
            assertEquals("Old article", detail.title)
            assertEquals(ItemKind.ARTICLE, detail.kind)
            assertNull(detail.fileName)
            assertNull(detail.fileSize)
        } finally {
            db.close()
            file.delete()
        }
    }

    /** Rows pulled by a v1 app lack `kind`; the upgrade must re-pull everything so PDF items become PDFs. */
    @Test fun migrationToV2RestartsSyncFromCursorZero() = runBlocking {
        val file = context.getDatabasePath("migration-cursor-test.db").apply { parentFile?.mkdirs(); delete() }
        createV1(file)
        val db = Room.databaseBuilder<SrokaDatabase>(context, file.absolutePath)
            .setDriver(AndroidSQLiteDriver())
            .addMigrations(*ALL_MIGRATIONS)
            .build()
        try {
            assertEquals(0L, db.syncStateDao().get().cursor)
        } finally {
            db.close()
            file.delete()
        }
    }

    /** 1.1.0 shipped v2 without the cursor reset; v3 repeats it for devices already on v2. */
    @Test fun migrationV2ToV3RestartsSyncFromCursorZero() = runBlocking {
        val file = context.getDatabasePath("migration-v3-test.db").apply { parentFile?.mkdirs(); delete() }
        createAt(file, 2)
        val db = Room.databaseBuilder<SrokaDatabase>(context, file.absolutePath)
            .setDriver(AndroidSQLiteDriver())
            .addMigrations(*ALL_MIGRATIONS)
            .build()
        try {
            assertEquals(0L, db.syncStateDao().get().cursor)
            assertEquals("Old article", db.itemDao().getItem("old")!!.title)
        } finally {
            db.close()
            file.delete()
        }
    }

    @Test fun exportedV2SchemaHasPdfColumns() {
        val items = schema(2)["entities"]!!.jsonArray.map { it.jsonObject }.first { it["tableName"]!!.jsonPrimitive.content == "items" }
        val columns = items["fields"]!!.jsonArray.map { it.jsonObject["columnName"]!!.jsonPrimitive.content }
        assertEquals(true, columns.containsAll(listOf("kind", "file_name", "file_size")))
    }
}
