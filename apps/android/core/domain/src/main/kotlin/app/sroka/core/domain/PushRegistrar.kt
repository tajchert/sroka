package app.sroka.core.domain

/**
 * Silent "sync" push registration (repo-root D17). The `play` flavor implements it with FCM, the
 * `foss` flavor binds [None]: no push there, the hourly periodic sync is the only background trigger.
 *
 * Both calls are best effort and never throw (except for coroutine cancellation).
 */
interface PushRegistrar {

    /** Registers this device's push token with the server when signed in; cheap when already current (throttled). */
    suspend fun register()

    /** Removes this device's token from the server (needs the session, so call before sign-out) and drops it locally. */
    suspend fun unregister()

    companion object {
        /** Does nothing; the foss flavor binds it and tests use it as a default. */
        val None: PushRegistrar = object : PushRegistrar {
            override suspend fun register() = Unit
            override suspend fun unregister() = Unit
        }
    }
}
