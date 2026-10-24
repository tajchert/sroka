package app.sroka.core.database

import androidx.room3.migration.Migration
import androidx.sqlite.execSQL

/**
 * v1 -> v2: PDF items (`kind`, `file_name`, `file_size`). Existing rows default to articles, but a v1 app
 * may already have pulled PDF items without these fields, so the next sync restarts at cursor 0 (a full
 * pass, SyncEngine) and re-pulls every row with its real kind.
 */
val MIGRATION_1_2: Migration = Migration(1, 2) { connection ->
    connection.execSQL("ALTER TABLE `items` ADD COLUMN `kind` TEXT NOT NULL DEFAULT 'ARTICLE'")
    connection.execSQL("ALTER TABLE `items` ADD COLUMN `file_name` TEXT")
    connection.execSQL("ALTER TABLE `items` ADD COLUMN `file_size` INTEGER")
    connection.execSQL("UPDATE `sync_state` SET `cursor` = 0")
}

/**
 * v2 -> v3: no schema change. App 1.1.0 shipped v2 without the cursor reset above, so devices already on
 * v2 still hold PDF items stored as articles; restart the sync at cursor 0 once more.
 */
val MIGRATION_2_3: Migration = Migration(2, 3) { connection ->
    connection.execSQL("UPDATE `sync_state` SET `cursor` = 0")
}

/** Every migration, in order; registered by `DatabaseModule` and the migration test. */
val ALL_MIGRATIONS: Array<Migration> = arrayOf(MIGRATION_1_2, MIGRATION_2_3)
