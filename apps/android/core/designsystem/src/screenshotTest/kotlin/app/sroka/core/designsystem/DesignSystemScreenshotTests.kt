package app.sroka.core.designsystem

import android.content.res.Configuration
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Inbox
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import com.android.tools.screenshot.PreviewTest
import app.sroka.core.designsystem.component.SrokaButton
import app.sroka.core.designsystem.component.SrokaCard
import app.sroka.core.designsystem.component.SrokaElevatedCard
import app.sroka.core.designsystem.component.SrokaEmptyState
import app.sroka.core.designsystem.component.SrokaErrorState
import app.sroka.core.designsystem.component.SrokaLoadingIndicator
import app.sroka.core.designsystem.component.SrokaOutlinedButton
import app.sroka.core.designsystem.component.SrokaSmallLoadingIndicator
import app.sroka.core.designsystem.component.SrokaTextButton
import app.sroka.core.designsystem.component.SrokaTopAppBar
import app.sroka.core.designsystem.theme.SrokaTheme

@Preview(name = "Light", showBackground = true, widthDp = 360)
@Preview(
    name = "Dark",
    showBackground = true,
    widthDp = 360,
    uiMode = Configuration.UI_MODE_NIGHT_YES,
)
private annotation class ComponentThemes

@PreviewTest
@ComponentThemes
@Composable
fun ButtonsScreenshotTest() {
    SrokaTheme {
        Column(
            modifier = Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            SrokaButton(onClick = {}, text = "Primary")
            SrokaButton(onClick = {}, text = "Loading", isLoading = true)
            SrokaButton(onClick = {}, text = "Disabled", enabled = false)
            SrokaOutlinedButton(onClick = {}, text = "Outlined")
            SrokaTextButton(onClick = {}, text = "Text")
        }
    }
}

@PreviewTest
@ComponentThemes
@Composable
fun CardsScreenshotTest() {
    SrokaTheme {
        Column(
            modifier = Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            SrokaCard(onClick = {}) {
                Text("Standard card", style = MaterialTheme.typography.titleMedium)
                Text("Supporting content")
            }
            SrokaElevatedCard {
                Text("Elevated card", style = MaterialTheme.typography.titleMedium)
                Text("Prominent supporting content")
            }
        }
    }
}

@PreviewTest
@ComponentThemes
@Composable
fun LoadingIndicatorsScreenshotTest() {
    SrokaTheme {
        Row(
            modifier = Modifier.padding(16.dp),
            horizontalArrangement = Arrangement.spacedBy(24.dp),
        ) {
            SrokaLoadingIndicator(modifier = Modifier.size(80.dp))
            SrokaSmallLoadingIndicator()
        }
    }
}

@PreviewTest
@Preview(name = "Empty and error", showBackground = true, widthDp = 360, heightDp = 640)
@Composable
fun EmptyAndErrorStatesScreenshotTest() {
    SrokaTheme {
        Column {
            SrokaEmptyState(
                icon = Icons.Outlined.Inbox,
                title = "Nothing here",
                description = "Create the first item to get started.",
                actionLabel = "Create item",
                onAction = {},
                modifier = Modifier.weight(1f),
            )
            SrokaErrorState(
                message = "The content could not be loaded.",
                onRetry = {},
                modifier = Modifier.weight(1f),
            )
        }
    }
}

@PreviewTest
@ComponentThemes
@Composable
fun TopAppBarsScreenshotTest() {
    SrokaTheme {
        Column {
            SrokaTopAppBar(title = "Overview")
            SrokaTopAppBar(title = "Details", onNavigationClick = {})
        }
    }
}
