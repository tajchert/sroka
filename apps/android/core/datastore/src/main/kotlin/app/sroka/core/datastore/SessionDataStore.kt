package app.sroka.core.datastore

import javax.inject.Qualifier

/** Qualifier for the encrypted-session DataStore (`datastore/session.preferences_pb`). */
@Qualifier
@Retention(AnnotationRetention.BINARY)
annotation class SessionDataStore
