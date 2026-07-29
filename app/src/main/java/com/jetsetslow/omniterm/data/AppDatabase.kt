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
        NetworkShareEntity::class,
        AppSettingEntity::class,
        PersistentSessionEntity::class,
        PortForwardEntity::class,
        StackRegistryEntity::class
    ],
    // NOTE: bump this whenever any @Entity schema changes, and add a real Migration for the bump.
    // Schemas are exported to app/schemas/ (committed) so migrations can be written and tested
    // against the exact prior shape. Versions ≤7 predate schema export (several v5 builds shipped
    // with differing schemas), so upgrades from those still fall back to a destructive wipe — but
    // from v8 on, a version bump without a Migration must fail loudly instead of deleting data.
    version = 20,
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
    abstract fun networkShareDao(): NetworkShareDao
    abstract fun appSettingDao(): AppSettingDao
    abstract fun persistentSessionDao(): PersistentSessionDao
    abstract fun portForwardDao(): PortForwardDao
    abstract fun stackRegistryDao(): StackRegistryDao

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

        // WoL targets gain an optional host IP, used to ping for live online status.
        private val MIGRATION_12_13 = object : Migration(12, 13) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE wol_targets ADD COLUMN ipAddress TEXT NOT NULL DEFAULT ''")
            }
        }

        // Scripts and alert rules gain a free-text notes/comment field for documentation.
        private val MIGRATION_13_14 = object : Migration(13, 14) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE quick_scripts ADD COLUMN notes TEXT NOT NULL DEFAULT ''")
                db.execSQL("ALTER TABLE alert_rules ADD COLUMN notes TEXT NOT NULL DEFAULT ''")
            }
        }

        // Saved LAN/network share profiles for SMB/FTP/SFTP/NFS/WebDAV discovery and access metadata.
        private val MIGRATION_14_15 = object : Migration(14, 15) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE credential_profiles ADD COLUMN groupName TEXT NOT NULL DEFAULT 'General'")
                db.execSQL(
                    "CREATE TABLE IF NOT EXISTS network_shares (" +
                        "id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, " +
                        "name TEXT NOT NULL, " +
                        "protocol TEXT NOT NULL, " +
                        "address TEXT NOT NULL, " +
                        "port INTEGER NOT NULL, " +
                        "sharePath TEXT NOT NULL, " +
                        "workgroup TEXT NOT NULL, " +
                        "username TEXT NOT NULL, " +
                        "password TEXT NOT NULL, " +
                        "authProfileId INTEGER, " +
                        "anonymous INTEGER NOT NULL, " +
                        "notes TEXT NOT NULL, " +
                        "lastChecked INTEGER NOT NULL, " +
                        "lastStatus TEXT NOT NULL)"
                )
            }
        }

        // WebDAV shares gain an explicit TLS flag; backfill from the old port heuristic (443/8443
        // were treated as https) so existing shares keep connecting exactly as before.
        private val MIGRATION_15_16 = object : Migration(15, 16) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE network_shares ADD COLUMN useHttps INTEGER NOT NULL DEFAULT 0")
                db.execSQL("UPDATE network_shares SET useHttps = 1 WHERE UPPER(protocol) = 'WEBDAV' AND port IN (443, 8443)")
            }
        }

        // Per-server SSH agent forwarding (ssh -A) opt-in + saved port-forward tunnels.
        private val MIGRATION_16_17 = object : Migration(16, 17) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE servers ADD COLUMN agentForwarding INTEGER NOT NULL DEFAULT 0")
                db.execSQL(
                    "CREATE TABLE IF NOT EXISTS port_forwards (" +
                        "id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, " +
                        "serverId INTEGER NOT NULL, " +
                        "name TEXT NOT NULL, " +
                        "kind TEXT NOT NULL DEFAULT 'local', " +
                        "bindHost TEXT NOT NULL DEFAULT '127.0.0.1', " +
                        "bindPort INTEGER NOT NULL, " +
                        "destHost TEXT NOT NULL DEFAULT '', " +
                        "destPort INTEGER NOT NULL DEFAULT 0, " +
                        "autoStart INTEGER NOT NULL DEFAULT 0)"
                )
            }
        }

        // App-side registry of compose stacks, so a stack downed via `compose down` (containers
        // and networks removed — the daemon keeps no record) can still be listed and brought up.
        private val MIGRATION_17_18 = object : Migration(17, 18) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL(
                    "CREATE TABLE IF NOT EXISTS stack_registry (" +
                        "id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, " +
                        "serverId INTEGER NOT NULL, " +
                        "runtime TEXT NOT NULL, " +
                        "project TEXT NOT NULL, " +
                        "workingDir TEXT NOT NULL, " +
                        "configFiles TEXT NOT NULL, " +
                        "lastSeenAt INTEGER NOT NULL)"
                )
                db.execSQL(
                    "CREATE UNIQUE INDEX IF NOT EXISTS index_stack_registry_serverId_runtime_project " +
                        "ON stack_registry (serverId, runtime, project)"
                )
            }
        }

        // One rule can have one live incident per concrete host. Keep the newest legacy row before
        // enforcing that identity; older builds could race manual and periodic telemetry probes.
        private val MIGRATION_18_19 = object : Migration(18, 19) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL(
                    "DELETE FROM active_alerts WHERE id NOT IN (" +
                        "SELECT MAX(id) FROM active_alerts GROUP BY ruleId, serverId)"
                )
                db.execSQL(
                    "CREATE UNIQUE INDEX IF NOT EXISTS index_active_alerts_ruleId_serverId " +
                        "ON active_alerts (ruleId, serverId)"
                )
            }
        }

        // Preset rows get a stable presetKey so the "default presets" toggles can remove exactly
        // what they seeded even after the user edits one. Back-stamping is deliberately gated by
        // the corresponding setting: a matching name/category or fleet-wide metric is not proof
        // that a row belongs to OmniTerm when that preset family was disabled.
        private val MIGRATION_19_20 = object : Migration(19, 20) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE quick_scripts ADD COLUMN presetKey TEXT")
                db.execSQL("ALTER TABLE alert_rules ADD COLUMN presetKey TEXT")
                // "Backgrounded since" for saved tmux sessions. Existing rows have never been
                // observed being backgrounded, so seed them from createdAt rather than "now",
                // which would falsely show every restored session as just-backgrounded.
                db.execSQL("ALTER TABLE persistent_sessions ADD COLUMN backgroundedAt INTEGER NOT NULL DEFAULT 0")
                db.execSQL("UPDATE persistent_sessions SET backgroundedAt = createdAt WHERE backgroundedAt = 0")

                // Fleet presets used to be on by default without persisting a setting. Preserve
                // that state only when a recognisable legacy fleet row exists. A stored false
                // value wins because INSERT OR IGNORE never overwrites the user's choice.
                db.execSQL(
                    "INSERT OR IGNORE INTO app_settings (`key`, value) " +
                        "SELECT 'fleet_presets', 'true' WHERE EXISTS (" +
                        "SELECT 1 FROM quick_scripts WHERE category = 'Fleet' AND name IN (" +
                        LEGACY_SCRIPT_PRESET_KEYS
                            .filter { it.familySetting == "fleet_presets" }
                            .joinToString(",") { "'${it.name.replace("'", "''")}'" } +
                        "))"
                )
                for (preset in LEGACY_SCRIPT_PRESET_KEYS) {
                    db.execSQL(
                        "UPDATE quick_scripts SET presetKey = ? " +
                            "WHERE presetKey IS NULL AND name = ? AND category = ? " +
                            "AND EXISTS (SELECT 1 FROM app_settings WHERE `key` = ? AND value = 'true')",
                        arrayOf(preset.key, preset.name, preset.category, preset.familySetting),
                    )
                }
                for (preset in LEGACY_RULE_PRESETS) {
                    db.execSQL(
                        "UPDATE alert_rules SET presetKey = ? " +
                            "WHERE presetKey IS NULL AND serverId = 0 AND metricName = ? " +
                            "AND mountPoint = '/' AND thresholdValue = ? AND severity = ? " +
                            "AND triggerWindow = '5m' AND enabled = 1 AND notes = '' " +
                            "AND EXISTS (SELECT 1 FROM app_settings " +
                            "WHERE `key` = 'alert_presets' AND value = 'true')",
                        arrayOf<Any>(
                            preset.key,
                            preset.metric,
                            preset.threshold,
                            preset.severity,
                        ),
                    )
                }
            }
        }

        private data class LegacyScriptPreset(
            val key: String,
            val name: String,
            val category: String,
            val familySetting: String,
        )

        /** Seeded identities for rows created before the presetKey column existed. */
        private val LEGACY_SCRIPT_PRESET_KEYS = listOf(
            LegacyScriptPreset("fleet.cpu", "CPU/RAM", "Fleet", "fleet_presets"),
            LegacyScriptPreset("fleet.disk", "Disk", "Fleet", "fleet_presets"),
            LegacyScriptPreset("fleet.processes", "Processes", "Fleet", "fleet_presets"),
            LegacyScriptPreset("fleet.services", "Failed services", "Fleet", "fleet_presets"),
            LegacyScriptPreset("fleet.syslog", "Syslog errors", "Fleet", "fleet_presets"),
            LegacyScriptPreset("fleet.containers", "Containers", "Fleet", "fleet_presets"),
            LegacyScriptPreset("fleet.ports", "Listening ports", "Fleet", "fleet_presets"),
            LegacyScriptPreset("fleet.kernel", "Kernel", "Fleet", "fleet_presets"),
            LegacyScriptPreset("homelab.pve_vms", "PVE: list VMs", "Proxmox", "homelab_presets"),
            LegacyScriptPreset("homelab.pve_containers", "PVE: list containers", "Proxmox", "homelab_presets"),
            LegacyScriptPreset("homelab.pve_cluster", "PVE: cluster status", "Proxmox", "homelab_presets"),
            LegacyScriptPreset("homelab.pve_storage", "PVE: storage status", "Proxmox", "homelab_presets"),
            LegacyScriptPreset("homelab.pve_start_vm", "PVE: start VM <id>", "Proxmox", "homelab_presets"),
            LegacyScriptPreset("homelab.pve_stop_vm", "PVE: stop VM <id>", "Proxmox", "homelab_presets"),
            LegacyScriptPreset("homelab.casaos_status", "CasaOS: status", "CasaOS", "homelab_presets"),
            LegacyScriptPreset("homelab.casaos_restart", "CasaOS: restart", "CasaOS", "homelab_presets"),
            LegacyScriptPreset("homelab.casaos_version", "CasaOS: version", "CasaOS", "homelab_presets"),
            LegacyScriptPreset("homelab.ha_info", "HA: info", "Home Assistant", "homelab_presets"),
            LegacyScriptPreset("homelab.ha_core_logs", "HA: core logs", "Home Assistant", "homelab_presets"),
            LegacyScriptPreset("homelab.ha_restart_core", "HA: restart core", "Home Assistant", "homelab_presets"),
            LegacyScriptPreset("homelab.ha_supervisor_logs", "HA: supervisor logs", "Home Assistant", "homelab_presets"),
            LegacyScriptPreset("homelab.temperature", "Temperature", "Linux", "homelab_presets"),
            LegacyScriptPreset("homelab.updates", "Updates available", "Homelab", "homelab_presets"),
            LegacyScriptPreset("homelab.reboot_required", "Reboot required?", "Homelab", "homelab_presets"),
            LegacyScriptPreset("homelab.top_cpu", "Top 10 by CPU", "Homelab", "homelab_presets"),
            LegacyScriptPreset("homelab.docker_stats", "Docker stats", "Homelab", "homelab_presets"),
            LegacyScriptPreset("homelab.disk_usage", "Disk usage", "Homelab", "homelab_presets"),
        )

        private data class LegacyRulePreset(
            val key: String,
            val metric: String,
            val threshold: Float,
            val severity: String,
        )

        /** Exact pristine alert identities predating presetKey. */
        private val LEGACY_RULE_PRESETS = listOf(
            LegacyRulePreset("alert.cpu", "CPU Usage", 90f, "CRITICAL"),
            LegacyRulePreset("alert.memory", "Memory Usage", 90f, "CRITICAL"),
            LegacyRulePreset("alert.disk", "Disk Usage", 90f, "WARNING"),
            LegacyRulePreset("alert.latency", "Latency", 250f, "WARNING"),
        )

        /** Complete non-destructive migration chain for builders and schema regression tests. */
        internal val ALL_MIGRATIONS: Array<Migration> = arrayOf(
            MIGRATION_8_9,
            MIGRATION_9_10,
            MIGRATION_10_11,
            MIGRATION_11_12,
            MIGRATION_12_13,
            MIGRATION_13_14,
            MIGRATION_14_15,
            MIGRATION_15_16,
            MIGRATION_16_17,
            MIGRATION_17_18,
            MIGRATION_18_19,
            MIGRATION_19_20,
        )

        fun getDatabase(context: Context): AppDatabase {
            return INSTANCE ?: synchronized(this) {
                val instance = Room.databaseBuilder(
                    context.applicationContext,
                    AppDatabase::class.java,
                    "omniterm_database"
                )
                // Destructive only for the un-exported legacy versions; never for v8+.
                .fallbackToDestructiveMigrationFrom(dropAllTables = true, 1, 2, 3, 4, 5, 6, 7)
                .addMigrations(*ALL_MIGRATIONS)
                .build()
                INSTANCE = instance
                instance
            }
        }
    }
}
