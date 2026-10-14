package app.sroka.core.datastore.di

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.core.handlers.ReplaceFileCorruptionHandler
import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.emptyPreferences
import androidx.datastore.preferences.preferencesDataStoreFile
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import app.sroka.core.datastore.KeystoreTokenCipher
import app.sroka.core.datastore.SessionDataStore
import app.sroka.core.datastore.TokenCipher
import javax.inject.Singleton

/**
 * Hilt module providing the user preferences DataStore
 * (`files/datastore/user_preferences.preferences_pb`). DataStore must be a singleton per file.
 * The encrypted session store (DECISIONS A6) uses a separate file and qualifier.
 */
@Module
@InstallIn(SingletonComponent::class)
internal object DataStoreModule {

    @Provides
    @Singleton
    fun providesUserPreferencesDataStore(
        @ApplicationContext context: Context,
    ): DataStore<Preferences> = PreferenceDataStoreFactory.create(
        corruptionHandler = ReplaceFileCorruptionHandler { emptyPreferences() },
        produceFile = { context.preferencesDataStoreFile("user_preferences") },
    )

    @Provides
    @Singleton
    @SessionDataStore
    fun providesSessionDataStore(
        @ApplicationContext context: Context,
    ): DataStore<Preferences> = PreferenceDataStoreFactory.create(
        // A corrupt session file just means signed out.
        corruptionHandler = ReplaceFileCorruptionHandler { emptyPreferences() },
        produceFile = { context.preferencesDataStoreFile("session") },
    )

    @Provides
    @Singleton
    fun providesTokenCipher(): TokenCipher = KeystoreTokenCipher()
}
