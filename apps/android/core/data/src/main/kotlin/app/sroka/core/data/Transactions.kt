package app.sroka.core.data

import androidx.room3.withWriteTransaction
import app.sroka.core.database.SrokaDatabase

/** One write transaction across DAOs (DECISIONS A7). Never call the network inside [block]. */
internal suspend fun <R> SrokaDatabase.tx(block: suspend () -> R): R = withWriteTransaction { block() }
