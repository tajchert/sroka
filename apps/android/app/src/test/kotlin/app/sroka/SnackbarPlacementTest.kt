package app.sroka

import androidx.compose.ui.unit.dp
import app.sroka.navigation.snackbarPlacement
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SnackbarPlacementTest {
    @Test
    fun phoneCentredAboveFab() {
        val p = snackbarPlacement(twoPane = false, railShown = false, hasFab = true)
        assertFalse(p.startAligned)
        assertNull(p.width)
        assertEquals(88.dp, p.bottomClearance)
    }

    @Test
    fun phoneWithoutFabHasNoClearance() {
        assertEquals(0.dp, snackbarPlacement(false, false, false).bottomClearance)
    }

    @Test
    fun twoPaneStartAlignedInListPane() {
        val p = snackbarPlacement(twoPane = true, railShown = true, hasFab = true)
        assertTrue(p.startAligned)
        assertEquals(360.dp, p.width)
        assertEquals(0.dp, p.bottomClearance)
    }
}
