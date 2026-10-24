package app.sroka.core.database

import androidx.room3.migration.Migration
import androidx.sqlite.execSQL

/** v1 -> v2: PDF items (`kind`, `file_name`, `file_size`). Existing rows are articles. */
val MIGRATION_1_2: Migration = Migration(1, 2) { connection ->
    connection.execSQL("ALTER TABLE `items` ADD COLUMN `kind` TEXT NOT NULL DEFAULT 'ARTICLE'")
    connection.execSQL("ALTER TABLE `items` ADD COLUMN `file_name` TEXT")
    connection.execSQL("ALTER TABLE `items` ADD COLUMN `file_size` INTEGER")
}

/** Every migration, in order; registered by `DatabaseModule` and the migration test. */
val ALL_MIGRATIONS: Array<Migration> = arrayOf(MIGRATION_1_2)
