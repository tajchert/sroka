package app.sroka.core.database.di

import android.content.Context
import androidx.room3.Room
import androidx.sqlite.driver.AndroidSQLiteDriver
import app.sroka.core.database.SrokaDatabase
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import javax.inject.Singleton

/** Provides `SrokaDatabase` (file `sroka.db`, DECISIONS A4) and its DAOs. Never add destructive migrations. */
@Module
@InstallIn(SingletonComponent::class)
internal object DatabaseModule {

    @Provides
    @Singleton
    fun providesDatabase(@ApplicationContext context: Context): SrokaDatabase =
        Room.databaseBuilder<SrokaDatabase>(context, SrokaDatabase.FILE_NAME)
            .setDriver(AndroidSQLiteDriver())
            .build()

    @Provides fun providesItemDao(db: SrokaDatabase) = db.itemDao()
    @Provides fun providesPendingOpDao(db: SrokaDatabase) = db.pendingOpDao()
    @Provides fun providesSyncStateDao(db: SrokaDatabase) = db.syncStateDao()
    @Provides fun providesContentFileDao(db: SrokaDatabase) = db.contentFileDao()
    @Provides fun providesMaintenanceDao(db: SrokaDatabase) = db.maintenanceDao()
}
