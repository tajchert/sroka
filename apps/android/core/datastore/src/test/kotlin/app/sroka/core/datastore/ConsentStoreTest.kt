package app.sroka.core.datastore

import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import app.sroka.core.model.Consent
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class ConsentStoreTest {

    @get:Rule
    val tmp = TemporaryFolder()

    private val scope = TestScope(UnconfinedTestDispatcher())
    private val store = ConsentStore(
        PreferenceDataStoreFactory.create(scope = scope.backgroundScope) { tmp.newFile("consent.preferences_pb") },
    )

    @Test
    fun defaultsAreNotAskedAndCrashReportsOn() = scope.runTest {
        val consent = store.consent.first()
        assertEquals(Consent(analytics = null, crashReports = true), consent)
        assertFalse(consent.analyticsEnabled)
    }

    @Test
    fun analyticsDecisionIsPersisted() = scope.runTest {
        store.setAnalytics(true)
        assertEquals(true, store.consent.first().analytics)
        store.setAnalytics(false)
        assertEquals(false, store.consent.first().analytics)
    }

    @Test
    fun crashReportsCanBeOptedOut() = scope.runTest {
        store.setCrashReports(false)
        val consent = store.consent.first()
        assertFalse(consent.crashReports)
        assertEquals(null, consent.analytics)
    }
}
