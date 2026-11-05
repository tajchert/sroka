package app.sroka.core.data.repository

import app.sroka.core.datastore.ConsentStore
import app.sroka.core.domain.ConsentRepository
import app.sroka.core.model.Consent
import kotlinx.coroutines.flow.Flow
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
internal class ConsentRepositoryImpl @Inject constructor(
    private val store: ConsentStore,
) : ConsentRepository {

    override val consent: Flow<Consent> = store.consent

    override suspend fun setAnalytics(enabled: Boolean) {
        store.setAnalytics(enabled)
    }

    override suspend fun setCrashReports(enabled: Boolean) {
        store.setCrashReports(enabled)
    }
}
