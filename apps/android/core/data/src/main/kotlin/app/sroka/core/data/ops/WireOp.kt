package app.sroka.core.data.ops

import app.sroka.core.model.ItemStatus
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.floatOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put

/**
 * A sync op exactly as sent to `POST /v1/sync/push` (api.md §7.1). The JSON is stored verbatim in
 * `pending_ops.payload`, compact (no spaces) because alias handling rewrites `"itemId":"…"` in place.
 */
sealed interface WireOp {
    val opId: String
    val at: Long
    val type: String

    /** Target item, or null for tag-level ops. */
    val itemId: String?

    fun toJson(): JsonObject

    fun payload(): String = COMPACT.encodeToString(JsonObject.serializer(), toJson())

    data class Add(
        override val opId: String,
        override val itemId: String,
        override val at: Long,
        val url: String,
        val title: String?,
        val tags: List<String>,
        val source: String?,
        val savedAt: Long,
    ) : WireOp {
        override val type get() = ADD
        override fun toJson() = op {
            put("url", url)
            title?.let { put("title", it) }
            put("tags", JsonArray(tags.map(::JsonPrimitive)))
            source?.let { put("source", it) }
            put("savedAt", savedAt)
            put("onDuplicate", "readd")
        }
    }

    data class SetStatus(
        override val opId: String,
        override val itemId: String,
        override val at: Long,
        val status: ItemStatus,
    ) : WireOp {
        override val type get() = SET_STATUS
        override fun toJson() = op { put("status", status.wire) }
    }

    data class SetFavorite(
        override val opId: String,
        override val itemId: String,
        override val at: Long,
        val value: Boolean,
    ) : WireOp {
        override val type get() = SET_FAVORITE
        override fun toJson() = op { put("value", value) }
    }

    data class SetProgress(
        override val opId: String,
        override val itemId: String,
        override val at: Long,
        val progress: Float,
        val anchor: Int?,
    ) : WireOp {
        override val type get() = SET_PROGRESS
        override fun toJson() = op {
            put("progress", progress)
            anchor?.let { put("anchor", it) }
        }
    }

    data class Tag(
        override val opId: String,
        override val itemId: String,
        override val at: Long,
        val tag: String,
        val present: Boolean,
    ) : WireOp {
        override val type get() = TAG
        override fun toJson() = op {
            put("tag", tag)
            put("present", present)
        }
    }

    /** [title] null clears the user title (sent as `""`, api.md §8.3). */
    data class SetTitle(
        override val opId: String,
        override val itemId: String,
        override val at: Long,
        val title: String?,
    ) : WireOp {
        override val type get() = SET_TITLE
        override fun toJson() = op { put("title", title.orEmpty()) }
    }

    data class Delete(override val opId: String, override val itemId: String, override val at: Long) : WireOp {
        override val type get() = DELETE
        override fun toJson() = op { }
    }

    data class Refresh(override val opId: String, override val itemId: String, override val at: Long) : WireOp {
        override val type get() = REFRESH
        override fun toJson() = op { }
    }

    data class TagRename(override val opId: String, override val at: Long, val from: String, val to: String) : WireOp {
        override val type get() = TAG_RENAME
        override val itemId: String? get() = null
        override fun toJson() = op {
            put("from", from)
            put("to", to)
        }
    }

    data class TagDelete(override val opId: String, override val at: Long, val tag: String) : WireOp {
        override val type get() = TAG_DELETE
        override val itemId: String? get() = null
        override fun toJson() = op { put("tag", tag) }
    }

    companion object {
        const val ADD = "item.add"
        const val SET_STATUS = "item.setStatus"
        const val SET_FAVORITE = "item.setFavorite"
        const val SET_PROGRESS = "item.setProgress"
        const val TAG = "item.tag"
        const val SET_TITLE = "item.setTitle"
        const val DELETE = "item.delete"
        const val REFRESH = "item.refresh"
        const val TAG_RENAME = "tag.rename"
        const val TAG_DELETE = "tag.delete"

        internal val COMPACT = Json { prettyPrint = false }

        /** Parses a stored payload; null for unknown/corrupt ops. */
        fun parse(payload: String): WireOp? = runCatching {
            parse(COMPACT.parseToJsonElement(payload) as JsonObject)
        }.getOrNull()

        fun parse(o: JsonObject): WireOp? {
            val opId = o.str("opId") ?: return null
            val at = o["at"]?.jsonPrimitive?.longOrNull ?: return null
            val item = o.str("itemId")
            return when (o.str("type")) {
                ADD -> Add(
                    opId, item ?: return null, at,
                    url = o.str("url") ?: return null,
                    title = o.str("title"),
                    tags = o["tags"]?.jsonArray?.mapNotNull { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.content }.orEmpty(),
                    source = o.str("source"),
                    savedAt = o["savedAt"]?.jsonPrimitive?.longOrNull ?: at,
                )
                SET_STATUS -> SetStatus(opId, item ?: return null, at, statusFromWire(o.str("status")) ?: return null)
                SET_FAVORITE -> SetFavorite(opId, item ?: return null, at, o["value"]?.jsonPrimitive?.booleanOrNull ?: return null)
                SET_PROGRESS -> SetProgress(
                    opId, item ?: return null, at,
                    progress = o["progress"]?.jsonPrimitive?.floatOrNull ?: return null,
                    anchor = o["anchor"]?.jsonPrimitive?.intOrNull,
                )
                TAG -> Tag(
                    opId, item ?: return null, at,
                    tag = o.str("tag") ?: return null,
                    present = o["present"]?.jsonPrimitive?.booleanOrNull ?: return null,
                )
                SET_TITLE -> SetTitle(opId, item ?: return null, at, o.str("title")?.takeIf { it.isNotEmpty() })
                DELETE -> Delete(opId, item ?: return null, at)
                REFRESH -> Refresh(opId, item ?: return null, at)
                TAG_RENAME -> TagRename(opId, at, o.str("from") ?: return null, o.str("to") ?: return null)
                TAG_DELETE -> TagDelete(opId, at, o.str("tag") ?: return null)
                else -> null
            }
        }

        private fun JsonObject.str(key: String): String? =
            (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.content
    }
}

/** Wire value of a status (api.md §4.1). */
val ItemStatus.wire: String get() = if (this == ItemStatus.ARCHIVED) "archived" else "unread"

fun statusFromWire(value: String?): ItemStatus? = when (value) {
    "unread" -> ItemStatus.UNREAD
    "archived" -> ItemStatus.ARCHIVED
    else -> null
}

/** Common head of every op: `opId`, `type`, `itemId` (if any), `at`, then the op fields. */
private inline fun WireOp.op(fields: kotlinx.serialization.json.JsonObjectBuilder.() -> Unit): JsonObject = buildJsonObject {
    put("opId", opId)
    put("type", type)
    itemId?.let { put("itemId", it) }
    put("at", at)
    fields()
}
