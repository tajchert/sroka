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

    private fun createV1(file: File) = runBlocking {
        val db = schema(1)
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
            connection.execSQL("PRAGMA user_version = 1")
            connection.execSQL(
                "INSERT INTO items (id, url, canonical_url, content_private, parse_status, status, is_favorite, progress, saved_at, fts_rowid, title) " +
                    "VALUES ('old', 'https://example.com/a', 'https://example.com/a', 0, 'OK', 'UNREAD', 0, 0, 5, 1, 'Old article')",
            )
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

    @Test fun exportedV2SchemaHasPdfColumns() {
        val items = schema(2)["entities"]!!.jsonArray.map { it.jsonObject }.first { it["tableName"]!!.jsonPrimitive.content == "items" }
        val columns = items["fields"]!!.jsonArray.map { it.jsonObject["columnName"]!!.jsonPrimitive.content }
        assertEquals(true, columns.containsAll(listOf("kind", "file_name", "file_size")))
    }
}
