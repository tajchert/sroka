package app.sroka.feature.reader.impl.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import app.sroka.core.designsystem.theme.SrokaTheme
import com.android.tools.screenshot.PreviewTest

@PreviewTest
@Preview(name = "Tabletop", showBackground = true, widthDp = 841, heightDp = 673, apiLevel = 36)
@Composable
fun TabletopReaderLight() {
    SrokaTheme(darkTheme = false) {
        Box(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background)) {
            Box(Modifier.tabletopArticle(statusBar = 24.dp, hingeTop = 336.dp)) {
                Text("The long road to a quieter web. A stub article area above the hinge.", color = MaterialTheme.colorScheme.onBackground)
            }
            TabletopChrome(
                statusBar = 24.dp,
                hingeBottom = 336.dp,
                titleLine = "example.com · The long road to a quieter web",
                progress = 0.42f,
            ) {
                TabletopControls(
                    progress = 0.42f,
                    minutesLeft = 6,
                    textSizePx = 17,
                    isFavorite = true,
                    isArchived = false,
                    upNext = UpNextCard("Why every app needs an offline mode"),
                    onScrub = {},
                    onTextSmaller = {},
                    onTextLarger = {},
                    onFavorite = {},
                    onArchive = {},
                    onTags = {},
                    onReadNext = {},
                )
            }
        }
    }
}
