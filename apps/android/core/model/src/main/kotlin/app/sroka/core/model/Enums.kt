package app.sroka.core.model

/** Wire `status` (api.md §4.1). */
enum class ItemStatus { UNREAD, ARCHIVED }

/** Wire `parseStatus` (api.md §4.1). */
enum class ParseStatus { PENDING, OK, PARTIAL, FAILED }

/** Local availability of an item's article package (DECISIONS A4/A9). */
enum class OfflineState {
    /** The server has no content for this item yet. */
    NONE,

    /** Content exists on the server but is not downloaded (or the local copy is stale). */
    AVAILABLE_REMOTE,
    QUEUED,
    DOWNLOADING,
    DOWNLOADED,
    FAILED,
}

/** Top-level library lists. Tags is a separate destination (see [ItemQuery.tag]). */
enum class LibraryTab { MY_LIST, ARCHIVE, FAVORITES }

enum class SortOrder { NEWEST, OLDEST, SHORTEST, LONGEST }

/** When article packages are downloaded automatically (DECISIONS A9). */
enum class DownloadPolicy { WIFI_ONLY, ANY_NETWORK, MANUAL }

enum class ThemeMode { SYSTEM, LIGHT, DARK }

enum class ReaderTheme { AUTO, LIGHT, SEPIA, DARK }
