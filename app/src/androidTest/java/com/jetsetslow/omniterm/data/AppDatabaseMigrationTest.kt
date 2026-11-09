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
        const val CURRENT_VERSION = 26
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

    @Test
    fun migrationToTwentyOnePreservesMetricsAndAddsNullableTemperature() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val databaseName = "migration-20-temperature-history"
        context.deleteDatabase(databaseName)
        helper.createDatabase(databaseName, 20).use { db ->
            db.execSQL(
                "INSERT INTO metric_history " +
                    "(id, serverId, timestamp, cpuUsage, ramUsage, diskUsage, latency, networkIn, networkOut) " +
                    "VALUES (1, 7, 1234, 11.0, 22.0, 33.0, 44, 55.0, 66.0)"
            )
        }

        helper.runMigrationsAndValidate(
            databaseName,
            CURRENT_VERSION,
            true,
            *AppDatabase.ALL_MIGRATIONS,
        ).use { db ->
            db.query(
                "SELECT serverId, cpuUsage, ramUsage, cpuTemperatureC FROM metric_history WHERE id = 1"
            ).use { cursor ->
                assertTrue(cursor.moveToFirst())
                assertEquals(7, cursor.getInt(0))
                assertEquals(11f, cursor.getFloat(1))
                assertEquals(22f, cursor.getFloat(2))
                assertTrue(cursor.isNull(3))
            }
        }
        context.deleteDatabase(databaseName)
    }

    /**
     * Saved tmux sessions are re-keyed by host and name. Existing rows keep every value, are
     * marked as OmniTerm's own, and two hosts may then each save a session with the same name.
     */
    @Test
    fun migrationToTwentyThreeKeysSavedSessionsByHostAndName() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val databaseName = "migration-22-saved-sessions"
        context.deleteDatabase(databaseName)
        helper.createDatabase(databaseName, 22).use { db ->
            db.execSQL(
                "INSERT INTO persistent_sessions (tmuxName, serverId, serverName, createdAt, backgroundedAt) " +
                    "VALUES ('omniterm-calm-otter', 7, 'nas', 1000, 2000)"
            )
        }

        helper.runMigrationsAndValidate(
            databaseName,
            CURRENT_VERSION,
            true,
            *AppDatabase.ALL_MIGRATIONS,
        ).use { db ->
            db.query(
                "SELECT tmuxName, serverId, serverName, createdAt, backgroundedAt, adopted FROM persistent_sessions"
            ).use { cursor ->
                assertTrue(cursor.moveToFirst())
                assertEquals("omniterm-calm-otter", cursor.getString(0))
                assertEquals(7, cursor.getInt(1))
                assertEquals("nas", cursor.getString(2))
                assertEquals(1000L, cursor.getLong(3))
                assertEquals(2000L, cursor.getLong(4))
                assertEquals(0, cursor.getInt(5))
            }
            db.execSQL(
                "INSERT INTO persistent_sessions (tmuxName, serverId, serverName, createdAt, backgroundedAt, adopted) " +
                    "VALUES ('main', 7, 'nas', 1, 1, 1), ('main', 8, 'pi', 1, 1, 1)"
            )
            db.query("SELECT COUNT(*) FROM persistent_sessions WHERE tmuxName = 'main'").use { cursor ->
                assertTrue(cursor.moveToFirst())
                assertEquals(2, cursor.getInt(0))
            }
        }
        context.deleteDatabase(databaseName)
    }

    /**
     * Existing alert rules keep every value and get an empty target, which only TLS and URL checks
     * read; existing SSH keys keep theirs and get no certificate.
     */
    @Test
    fun migrationToTwentyFourGivesExistingRulesAnEmptyTargetAndAddsTelnetHostsAndKubeClusters() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val databaseName = "migration-23-rule-target"
        context.deleteDatabase(databaseName)
        helper.createDatabase(databaseName, 23).use { db ->
            db.execSQL(
                "INSERT INTO alert_rules (id, serverId, metricName, mountPoint, thresholdValue, severity, triggerWindow, enabled, notes, presetKey) " +
                    "VALUES (4, 7, 'Disk Usage', '/srv', 85.0, 'WARNING', '10m', 1, 'backups', NULL)"
            )
            db.execSQL(
                "INSERT INTO ssh_keys (id, alias, keyType, privateKey, publicKey, fingerprint) " +
                    "VALUES (2, 'laptop', 'ED25519', 'enc:v1:k', 'ssh-ed25519 AAAA laptop', 'SHA256:x')"
            )
        }

        helper.runMigrationsAndValidate(
            databaseName,
            CURRENT_VERSION,
            true,
            *AppDatabase.ALL_MIGRATIONS,
        ).use { db ->
            db.query("SELECT serverId, metricName, mountPoint, thresholdValue, triggerWindow, notes, target FROM alert_rules WHERE id = 4").use { cursor ->
                assertTrue(cursor.moveToFirst())
                assertEquals(7, cursor.getInt(0))
                assertEquals("Disk Usage", cursor.getString(1))
                assertEquals("/srv", cursor.getString(2))
                assertEquals(85.0, cursor.getDouble(3), 0.0)
                assertEquals("10m", cursor.getString(4))
                assertEquals("backups", cursor.getString(5))
                assertEquals("", cursor.getString(6))
            }
            db.query("SELECT alias, privateKey, certificate FROM ssh_keys WHERE id = 2").use { cursor ->
                assertTrue(cursor.moveToFirst())
                assertEquals("laptop", cursor.getString(0))
                assertEquals("enc:v1:k", cursor.getString(1))
                assertEquals("", cursor.getString(2))
            }
            db.execSQL("INSERT INTO telnet_hosts (name, host, port) VALUES ('core switch', '10.0.0.2', 23)")
            db.query("SELECT name, host, port FROM telnet_hosts").use { cursor ->
                assertTrue(cursor.moveToFirst())
                assertEquals("core switch", cursor.getString(0))
                assertEquals(23, cursor.getInt(2))
            }
            db.execSQL(
                "INSERT INTO kube_clusters (name, server, caPem, clientCertPem, clientKeyPem, token, namespace) " +
                    "VALUES ('lab', 'https://10.0.0.5:6443', '', '', '', 'enc:v1:x', 'shop')"
            )
            db.query("SELECT name, server, namespace FROM kube_clusters").use { cursor ->
                assertTrue(cursor.moveToFirst())
                assertEquals("lab", cursor.getString(0))
                assertEquals("https://10.0.0.5:6443", cursor.getString(1))
                assertEquals("shop", cursor.getString(2))
            }
        }
        context.deleteDatabase(databaseName)
    }

    /** Rules from before runbooks keep everything and have none; a runbook id then saves and reads back. */
    @Test
    fun migrationToTwentyFiveGivesExistingRulesNoRunbook() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val databaseName = "migration-24-runbook"
        context.deleteDatabase(databaseName)
        helper.createDatabase(databaseName, 24).use { db ->
            db.execSQL(
                "INSERT INTO alert_rules (id, serverId, metricName, mountPoint, thresholdValue, severity, triggerWindow, enabled, notes, presetKey, target) " +
                    "VALUES (5, 3, 'TCP Port', '/', 1000.0, 'CRITICAL', '2m', 1, 'db', NULL, 'db.lan:5432')"
            )
        }

        helper.runMigrationsAndValidate(
            databaseName,
            CURRENT_VERSION,
            true,
            *AppDatabase.ALL_MIGRATIONS,
        ).use { db ->
            db.query("SELECT serverId, metricName, triggerWindow, notes, target, runbookScriptId FROM alert_rules WHERE id = 5").use { cursor ->
                assertTrue(cursor.moveToFirst())
                assertEquals(3, cursor.getInt(0))
                assertEquals("TCP Port", cursor.getString(1))
                assertEquals("2m", cursor.getString(2))
                assertEquals("db", cursor.getString(3))
                assertEquals("db.lan:5432", cursor.getString(4))
                assertTrue(cursor.isNull(5))
            }
            db.execSQL("UPDATE alert_rules SET runbookScriptId = 9 WHERE id = 5")
            db.query("SELECT runbookScriptId FROM alert_rules WHERE id = 5").use { cursor ->
                assertTrue(cursor.moveToFirst())
                assertEquals(9, cursor.getInt(0))
            }
        }
        context.deleteDatabase(databaseName)
    }

    /** The run history starts empty, keeps the hosts and the rules it migrated alongside, and holds one row per run id. */
    @Test
    fun migrationToTwentySixAddsAnEmptyRunHistory() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val databaseName = "migration-25-run-history"
        context.deleteDatabase(databaseName)
        helper.createDatabase(databaseName, 25).use { db ->
            db.execSQL(
                "INSERT INTO alert_rules (id, serverId, metricName, mountPoint, thresholdValue, severity, triggerWindow, enabled, notes, presetKey, target, runbookScriptId) " +
                    "VALUES (5, 3, 'Script Check', '/', 0.0, 'CRITICAL', '2m', 1, '', NULL, '7', 8)"
            )
        }

        helper.runMigrationsAndValidate(
            databaseName,
            CURRENT_VERSION,
            true,
            *AppDatabase.ALL_MIGRATIONS,
        ).use { db ->
            db.query("SELECT target, runbookScriptId FROM alert_rules WHERE id = 5").use { cursor ->
                assertTrue(cursor.moveToFirst())
                assertEquals("7", cursor.getString(0))
                assertEquals(8, cursor.getInt(1))
            }
            db.query("SELECT COUNT(*) FROM fleet_runs").use { cursor ->
                assertTrue(cursor.moveToFirst())
                assertEquals(0, cursor.getInt(0))
            }
            db.execSQL("INSERT INTO fleet_runs (runKey, startedAt, finishedAt, command, scriptName, source) VALUES ('abc', 1, 2, 'uptime', NULL, 'fleet')")
            db.execSQL("INSERT INTO fleet_run_hosts (runId, serverId, serverName, status, note, output, truncated) VALUES (1, 3, 'nas', 'Success', NULL, 'up', 0)")
            db.query("SELECT r.command, h.serverName, h.output FROM fleet_runs r JOIN fleet_run_hosts h ON h.runId = r.id").use { cursor ->
                assertTrue(cursor.moveToFirst())
                assertEquals("uptime", cursor.getString(0))
                assertEquals("nas", cursor.getString(1))
                assertEquals("up", cursor.getString(2))
            }
            val duplicate = runCatching {
                db.execSQL("INSERT INTO fleet_runs (runKey, startedAt, finishedAt, command, scriptName, source) VALUES ('abc', 3, 4, 'df', NULL, 'fleet')")
            }
            assertTrue(duplicate.isFailure)
        }
        context.deleteDatabase(databaseName)
    }
}
