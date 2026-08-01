@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package com.jetsetslow.omniterm.shared.platform

import platform.Foundation.NSApplicationSupportDirectory
import platform.Foundation.NSFileManager
import platform.Foundation.NSFileProtectionComplete
import platform.Foundation.NSFileProtectionKey
import platform.Foundation.NSURL
import platform.Foundation.NSURLIsExcludedFromBackupKey
import platform.Foundation.NSUserDomainMask

/**
 * Where the OmniTerm database lives on iOS, and how it is protected (platform half of IOS-042).
 *
 * Application Support rather than Documents: the database is app-managed state, not user documents,
 * so it must not appear in the Files app where a stray delete would take the fleet with it.
 *
 * The database and its WAL/SHM siblings get `NSFileProtectionComplete` — unreadable while the
 * device is locked — and are excluded from iCloud/iTunes backup. Backing up the database would put
 * host inventory into a backup that a Keychain `ThisDeviceOnly` credential can never be restored
 * with, producing a restored app full of hosts whose secrets are gone.
 *
 * Nothing here moves any schema: the Room migration itself stays blocked on IOS-041's evidence.
 */
object IosDatabaseLocation {
    const val DATABASE_NAME: String = "omniterm.db"

    /** Files the protection and backup rules must cover; SQLite creates the siblings as needed. */
    fun companionFiles(databaseName: String = DATABASE_NAME): List<String> =
        listOf(databaseName, "$databaseName-wal", "$databaseName-shm")

    /** Creates the directory if needed and returns the absolute database path, or null if unavailable. */
    fun prepare(databaseName: String = DATABASE_NAME): String? {
        val manager = NSFileManager.defaultManager
        val support = manager.URLsForDirectory(NSApplicationSupportDirectory, NSUserDomainMask)
            .firstOrNull() as? NSURL ?: return null
        val directory = support.URLByAppendingPathComponent("OmniTerm") ?: return null
        val path = directory.path ?: return null
        if (!manager.fileExistsAtPath(path)) {
            manager.createDirectoryAtPath(path, withIntermediateDirectories = true, attributes = null, error = null)
        }
        val databaseUrl = directory.URLByAppendingPathComponent(databaseName) ?: return null
        return databaseUrl.path
    }

    /**
     * Applies protection and backup exclusion. Called after the database is opened, because SQLite
     * creates `-wal`/`-shm` lazily and a rule set before they exist would miss them.
     */
    fun protect(databasePath: String) {
        val manager = NSFileManager.defaultManager
        val directory = databasePath.substringBeforeLast('/')
        val name = databasePath.substringAfterLast('/')
        companionFiles(name).forEach { file ->
            val path = "$directory/$file"
            if (!manager.fileExistsAtPath(path)) return@forEach
            manager.setAttributes(
                mapOf<Any?, Any?>(NSFileProtectionKey to NSFileProtectionComplete),
                ofItemAtPath = path,
                error = null,
            )
            NSURL.fileURLWithPath(path).setResourceValue(true, forKey = NSURLIsExcludedFromBackupKey, error = null)
        }
    }
}
