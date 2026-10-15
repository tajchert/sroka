package app.sroka.core.data.repository

import app.sroka.core.data.ops.OpWriter
import app.sroka.core.data.ops.WireOp
import app.sroka.core.database.dao.ItemDao
import app.sroka.core.domain.SyncController
import app.sroka.core.domain.TagEditResult
import app.sroka.core.domain.TagRepository
import app.sroka.core.model.MAX_TAG_LENGTH
import app.sroka.core.model.TagCount
import app.sroka.core.model.normalizeTagName
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
internal class TagRepositoryImpl @Inject constructor(
    private val itemDao: ItemDao,
    private val writer: OpWriter,
    private val syncController: SyncController,
) : TagRepository {

    override fun observeTags(): Flow<List<TagCount>> =
        itemDao.observeTagCounts()
            .map { rows -> rows.map { TagCount(it.name, it.count) } }
            .distinctUntilChanged()

    override fun observeRecentTags(limit: Int): Flow<List<String>> =
        itemDao.observeRecentTags(limit).distinctUntilChanged()

    override suspend fun rename(from: String, to: String): TagEditResult {
        val target = normalizeTagName(to)
        if (target.isEmpty() || target.length > MAX_TAG_LENGTH) return TagEditResult.InvalidName
        val source = normalizeTagName(from)
        if (source.isEmpty() || source == target) return TagEditResult.Done
        if (writer.write { now -> listOf(WireOp.TagRename(writer.newOpId(now), now, source, target)) }) {
            syncController.requestSync()
        }
        return TagEditResult.Done
    }

    override suspend fun delete(name: String) {
        val tag = normalizeTagName(name)
        if (tag.isEmpty()) return
        if (writer.write { now -> listOf(WireOp.TagDelete(writer.newOpId(now), now, tag)) }) {
            syncController.requestSync()
        }
    }
}
