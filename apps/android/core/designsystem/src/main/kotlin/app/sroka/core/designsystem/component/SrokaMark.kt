package app.sroka.core.designsystem.component

import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import app.sroka.core.designsystem.R

/** The Sroka magpie mark on a white circle tile (decorative). */
@Composable
fun SrokaMark(modifier: Modifier = Modifier, size: Dp = 64.dp) {
    Image(
        painter = painterResource(R.drawable.ic_sroka_mark),
        contentDescription = null,
        modifier = modifier.size(size).clip(CircleShape),
    )
}
