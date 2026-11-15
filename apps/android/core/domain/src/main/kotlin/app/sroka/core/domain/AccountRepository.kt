package app.sroka.core.domain

/** Account-level server operations (api.md §12). */
interface AccountRepository {

    /** Deletes the account on the server, then signs out and wipes local data. */
    suspend fun deleteAccount(): DeleteAccountResult

    /**
     * Which client types this account has used (`GET /v1/me` `clients`); a server without `clients`
     * reports none. Null when the request failed (offline, signed out, server error): callers stay silent.
     */
    suspend fun connectedClients(): ConnectedClients?
}

/** Client types that have signed in for this account. */
data class ConnectedClients(val extension: Boolean = false, val android: Boolean = false)

sealed interface DeleteAccountResult {
    data object Deleted : DeleteAccountResult

    data class Failed(val reason: RemoteFailure) : DeleteAccountResult
}
