package app.sroka.core.testing.fake

import app.sroka.core.domain.AuthRepository
import app.sroka.core.domain.AuthResult
import app.sroka.core.model.SessionState
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow

/** Scripted [AuthRepository]: set [sendCodeResult]/[signInResult]; [sessionFlow] reflects sign-in/out. */
class FakeAuthRepository(initial: SessionState = SessionState.SignedOut) : AuthRepository {

    val sessionFlow = MutableStateFlow(initial)
    var sendCodeResult: AuthResult = AuthResult.Success
    var signInResult: AuthResult = AuthResult.Success
    val sentCodesTo = mutableListOf<String>()
    var signOutCount = 0
        private set

    override val session: Flow<SessionState> = sessionFlow

    override suspend fun sendCode(email: String): AuthResult {
        sentCodesTo += email
        return sendCodeResult
    }

    override suspend fun signIn(email: String, code: String): AuthResult {
        val result = signInResult
        if (result == AuthResult.Success) sessionFlow.value = SessionState.SignedIn(email)
        return result
    }

    override suspend fun signOut() {
        signOutCount++
        sessionFlow.value = SessionState.SignedOut
    }
}
