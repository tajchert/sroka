package app.sroka.core.ui.posture

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PostureTest {
    @Test
    fun halfOpenedHorizontalIsTabletop() {
        assertEquals(ReaderLayout.Tabletop(1000, 1040), readerLayoutFor(true, true, 1000, 1040, 2000))
    }

    @Test
    fun flatFoldedVerticalOrBadBoundsAreNormal() {
        assertEquals(ReaderLayout.Normal, readerLayoutFor(false, true, 1000, 1040, 2000))
        assertEquals(ReaderLayout.Normal, readerLayoutFor(true, false, 1000, 1040, 2000))
        assertEquals(ReaderLayout.Normal, readerLayoutFor(true, true, 0, 0, 2000))
        assertEquals(ReaderLayout.Normal, readerLayoutFor(true, true, 1040, 1000, 2000))
        assertEquals(ReaderLayout.Normal, readerLayoutFor(true, true, 1000, 2000, 2000))
    }

    @Test
    fun tabletopWithReaderOnTopHidesNavigationAndForcesSinglePane() {
        assertEquals(ShellLayout(true, true), shellLayoutFor(ReaderLayout.Tabletop(1000, 1040), readerOnTop = true))
    }

    @Test
    fun otherwiseShellIsUntouched() {
        val none = ShellLayout(hideNavigation = false, forceSinglePane = false)
        assertEquals(none, shellLayoutFor(ReaderLayout.Tabletop(1000, 1040), readerOnTop = false))
        assertEquals(none, shellLayoutFor(ReaderLayout.Normal, readerOnTop = true))
        assertEquals(none, shellLayoutFor(ReaderLayout.Normal, readerOnTop = false))
    }

    @Test
    fun hingeIsShiftedByTheContainerOffset() {
        assertEquals(LocalSplit(520, 560), localSplit(600, 640, containerTopPx = 80, containerHeightPx = 1000))
    }

    @Test
    fun fullWindowContainerKeepsWindowCoordinates() {
        assertEquals(LocalSplit(600, 640), localSplit(600, 640, 0, 1400))
    }

    @Test
    fun hingeOutsideTheContainerGivesNoSplit() {
        assertNull(localSplit(600, 640, containerTopPx = 700, containerHeightPx = 500))
        assertNull(localSplit(600, 640, containerTopPx = 0, containerHeightPx = 500))
        assertNull(localSplit(600, 640, containerTopPx = 0, containerHeightPx = 0))
    }

    @Test
    fun bottomIsClampedToTheContainer() {
        assertEquals(LocalSplit(100, 200), localSplit(100, 300, 0, 200))
    }
}
