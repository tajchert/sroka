package app.sroka.feature.tasks.impl

import androidx.activity.ComponentActivity
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.junit4.accessibility.enableAccessibilityChecks
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.tryPerformAccessibilityChecks
import app.sroka.core.designsystem.theme.SrokaTheme
import app.sroka.core.testing.testTask
import app.sroka.feature.tasks.impl.list.TaskListContent
import app.sroka.feature.tasks.impl.list.TaskListUiState
import org.junit.Rule
import org.junit.Test

class TaskAccessibilityTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    @Test fun taskActions_haveSpecificLabels_andPassAccessibilityChecks() {
        compose.setContent {
            SrokaTheme(dynamicColor = false) {
                TaskListContent(TaskListUiState.Success(listOf(testTask(title = "Read guide"))),
                    {}, { _, _ -> }, {}, onCreateClick = {})
            }
        }
        compose.onNodeWithContentDescription("Completion of Read guide").assertIsDisplayed()
        compose.onNodeWithContentDescription("Delete task Read guide").assertIsDisplayed()
        compose.enableAccessibilityChecks()
        compose.onRoot().tryPerformAccessibilityChecks()
    }
}
