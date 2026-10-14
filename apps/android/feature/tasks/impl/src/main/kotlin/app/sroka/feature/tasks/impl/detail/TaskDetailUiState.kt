package app.sroka.feature.tasks.impl.detail

import app.sroka.feature.tasks.impl.TaskUiError
import app.sroka.core.model.Task

/**
 * UI state for the task detail screen.
 */
sealed interface TaskDetailUiState {

    /**
     * Loading the task.
     */
    data object Loading : TaskDetailUiState

    /**
     * Task loaded successfully.
     *
     * @param task The task to display
     */
    data class Success(
        val task: Task,
    ) : TaskDetailUiState

    /**
     * Task not found.
     *
     * This can happen if the task was deleted or if an invalid ID was passed.
     */
    data object NotFound : TaskDetailUiState

    /**
     * Error loading task.
     *
     * @param message User-friendly error message
     */
    data class Error(
        val message: TaskUiError,
    ) : TaskDetailUiState
}
