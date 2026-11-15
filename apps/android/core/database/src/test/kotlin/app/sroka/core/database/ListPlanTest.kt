package app.sroka.core.database

import androidx.room3.useReaderConnection
import app.sroka.core.database.dao.itemListSql
import app.sroka.core.model.ItemQuery
import app.sroka.core.model.LibraryTab
import app.sroka.core.model.SortOrder
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The list/search queries must be index-driven: no full scan of `items` (alias `i`). */
class ListPlanTest : DatabaseTestBase() {

    /**
     * EXPLAIN returns rows but the androidx.sqlite Android driver runs it as an update, so replay the
     * schema (read via ordinary SELECTs) into a plain framework database and EXPLAIN there.
     */
    private fun plan(sql: String): String = runBlocking {
        val ddl = db.useReaderConnection { connection ->
            connection.usePrepared(
                "SELECT sql FROM sqlite_master WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%' " +
                    "AND name NOT LIKE 'items_fts_%' AND name NOT LIKE 'room_%' AND name != 'android_metadata' ORDER BY type = 'index', rowid",
            ) { stmt -> buildList { while (stmt.step()) add(stmt.getText(0)) } }
        }
        val plain = android.database.sqlite.SQLiteDatabase.create(null)
        try {
            ddl.forEach { plain.execSQL(it) }
            plain.rawQuery("EXPLAIN QUERY PLAN $sql", null).use { c ->
                buildString { while (c.moveToNext()) appendLine(c.getString(3)) }
            }
        } finally {
            plain.close()
        }
    }

    private val fullScanOfItems = Regex("""SCAN i\b""")

    private fun assertIndexed(sql: String) {
        val p = plan(sql)
        assertFalse("full scan of items:\n$p", fullScanOfItems.containsMatchIn(p))
    }

    /** [query]'s statement with its bound arguments inlined as literals. */
    private fun literalSql(query: ItemQuery): String {
        val built = itemListSql(query)
        var i = 0
        return built.sql.replace(Regex("""\?""")) {
            when (val arg = built.args[i++]) {
                is Long -> arg.toString()
                else -> "'" + arg.toString().replace("'", "''") + "'"
            }
        }
    }

    @Test fun listQueriesDoNotScanItems() {
        val tabs = listOf(LibraryTab.MY_LIST, LibraryTab.ARCHIVE, LibraryTab.FAVORITES)
        for (sort in SortOrder.entries) {
            for (tab in tabs) {
                assertIndexed(literalSql(ItemQuery(tab, sort = sort)))
                assertIndexed(literalSql(ItemQuery(tab, sort = sort, favoritesOnly = true, maxReadingMinutes = 9)))
                assertIndexed(literalSql(ItemQuery(tab, sort = sort, search = "x")))
                assertIndexed(literalSql(ItemQuery(tab, sort = sort, tag = "x", favoritesOnly = true)))
                assertIndexed(literalSql(ItemQuery(tab, sort = sort, tag = "x", search = "x", maxReadingMinutes = 9)))
            }
            assertIndexed(literalSql(ItemQuery(tab = null, sort = sort, tag = "x")))
            assertIndexed(literalSql(ItemQuery(tab = null, sort = sort, tag = "x", search = "x")))
        }
    }

    @Test fun newestAndOldestNeedNoTempSort() {
        for (sort in listOf(SortOrder.NEWEST, SortOrder.OLDEST)) {
            for (tab in listOf(LibraryTab.MY_LIST, LibraryTab.ARCHIVE, LibraryTab.FAVORITES)) {
                val p = plan(literalSql(ItemQuery(tab, sort = sort)))
                assertTrue(p, p.contains("index_items_"))
                assertFalse("temp sort:\n$p", p.contains("TEMP B-TREE FOR ORDER BY"))
            }
        }
    }
}
