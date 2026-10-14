package app.sroka.core.data.repository

import android.util.Log
import app.sroka.core.common.di.Dispatcher
import app.sroka.core.common.di.SrokaDispatchers
import app.sroka.core.data.mapper.toEntity
import app.sroka.core.data.mapper.toNetworkDto
import app.sroka.core.database.dao.TaskDao
import app.sroka.core.database.entity.toEntity
import app.sroka.core.database.entity.toModel
import app.sroka.core.model.Task
import app.sroka.core.model.TaskPriority
import app.sroka.core.network.TaskNetworkDataSource
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.withContext
import kotlin.time.Clock
import java.util.UUID
import javax.inject.Inject

/**
 * Room-backed local-first reads and writes. Remote writes are awaited and
 * best-effort; failures are logged and cancellation propagates. This demo has
 * no durable outbox. Only a confirmed demo import replaces the local snapshot.
 */
internal class DefaultTaskRepository @Inject constructor(
    private val taskDao: TaskDao,
    private val networkDataSource: TaskNetworkDataSource,
    @Dispatcher(SrokaDispatchers.IO) private val ioDispatcher: CoroutineDispatcher,
) : TaskRepository {

    /**
     * Observe all tasks from the local database.
     *
     * WHY flowOn(ioDispatcher):
     * - The database query runs on the IO dispatcher
     * - The downstream (UI) collection happens on the Main dispatcher
     * - This is automatic with Room but explicit here for clarity
     */
    override fun observeTasks(): Flow<List<Task>> = taskDao.observeAllTasks()
        .map { entities -> entities.map { it.toModel() } }
        .flowOn(ioDispatcher)

    /**
     * Observe a single task from the local database.
     */
    override fun observeTask(taskId: String): Flow<Task?> = taskDao.observeTask(taskId)
        .map { entity -> entity?.toModel() }
        .flowOn(ioDispatcher)

    /**
     * Create a new task.
     *
     * ## Process
     *
     * 1. Generate UUID for the new task
     * 2. Save to local database immediately
     * 3. Await the best-effort remote write
     *
     * The task is available locally even if network sync fails.
     */
    override suspend fun createTask(
        title: String,
        description: String,
        priority: TaskPriority,
    ): Task = withContext(ioDispatcher) {
        val task = Task(
            id = UUID.randomUUID().toString(),
            title = title,
            description = description,
            isCompleted = false,
            createdAt = Clock.System.now(),
            priority = priority,
        )

        // Save locally first (offline-first)
        taskDao.upsertTask(task.toEntity())

        // Then attempt network sync (best-effort)
        try {
            networkDataSource.createTask(task.toNetworkDto())
        } catch (e: Exception) {
            if (e is CancellationException) throw e
            // Log error but don't throw - task is saved locally
            // In production, queue for retry with WorkManager
            Log.w(TAG, "Task creation was saved locally but remote sync failed", e)
        }

        task
    }

    /**
     * Update an existing task.
     */
    override suspend fun updateTask(task: Task): Unit = withContext(ioDispatcher) {
        // Save locally first
        taskDao.upsertTask(task.toEntity())

        // Then attempt network sync
        try {
            networkDataSource.updateTask(task.toNetworkDto())
        } catch (e: Exception) {
            if (e is CancellationException) throw e
            Log.w(TAG, "Task update was saved locally but remote sync failed", e)
        }
    }

    /**
     * Update task completion status.
     *
     * More efficient than full update - only changes one field.
     */
    override suspend fun updateTaskCompletion(
        taskId: String,
        isCompleted: Boolean,
    ) = withContext(ioDispatcher) {
        val task = taskDao.getTask(taskId) ?: return@withContext

        // Update locally
        taskDao.updateTaskCompletion(taskId, isCompleted)

        // Sync to network
        try {
            val updatedTask = task.copy(isCompleted = isCompleted).toModel()
            networkDataSource.updateTask(updatedTask.toNetworkDto())
        } catch (e: Exception) {
            if (e is CancellationException) throw e
            Log.w(TAG, "Completion was saved locally but remote sync failed", e)
        }
    }

    /**
     * Delete a task.
     */
    override suspend fun deleteTask(taskId: String) = withContext(ioDispatcher) {
        // Delete locally
        taskDao.deleteTaskById(taskId)

        // Sync to network
        try {
            networkDataSource.deleteTask(taskId)
        } catch (e: Exception) {
            if (e is CancellationException) throw e
            Log.w(TAG, "Task was deleted locally but remote sync failed", e)
        }
        Unit
    }

    /**
     * Refresh tasks from the network.
     *
     * Fetches all tasks from the server and updates the local database.
     * This is a demo snapshot import - existing local data is replaced.
     */
    override suspend fun refreshTasks() = withContext(ioDispatcher) {
        val networkTasks = networkDataSource.getTasks()
        val entities = networkTasks.map { it.toEntity() }
        taskDao.replaceAllTasks(entities)
    }

    private companion object {
        const val TAG = "TaskRepository"
    }
}
