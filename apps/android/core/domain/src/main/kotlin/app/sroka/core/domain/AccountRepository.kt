package app.sroka.core.domain

/** Account-level server operations (api.md §12). */
interface AccountRepository {

    /** Deletes the account on the server, then signs out and wipes local data. */
    suspend fun deleteAccount(): DeleteAccountResult
}

sealed interface DeleteAccountResult {
    data object Deleted : DeleteAccountResult

    data class Failed(val reason: RemoteFailure) : DeleteAccountResult
}
