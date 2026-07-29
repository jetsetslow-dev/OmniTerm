package com.jetsetslow.omniterm.data

import androidx.room.testing.MigrationTestHelper
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AppDatabaseMigrationTest {
    private companion object {
        /** Keep in step with AppDatabase's @Database(version = …). */
        const val CURRENT_VERSION = 20
    }

    @get:Rule
    val helper = MigrationTestHelper(
        InstrumentationRegistry.getInstrumentation(),
        AppDatabase::class.java,
    )

    @Test
    fun everyExportedSchemaFromVersionEightMigratesToCurrent() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        for (startVersion in 8 until CURRENT_VERSION) {
            val databaseName = "migration-$startVersion-to-$CURRENT_VERSION"
            context.deleteDatabase(databaseName)
            helper.createDatabase(databaseName, startVersion).close()
            helper.runMigrationsAndValidate(
                databaseName,
                CURRENT_VERSION,
                true,
                *AppDatabase.ALL_MIGRATIONS,
            ).close()
            context.deleteDatabase(databaseName)
        }
    }

    /**
     * Presets seeded before the presetKey column existed must be back-stamped, otherwise the
     * "default presets" toggles could no longer recognise (and therefore reset or remove) them.
     * User-created rows must keep a null key so the toggles never delete them.
     */
    @Test
    fun migrationToTwentyBackStampsSeededPresetsAndLeavesUserRowsAlone() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val databaseName = "migration-19-preset-keys"
        context.deleteDatabase(databaseName)
        helper.createDatabase(databaseName, 19).use { db ->
            // Fleet presets had an implicit-on legacy default. Homelab is explicitly disabled:
            // even an exact homelab identity must remain a user-owned row.
            db.execSQL(
                "INSERT INTO quick_scripts " +
                    "(id, emoji, name, command, color, longRunning, category, sortOrder, " +
                    "availableForQuick, availableForFleet, targetOs, targetSystem, notes) VALUES " +
                    "(1, 'DSK', 'Disk', 'df -h', 'cyan', 0, 'Fleet', 1, 0, 1, 'Any', 'Any', ''), " +
                    "(2, 'CPU', 'CPU/RAM', 'my edited command', 'cyan', 0, 'Fleet', 0, 0, 1, 'Any', 'Any', ''), " +
                    "(3, 'OWN', 'My script', 'echo hi', 'green', 0, 'General', 0, 1, 0, 'Any', 'Any', ''), " +
                    "(4, 'TMP', 'Temperature', 'my own sensor script', 'green', 0, 'General', 0, 1, 0, 'Any', 'Any', ''), " +
                    "(5, 'TMP', 'Temperature', 'legacy preset command', 'red', 0, 'Linux', 0, 1, 0, 'Any', 'Any', '')"
            )
            db.execSQL(
                "INSERT INTO app_settings (`key`, value) VALUES " +
                    "('homelab_presets', 'false'), ('alert_presets', 'true')"
            )
            db.execSQL(
                "INSERT INTO alert_rules " +
                    "(id, serverId, metricName, mountPoint, thresholdValue, severity, triggerWindow, enabled, notes) VALUES " +
                    "(1, 0, 'CPU Usage', '/', 90.0, 'CRITICAL', '5m', 1, ''), " +
                    "(2, 4, 'CPU Usage', '/', 90.0, 'CRITICAL', '5m', 1, ''), " +
                    "(3, 0, 'CPU Usage', '/', 75.0, 'CRITICAL', '5m', 1, '')"
            )
        }

        helper.runMigrationsAndValidate(
            databaseName,
            CURRENT_VERSION,
            true,
            *AppDatabase.ALL_MIGRATIONS,
        ).use { db ->
            db.query("SELECT id, presetKey FROM quick_scripts ORDER BY id").use { cursor ->
                cursor.moveToFirst()
                assertEquals("fleet.disk", cursor.getString(1))
                cursor.moveToNext()
                // Edited command still gets stamped: identity is the seeded name + category.
                assertEquals("fleet.cpu", cursor.getString(1))
                cursor.moveToNext()
                assertEquals(null, cursor.getString(1))
                cursor.moveToNext()
                // Shares the "Temperature" preset name but sits in General, so it stays the user's:
                // stamping it would let a later "disable presets" delete their own script.
                assertEquals(null, cursor.getString(1))
                cursor.moveToNext()
                // The family was off, so even an exact category/name match remains unowned.
                assertEquals(null, cursor.getString(1))
            }
            // Only the exact pristine fleet-wide rule is a preset. A per-host rule and an edited
            // fleet-wide threshold are both user-owned.
            db.query("SELECT id, presetKey FROM alert_rules ORDER BY id").use { cursor ->
                cursor.moveToFirst()
                assertEquals("alert.cpu", cursor.getString(1))
                cursor.moveToNext()
                assertEquals(null, cursor.getString(1))
                cursor.moveToNext()
                assertEquals(null, cursor.getString(1))
            }
            db.query("SELECT value FROM app_settings WHERE `key` = 'fleet_presets'").use { cursor ->
                assertTrue(cursor.moveToFirst())
                assertEquals("true", cursor.getString(0))
            }
        }
        context.deleteDatabase(databaseName)
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
            CURRENT_VERSION,
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
