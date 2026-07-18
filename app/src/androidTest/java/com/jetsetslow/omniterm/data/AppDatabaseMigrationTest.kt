package com.jetsetslow.omniterm.data

import androidx.room.testing.MigrationTestHelper
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AppDatabaseMigrationTest {
    @get:Rule
    val helper = MigrationTestHelper(
        InstrumentationRegistry.getInstrumentation(),
        AppDatabase::class.java,
    )

    @Test
    fun everyExportedSchemaFromVersionEightMigratesToCurrent() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        for (startVersion in 8 until 19) {
            val databaseName = "migration-$startVersion-to-19"
            context.deleteDatabase(databaseName)
            helper.createDatabase(databaseName, startVersion).close()
            helper.runMigrationsAndValidate(
                databaseName,
                19,
                true,
                *AppDatabase.ALL_MIGRATIONS,
            ).close()
            context.deleteDatabase(databaseName)
        }
    }

    @Test
    fun migrationToNineteenDeduplicatesLiveIncidentsBeforeAddingUniqueIdentity() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val databaseName = "migration-18-alert-dedup"
        context.deleteDatabase(databaseName)
        helper.createDatabase(databaseName, 18).use { db ->
            val values = "1, 7, 'CPU Usage', 99.0, 80.0, 'CRITICAL', 1000, 0, 0"
            db.execSQL(
                "INSERT INTO active_alerts " +
                    "(id, ruleId, serverId, metricName, currentValue, thresholdValue, severity, triggeredTime, acknowledged, mutedUntil) " +
                    "VALUES (10, $values)"
            )
            db.execSQL(
                "INSERT INTO active_alerts " +
                    "(id, ruleId, serverId, metricName, currentValue, thresholdValue, severity, triggeredTime, acknowledged, mutedUntil) " +
                    "VALUES (11, $values)"
            )
        }

        helper.runMigrationsAndValidate(
            databaseName,
            19,
            true,
            *AppDatabase.ALL_MIGRATIONS,
        ).use { db ->
            db.query("SELECT COUNT(*), MAX(id) FROM active_alerts WHERE ruleId = 1 AND serverId = 7").use { cursor ->
                cursor.moveToFirst()
                assertEquals(1, cursor.getInt(0))
                assertEquals(11, cursor.getInt(1))
            }
        }
        context.deleteDatabase(databaseName)
    }
}
