package app.sroka.core.data

import app.sroka.core.data.repository.normalizeServerUrl
import app.sroka.core.data.repository.normalizeTags
import app.sroka.core.data.sync.SyncStatusRepositoryImpl
import app.sroka.core.database.entity.SyncStateEntity
import app.sroka.core.model.SyncErrorKind
import app.sroka.core.data.repository.matchedColumns
import app.sroka.core.data.repository.parseSnippet
import app.sroka.core.model.SyncPhase
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class SmallUnitsTest {
    @Test fun serverUrlValidation() {
        assertEquals("https://api.example.com", normalizeServerUrl(" https://api.example.com/ "))
        assertEquals("http://10.0.2.2:8787", normalizeServerUrl("http://10.0.2.2:8787"))
        assertNull(normalizeServerUrl("ftp://x"))
        assertNull(normalizeServerUrl("https://x?y=1"))
        assertNull(normalizeServerUrl("nope"))
    }

    @Test fun tagNormalization() {
        assertEquals(listOf("A b", "c"), normalizeTags(listOf(" A  b ", "a B", "", "c", "x".repeat(65))))
    }

    @Test fun phasePriority() {
        val idle = SyncStatusRepositoryImpl.WorkSnapshot(syncing = false, downloading = null)
        val dl = SyncPhase.Downloading(1, 3, "t")
        val state = SyncStateEntity()
        val phase = SyncStatusRepositoryImpl.Companion::phaseOf
        assertEquals(SyncPhase.Error(SyncErrorKind.AUTH), phase(idle.copy(syncing = true), state, true, true))
        assertEquals(SyncPhase.Syncing, phase(idle.copy(syncing = true, downloading = dl), state, true, false))
        assertEquals(dl, phase(idle.copy(downloading = dl), state, false, false))
        assertEquals(SyncPhase.Offline, phase(idle, state.copy(lastError = "SERVER"), false, false))
        assertEquals(SyncPhase.Error(SyncErrorKind.SERVER), phase(idle, state.copy(lastError = "SERVER"), true, false))
        assertEquals(SyncPhase.Idle, phase(idle, state.copy(lastError = "NETWORK"), true, false))
        assertEquals(SyncPhase.Idle, phase(idle, state, true, false))
    }

    @Test fun resyncingWhileFullPassRuns() {
        val idle = SyncStatusRepositoryImpl.WorkSnapshot(syncing = false, downloading = null)
        val full = SyncStateEntity(fullResync = true)
        val phase = SyncStatusRepositoryImpl.Companion::phaseOf
        assertEquals(SyncPhase.Resyncing(null), phase(idle.copy(syncing = true), full, true, false))
        assertEquals(SyncPhase.Idle, phase(idle, full, true, false)) // flag alone, no running sync
        assertEquals(SyncPhase.Error(SyncErrorKind.AUTH), phase(idle.copy(syncing = true), full, true, true))
    }
}

class SearchMappingTest {
    @Test fun parseSnippetStripsMarkersIntoRanges() {
        val (text, ranges) = parseSnippet("…a \uE000zebra\uE001 and \uE000stripes\uE001 end")!!
        assertEquals("…a zebra and stripes end", text)
        assertEquals(listOf(3..7, 13..19), ranges)
        assertEquals("zebra", text.substring(ranges[0].first, ranges[0].last + 1))
        assertEquals("stripes", text.substring(ranges[1].first, ranges[1].last + 1))
    }

    @Test fun parseSnippetHandlesNullAndNoMarkers() {
        assertNull(parseSnippet(null))
        assertNull(parseSnippet(" "))
        assertEquals("plain" to emptyList<IntRange>(), parseSnippet("plain"))
    }

    @Test fun matchedColumnsReadsOffsets() {
        assertEquals(setOf(0, 4), matchedColumns("0 0 0 5 4 0 12 5 4 1 30 3"))
        assertEquals(emptySet<Int>(), matchedColumns(null))
    }
}
