package app.sroka.core.data.telemetry

import app.sroka.core.testing.fake.FakeConsentRepository
import app.sroka.core.testing.fake.FakeTelemetry
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Test

class ConsentApplierTest {

    private val scope = TestScope(UnconfinedTestDispatcher())
    private val consent = FakeConsentRepository()
    private val telemetry = FakeTelemetry()

    private fun start() = ConsentApplier(consent, telemetry, scope.backgroundScope).start()

    @Test
    fun notAskedMeansAnalyticsOffAndCrashReportsOn() = scope.runTest {
        start()
        assertEquals(false, telemetry.analyticsEnabled)
        assertEquals(true, telemetry.crashReportingEnabled)
    }

    @Test
    fun appliesChangesAsTheyHappen() = scope.runTest {
        start()
        consent.setAnalytics(true)
        assertEquals(true, telemetry.analyticsEnabled)
        consent.setCrashReports(false)
        assertEquals(false, telemetry.crashReportingEnabled)
        consent.setAnalytics(false)
        assertEquals(false, telemetry.analyticsEnabled)
    }
}
