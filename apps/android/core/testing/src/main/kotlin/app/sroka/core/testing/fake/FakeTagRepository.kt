package app.sroka.core.testing.fake

import app.sroka.core.domain.TagEditResult
import app.sroka.core.domain.TagRepository
import app.sroka.core.model.MAX_TAG_LENGTH
import app.sroka.core.model.TagCount
import app.sroka.core.model.normalizeTagName
import app.sroka.core.model.tagKey
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.update

/** In-memory [TagRepository]; seed [tags] and [recentTags] directly. */
class FakeTagRepository(initial: List<TagCount> = emptyList()) : TagRepository {

    val tags = MutableStateFlow(initial)
    val recentTags = MutableStateFlow<List<String>>(emptyList())

    override fun observeTags(): Flow<List<TagCount>> = tags.map { list -> list.sortedBy { tagKey(it.name) } }

    override fun observeRecentTags(limit: Int): Flow<List<String>> = recentTags.map { it.take(limit) }

    override suspend fun rename(from: String, to: String): TagEditResult {
        val name = normalizeTagName(to)
        if (name.isEmpty() || name.length > MAX_TAG_LENGTH) return TagEditResult.InvalidName
        tags.update { list ->
            val moved = list.firstOrNull { tagKey(it.name) == tagKey(from) } ?: return@update list
            val target = list.firstOrNull { tagKey(it.name) == tagKey(name) && it !== moved }
            val rest = list.filterNot { it === moved || it === target }
            rest + TagCount(target?.name ?: name, moved.count + (target?.count ?: 0))
        }
        return TagEditResult.Done
    }

    override suspend fun delete(name: String) = tags.update { list -> list.filterNot { tagKey(it.name) == tagKey(name) } }
}
