package app.sroka.core.ui

import androidx.compose.runtime.Composable
import androidx.compose.ui.res.stringResource
import app.sroka.core.model.TaskPriority

@Composable
fun TaskPriority.localizedLabel(): String = stringResource(when (this) {
    TaskPriority.HIGH -> R.string.priority_high
    TaskPriority.MEDIUM -> R.string.priority_medium
    TaskPriority.LOW -> R.string.priority_low
})
