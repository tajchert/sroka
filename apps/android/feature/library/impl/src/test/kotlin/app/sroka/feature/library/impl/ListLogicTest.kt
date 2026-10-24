package app.sroka.feature.library.impl

import androidx.compose.ui.graphics.Color
import app.sroka.core.model.OfflineState
import app.sroka.core.model.ParseStatus
import app.sroka.core.model.PendingChange
import app.sroka.core.model.SyncPhase
import app.sroka.core.model.SyncStatus
import app.sroka.core.model.toSummary
import app.sroka.core.testing.testItem
import app.sroka.feature.library.impl.list.RowStatus
import app.sroka.feature.library.impl.list.StatusCard
import app.sroka.feature.library.impl.list.archiveMessage
import app.sroka.feature.library.impl.list.avatarLetter
import app.sroka.feature.library.impl.list.rowStatus
import app.sroka.feature.library.impl.list.selectStatusCard
import app.sroka.feature.library.impl.search.highlightSnippet
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ListLogicTest {
    private fun summary(
        pending: PendingChange? = null,
        parse: ParseStatus = ParseStatus.OK,
        offline: OfflineState = OfflineState.NONE,
    ) = testItem(pendingChange = pending, parseStatus = parse, offline = offline).toSummary()

    @Test
    fun pendingChangeBeatsEverything() {
        val partialDownloaded = summary(PendingChange.TAGS, ParseStatus.PARTIAL, OfflineState.DOWNLOADED)
        assertEquals(RowStatus.TAGS_WAITING, rowStatus(partialDownloaded))
        assertEquals(RowStatus.SAVE_WAITING, rowStatus(summary(PendingChange.SAVE)))
        assertEquals(RowStatus.FAVORITE_WAITING, rowStatus(summary(PendingChange.FAVORITE)))
        assertEquals(RowStatus.CHANGE_WAITING, rowStatus(summary(PendingChange.OTHER)))
    }

    @Test
    fun partialBeatsDownloadStates() {
        assertEquals(RowStatus.PARTIAL, rowStatus(summary(parse = ParseStatus.PARTIAL, offline = OfflineState.DOWNLOADED)))
        assertEquals(RowStatus.DOWNLOADING, rowStatus(summary(offline = OfflineState.QUEUED)))
        assertEquals(RowStatus.DOWNLOADING, rowStatus(summary(offline = OfflineState.DOWNLOADING)))
        assertEquals(RowStatus.OFFLINE, rowStatus(summary(offline = OfflineState.DOWNLOADED)))
        assertNull(rowStatus(summary(offline = OfflineState.AVAILABLE_REMOTE)))
    }

    @Test
    fun cardPriorityIsResyncOfflineDownloading() {
        fun card(phase: SyncPhase, pending: Int = 0, signIn: Boolean = false) =
            selectStatusCard(SyncStatus(phase = phase, pendingOps = pending), signIn)
        assertEquals(StatusCard.Resync(0.5f), card(SyncPhase.Resyncing(0.5f)))
        assertEquals(StatusCard.Offline(3), card(SyncPhase.Offline, pending = 3))
        assertEquals(StatusCard.Downloading(3, 12), card(SyncPhase.Downloading(3, 12, null)))
        assertEquals(null, card(SyncPhase.Downloading(0, 0, null)))
        assertEquals(null, card(SyncPhase.Downloading(12, 12, null)))
        assertNull(card(SyncPhase.Idle))
        assertNull(card(SyncPhase.Syncing))
        assertEquals(StatusCard.SignIn, card(SyncPhase.Offline, signIn = true))
    }

    @Test
    fun archiveMessageHasOfflineVariant() {
        assertEquals(R.string.feature_library_snack_archived, archiveMessage(archived = true, offline = false))
        assertEquals(R.string.feature_library_snack_archived_offline, archiveMessage(archived = true, offline = true))
        assertEquals(R.string.feature_library_snack_unarchived, archiveMessage(archived = false, offline = false))
    }

    @Test
    fun avatarLetterIsFirstLetterOrQuestionMark() {
        assertEquals("M", avatarLetter("michal@example.com"))
        assertEquals("?", avatarLetter(""))
    }

    @Test
    fun highlightClampsRanges() {
        val text = highlightSnippet("hello world", listOf(0..4, 6..40, 50..60), Color.Red, Color.Black)
        assertEquals("hello world", text.text)
        assertEquals(listOf(0 to 5, 6 to 11), text.spanStyles.map { it.start to it.end })
    }
}
