package app.sroka.core.data

import app.sroka.core.data.repository.normalizeServerUrl
import app.sroka.core.data.repository.normalizeTags
import app.sroka.core.data.sync.SyncStatusRepositoryImpl
import app.sroka.core.database.entity.SyncStateEntity
import app.sroka.core.model.SyncErrorKind
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
}
