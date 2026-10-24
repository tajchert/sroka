package app.sroka.core.data.transfer

import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import app.sroka.core.model.ImportFormat
import app.sroka.core.model.ImportJob
import app.sroka.core.model.JobStatus
import app.sroka.core.network.JobDto
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import javax.inject.Inject
import javax.inject.Singleton

/**
 * The last started import job, persisted in the app's preferences DataStore (key `active_import`) so the
 * import screen survives process death. No Room table (RULINGS R11).
 */
@Singleton
class ImportJobStore @Inject internal constructor(
    private val store: DataStore<Preferences>,
) {
    private val json = Json { ignoreUnknownKeys = true }

    fun observe(): Flow<ImportJob?> = store.data.map { decode(it[KEY]) }.distinctUntilChanged()

    suspend fun current(): ImportJob? = observe().first()

    suspend fun set(job: ImportJob) {
        store.edit { it[KEY] = json.encodeToString(Stored.of(job)) }
    }

    /** Writes [job] only while it is still the active one (a newer import may have replaced it). */
    suspend fun update(job: ImportJob) {
        store.edit { prefs ->
            if (decode(prefs[KEY])?.id == job.id) prefs[KEY] = json.encodeToString(Stored.of(job))
        }
    }

    suspend fun clear() {
        store.edit { it.remove(KEY) }
    }

    private fun decode(raw: String?): ImportJob? =
        raw?.let { runCatching { json.decodeFromString<Stored>(it).toJob() }.getOrNull() }

    @Serializable
    private data class Stored(
        val id: String,
        val status: String,
        val format: String,
        val total: Int? = null,
        val done: Int = 0,
        val skipped: Int = 0,
        val error: String? = null,
        val createdAt: Long = 0,
        val updatedAt: Long = 0,
    ) {
        fun toJob(): ImportJob = ImportJob(
            id, JobStatus.valueOf(status), ImportFormat.valueOf(format), total, done, skipped, error, createdAt, updatedAt,
        )

        companion object {
            fun of(j: ImportJob) = Stored(
                j.id, j.status.name, j.format.name, j.total, j.done, j.skipped, j.error, j.createdAt, j.updatedAt,
            )
        }
    }

    private companion object {
        val KEY = stringPreferencesKey("active_import")
    }
}

internal fun JobDto.toImportJob(fallbackFormat: ImportFormat): ImportJob = ImportJob(
    id = id,
    status = JobStatus.fromWire(status),
    format = ImportFormat.fromWire(format) ?: fallbackFormat,
    total = total,
    done = done,
    skipped = skipped,
    error = error,
    createdAt = createdAt,
    updatedAt = updatedAt,
)
