package app.sroka.core.testing.fake

import app.sroka.core.domain.AccountRepository
import app.sroka.core.domain.ConnectedClients
import app.sroka.core.domain.DeleteAccountResult

/** Scripted [AccountRepository]; on success also signs out [auth] when given. */
class FakeAccountRepository(private val auth: FakeAuthRepository? = null) : AccountRepository {

    var result: DeleteAccountResult = DeleteAccountResult.Deleted
    var deleteCount = 0
        private set

    /** What [connectedClients] returns (null = request failed). */
    var clients: ConnectedClients? = ConnectedClients()
    var clientsCalls = 0
        private set

    override suspend fun connectedClients(): ConnectedClients? {
        clientsCalls++
        return clients
    }

    override suspend fun deleteAccount(): DeleteAccountResult {
        deleteCount++
        if (result == DeleteAccountResult.Deleted) auth?.signOut()
        return result
    }
}
