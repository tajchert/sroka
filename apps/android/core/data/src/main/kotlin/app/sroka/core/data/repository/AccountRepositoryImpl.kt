package app.sroka.core.data.repository

import app.sroka.core.datastore.SessionStore
import app.sroka.core.domain.AccountRepository
import app.sroka.core.domain.DeleteAccountResult
import app.sroka.core.domain.RemoteFailure
import app.sroka.core.network.ApiResult
import app.sroka.core.network.SrokaApi
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
internal class AccountRepositoryImpl @Inject constructor(
    private val api: SrokaApi,
    private val sessionStore: SessionStore,
    private val auth: AuthRepositoryImpl,
) : AccountRepository {

    override suspend fun deleteAccount(): DeleteAccountResult = when (val r = api.deleteAccount()) {
        is ApiResult.Success -> {
            auth.clearLocal()
            DeleteAccountResult.Deleted
        }
        is ApiResult.NetworkError -> DeleteAccountResult.Failed(RemoteFailure.NETWORK)
        is ApiResult.HttpError -> DeleteAccountResult.Failed(
            when (r.status) {
                401 -> {
                    sessionStore.markExpired()
                    RemoteFailure.UNAUTHORIZED
                }
                429 -> RemoteFailure.RATE_LIMITED
                else -> RemoteFailure.SERVER
            },
        )
    }
}
