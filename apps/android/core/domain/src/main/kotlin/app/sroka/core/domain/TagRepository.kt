package app.sroka.core.domain

import app.sroka.core.model.TagCount
import kotlinx.coroutines.flow.Flow

/** Tags across the library (local-first like [LibraryRepository]). */
interface TagRepository {

    /** All tags with live-item counts, sorted case-insensitively by name. */
    fun observeTags(): Flow<List<TagCount>>

    /** Most recently used tag names (newest first), for tag-entry suggestions. */
    fun observeRecentTags(limit: Int = 10): Flow<List<String>>

    /** Renames [from] to [to] everywhere; merges into an existing tag with the same key. */
    suspend fun rename(from: String, to: String): TagEditResult

    /** Removes the tag from every item. */
    suspend fun delete(name: String)
}

sealed interface TagEditResult {
    data object Done : TagEditResult

    /** Empty after normalization or longer than 64 characters. */
    data object InvalidName : TagEditResult
}
