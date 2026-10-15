package app.sroka.core.database

import androidx.room3.useReaderConnection
import app.sroka.core.database.dao.FROM_TAG
import app.sroka.core.database.dao.LIST_FROM
import app.sroka.core.database.dao.MATCH
import app.sroka.core.database.dao.ORDER_LONGEST
import app.sroka.core.database.dao.ORDER_NEWEST
import app.sroka.core.database.dao.ORDER_OLDEST
import app.sroka.core.database.dao.ORDER_SHORTEST
import app.sroka.core.database.dao.ROW_COLUMNS
import app.sroka.core.database.dao.SCOPE_FAV
import app.sroka.core.database.dao.SCOPE_STATUS
import app.sroka.core.database.dao.SCOPE_TAG
import app.sroka.core.database.dao.SEARCH_FROM
import app.sroka.core.database.dao.SEARCH_TAG_FROM
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The list/search queries must be index-driven: no full scan of `items` (alias `i`). */
class ListPlanTest : DatabaseTestBase() {

    private val orders = listOf(ORDER_NEWEST, ORDER_OLDEST, ORDER_SHORTEST, ORDER_LONGEST)

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
            val literal = sql.replace(":status", "'UNREAD'").replace(":tagKey", "'x'").replace(":match", "'x*'")
            plain.rawQuery("EXPLAIN QUERY PLAN $literal", null).use { c ->
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

    @Test fun listQueriesDoNotScanItems() {
        for (order in orders) {
            assertIndexed("$ROW_COLUMNS $LIST_FROM $SCOPE_STATUS $order")
            assertIndexed("$ROW_COLUMNS $LIST_FROM $SCOPE_FAV $order")
            assertIndexed("$ROW_COLUMNS $FROM_TAG $SCOPE_TAG $order")
            assertIndexed("$ROW_COLUMNS $SEARCH_FROM WHERE $MATCH AND i.status = :status $order")
            assertIndexed("$ROW_COLUMNS $SEARCH_FROM WHERE $MATCH AND i.is_favorite = 1 $order")
            assertIndexed("$ROW_COLUMNS $SEARCH_TAG_FROM WHERE $MATCH AND t.name_key = :tagKey $order")
        }
    }

    @Test fun newestAndOldestNeedNoTempSort() {
        for (order in listOf(ORDER_NEWEST, ORDER_OLDEST)) {
            for (scope in listOf(SCOPE_STATUS, SCOPE_FAV)) {
                val p = plan("$ROW_COLUMNS $LIST_FROM $scope $order")
                assertTrue(p, p.contains("index_items_"))
                assertFalse("temp sort:\n$p", p.contains("TEMP B-TREE FOR ORDER BY"))
            }
        }
    }
}
