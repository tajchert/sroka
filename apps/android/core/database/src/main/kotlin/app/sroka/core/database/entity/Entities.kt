package app.sroka.core.database.entity

import androidx.room3.ColumnInfo
import androidx.room3.Entity
import androidx.room3.ForeignKey
import androidx.room3.Fts4
import androidx.room3.FtsOptions
import androidx.room3.Index
import androidx.room3.PrimaryKey
import app.sroka.core.model.ItemKind
import app.sroka.core.model.ItemStatus
import app.sroka.core.model.ParseStatus

/** One live item (DECISIONS A4). A server tombstone deletes the row. */
@Entity(
    tableName = "items",
    indices = [
        Index(value = ["status", "saved_at", "id"]),
        Index(value = ["is_favorite", "saved_at", "id"]),
        Index(value = ["saved_at"]),
        Index(value = ["canonical_url"]),
        Index(value = ["fts_rowid"], unique = true),
    ],
)
data class ItemEntity(
    @PrimaryKey val id: String,
    val url: String,
    @ColumnInfo(name = "canonical_url") val canonicalUrl: String,
    val title: String?,
    val excerpt: String?,
    @ColumnInfo(name = "site_name") val siteName: String?,
    val author: String?,
    val lang: String?,
    @ColumnInfo(name = "lead_image_key") val leadImageKey: String?,
    @ColumnInfo(name = "word_count") val wordCount: Int?,
    @ColumnInfo(name = "reading_minutes") val readingMinutes: Int?,
    @ColumnInfo(name = "content_id") val contentId: String?,
    @ColumnInfo(name = "content_private") val contentPrivate: Boolean,
    @ColumnInfo(name = "parse_status") val parseStatus: ParseStatus,
    @ColumnInfo(name = "parse_error") val parseError: String?,
    val status: ItemStatus,
    @ColumnInfo(name = "is_favorite") val isFavorite: Boolean,
    val progress: Float,
    @ColumnInfo(name = "progress_anchor") val progressAnchor: Int?,
    @ColumnInfo(name = "saved_at") val savedAt: Long,
    @ColumnInfo(name = "archived_at") val archivedAt: Long?,
    @ColumnInfo(name = "last_read_at") val lastReadAt: Long?,
    val source: String?,
    /** Null = never seen from the server (locally created, not yet pushed/pulled). */
    @ColumnInfo(name = "server_seq") val serverSeq: Long?,
    /** Rowid of this item's `items_fts` row. Allocated by the DAO on first insert; callers pass 0. */
    @ColumnInfo(name = "fts_rowid") val ftsRowId: Long = 0,
    /** 1 while a full resync is in progress and the row was not (yet) re-pulled (A8.3). */
    @ColumnInfo(name = "resync_mark", defaultValue = "0") val resyncMark: Int = 0,
    /** Schema v2: `ARTICLE` (default) or `PDF`. */
    @ColumnInfo(name = "kind", defaultValue = "ARTICLE") val kind: ItemKind = ItemKind.ARTICLE,
    @ColumnInfo(name = "file_name") val fileName: String? = null,
    @ColumnInfo(name = "file_size") val fileSize: Long? = null,
)

/** Tag on an item. `nameKey` = `tagKey(name)` (case-insensitive identity). */
@Entity(
    tableName = "item_tags",
    primaryKeys = ["item_id", "name_key"],
    foreignKeys = [
        ForeignKey(
            entity = ItemEntity::class,
            parentColumns = ["id"],
            childColumns = ["item_id"],
            onDelete = ForeignKey.CASCADE,
        ),
    ],
    indices = [Index(value = ["name_key"])],
)
data class ItemTagEntity(
    @ColumnInfo(name = "item_id") val itemId: String,
    @ColumnInfo(name = "name_key") val nameKey: String,
    val name: String,
)

/** Server tag rows from pull (keeps empty tags and ids). */
@Entity(tableName = "tags", indices = [Index(value = ["name_key"], unique = true)])
data class TagEntity(
    @PrimaryKey val id: String,
    val name: String,
    @ColumnInfo(name = "name_key") val nameKey: String,
)

/**
 * Full-text index, standalone (stores its own copy so `body` can hold the downloaded article text).
 * rowid = `items.fts_rowid`. Maintained by [app.sroka.core.database.dao.ItemDao] only.
 *
 * `remove_diacritics=1` (not 2, as A4 says): 2 needs SQLite 3.27+ (API 30), minSdk is 26.
 */
@Fts4(
    tokenizer = FtsOptions.TOKENIZER_UNICODE61,
    tokenizerArgs = ["remove_diacritics=1"],
)
@Entity(tableName = "items_fts")
data class ItemFtsEntity(
    @PrimaryKey @ColumnInfo(name = "rowid") val rowId: Long,
    val title: String,
    val excerpt: String,
    @ColumnInfo(name = "site_name") val siteName: String,
    val tags: String,
    val body: String,
)

/** Un-pushed local mutation, `payload` = full wire JSON of the op (A7). */
@Entity(
    tableName = "pending_ops",
    indices = [Index(value = ["op_id"], unique = true), Index(value = ["item_id"])],
)
data class PendingOpEntity(
    @PrimaryKey(autoGenerate = true) @ColumnInfo(name = "local_seq") val localSeq: Long = 0,
    @ColumnInfo(name = "op_id") val opId: String,
    @ColumnInfo(name = "item_id") val itemId: String?,
    val type: String,
    val payload: String,
    @ColumnInfo(name = "created_at") val createdAt: Long,
    @ColumnInfo(defaultValue = "0") val attempts: Int = 0,
    @ColumnInfo(name = "last_error") val lastError: String? = null,
)

/** Single row (id = 1). */
@Entity(tableName = "sync_state")
data class SyncStateEntity(
    @PrimaryKey val id: Int = 1,
    val cursor: Long = 0,
    @ColumnInfo(name = "last_success_at") val lastSuccessAt: Long? = null,
    @ColumnInfo(name = "last_error") val lastError: String? = null,
    @ColumnInfo(name = "full_resync", defaultValue = "0") val fullResync: Boolean = false,
)

enum class ContentState { QUEUED, DOWNLOADING, DOWNLOADED, FAILED }

/** Downloaded-package bookkeeping; files live under filesDir (A4/A9). */
@Entity(
    tableName = "content_files",
    foreignKeys = [
        ForeignKey(
            entity = ItemEntity::class,
            parentColumns = ["id"],
            childColumns = ["item_id"],
            onDelete = ForeignKey.CASCADE,
        ),
    ],
    indices = [Index(value = ["state"])],
)
data class ContentFileEntity(
    @PrimaryKey @ColumnInfo(name = "item_id") val itemId: String,
    @ColumnInfo(name = "content_id") val contentId: String,
    val state: ContentState,
    @ColumnInfo(defaultValue = "0") val bytes: Long = 0,
    @ColumnInfo(defaultValue = "0") val attempts: Int = 0,
    val error: String? = null,
    @ColumnInfo(name = "downloaded_at") val downloadedAt: Long? = null,
    /** Absolute path of the local thumbnail file. */
    @ColumnInfo(name = "thumb_path") val thumbPath: String? = null,
    /** Failed thumbnail fetches (capped so a permanently broken image is not retried forever). */
    @ColumnInfo(name = "thumb_attempts", defaultValue = "0") val thumbAttempts: Int = 0,
)
