package app.sroka.core.designsystem.component

import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.systemBars
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/** Corner radius of the detail card (R13). */
val DetailPaneCardCorner: Dp = 24.dp

/**
 * The rounded `surfaceContainerLow` card that holds the detail pane (reader or empty placeholder)
 * next to the list on wide windows (R13, screen 17): 24dp margin at the top, end and bottom, 24dp
 * corners. The start side is the pane gutter. System-bar insets are added on top of the margin.
 */
@Composable
fun DetailPaneCard(
    modifier: Modifier = Modifier,
    content: @Composable BoxScope.() -> Unit,
) {
    Surface(
        modifier = modifier
            .fillMaxSize()
            .windowInsetsPadding(
                WindowInsets.systemBars.only(WindowInsetsSides.Top + WindowInsetsSides.Bottom + WindowInsetsSides.End),
            )
            .padding(top = 24.dp, end = 24.dp, bottom = 24.dp),
        shape = RoundedCornerShape(DetailPaneCardCorner),
        color = MaterialTheme.colorScheme.surfaceContainerLow,
    ) {
        Box(Modifier.fillMaxSize(), content = content)
    }
}
