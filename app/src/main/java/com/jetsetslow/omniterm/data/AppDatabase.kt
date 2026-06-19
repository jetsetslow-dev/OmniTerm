package com.jetsetslow.omniterm.data

import android.content.Context
import androidx.room.Database
import androidx.room.Room
import androidx.room.RoomDatabase
import androidx.room.migration.Migration
import androidx.sqlite.db.SupportSQLiteDatabase

@Database(
    entities = [
        ServerEntity::class,
        MetricHistoryEntity::class,
        SshKeyEntity::class,
        CredentialProfileEntity::class,
        AlertRuleEntity::class,
        ActiveAlertEntity::class,
        AlertHistoryEntity::class,
        QuickScriptEntity::class,
        WolTargetEntity::class,
        AppSettingEntity::class,
        PersistentSessionEntity::class
    ],
    // NOTE: bump this whenever any @Entity schema changes, and add a real Migration for the bump.
    // Schemas are exported to app/schemas/ (committed) so migrations can be written and tested
    // against the exact prior shape. Versions ≤7 predate schema export (several v5 builds shipped
    // with differing schemas), so upgrades from those still fall back to a destructive wipe — but
    // from v8 on, a version bump without a Migration must fail loudly instead of deleting data.
    version = 12,
    exportSchema = true
)
abstract class AppDatabase : RoomDatabase() {
    abstract fun serverDao(): ServerDao
    abstract fun metricHistoryDao(): MetricHistoryDao
    abstract fun sshKeyDao(): SshKeyDao
    abstract fun credentialProfileDao(): CredentialProfileDao
    abstract fun alertRuleDao(): AlertRuleDao
    abstract fun activeAlertDao(): ActiveAlertDao
    abstract fun alertHistoryDao(): AlertHistoryDao
    abstract fun quickScriptDao(): QuickScriptDao
    abstract fun wolTargetDao(): WolTargetDao
    abstract fun appSettingDao(): AppSettingDao
    abstract fun persistentSessionDao(): PersistentSessionDao

    companion object {
        @Volatile
        private var INSTANCE: AppDatabase? = null

        private val MIGRATION_8_9 = object : Migration(8, 9) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE servers ADD COLUMN proxyKeyAlias TEXT")
            }
        }

        // The backup-jobs feature was removed before it ever shipped a UI; drop its table.
        private val MIGRATION_9_10 = object : Migration(9, 10) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("DROP TABLE IF EXISTS backup_jobs")
            }
        }

        // Persistent (tmux-backed) sessions: per-server opt-in flag.
        private val MIGRATION_10_11 = object : Migration(10, 11) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE servers ADD COLUMN persistentSession INTEGER NOT NULL DEFAULT 0")
            }
        }

        // Track live tmux sessions so they can be re-offered after an app restart.
        private val MIGRATION_11_12 = object : Migration(11, 12) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL(
                    "CREATE TABLE IF NOT EXISTS persistent_sessions (" +
                        "tmuxName TEXT NOT NULL PRIMARY KEY, " +
                        "serverId INTEGER NOT NULL, " +
                        "serverName TEXT NOT NULL, " +
                        "createdAt INTEGER NOT NULL)"
                )
            }
        }

        fun getDatabase(context: Context): AppDatabase {
            return INSTANCE ?: synchronized(this) {
                val instance = Room.databaseBuilder(
                    context.applicationContext,
                    AppDatabase::class.java,
                    "omniterm_database"
                )
                // Destructive only for the un-exported legacy versions; never for v8+.
                .fallbackToDestructiveMigrationFrom(dropAllTables = true, 1, 2, 3, 4, 5, 6, 7)
                .addMigrations(MIGRATION_8_9, MIGRATION_9_10, MIGRATION_10_11, MIGRATION_11_12)
                .build()
                INSTANCE = instance
                instance
            }
        }
    }
}
