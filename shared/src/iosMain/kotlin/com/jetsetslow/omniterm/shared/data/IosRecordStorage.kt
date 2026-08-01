@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package com.jetsetslow.omniterm.shared.data

import com.jetsetslow.omniterm.shared.platform.CapabilityResult
import com.jetsetslow.omniterm.shared.platform.PlatformError
import platform.Foundation.NSFileManager
import platform.Foundation.NSFileProtectionComplete
import platform.Foundation.NSFileProtectionKey
import platform.Foundation.NSString
import platform.Foundation.NSURL
import platform.Foundation.NSURLIsExcludedFromBackupKey
import platform.Foundation.NSUTF8StringEncoding
import platform.Foundation.stringWithContentsOfFile
import platform.Foundation.writeToFile

/**
 * iOS [RecordStorage] backed by one file in the app container (IOS-042).
 *
 * `atomically = true` is what makes a torn write impossible: Foundation writes a temporary file and
 * renames it over the target, so an interrupted save leaves the previous host list intact rather
 * than a truncated one.
 *
 * The file carries `NSFileProtectionComplete` — unreadable while the device is locked — and is
 * excluded from backup, matching [com.jetsetslow.omniterm.shared.platform.IosDatabaseLocation]:
 * host inventory must not travel in a backup whose `ThisDeviceOnly` credentials cannot follow it.
 */
class IosRecordStorage(private val path: String) : RecordStorage {
    private val fileManager = NSFileManager.defaultManager

    override suspend fun read(): String? {
        if (!fileManager.fileExistsAtPath(path)) return null
        return NSString.stringWithContentsOfFile(path, encoding = NSUTF8StringEncoding, error = null)
    }

    override suspend fun write(contents: String): CapabilityResult<Unit> {
        @Suppress("CAST_NEVER_SUCCEEDS")
        val text = contents as NSString
        val wrote = text.writeToFile(path, atomically = true, encoding = NSUTF8StringEncoding, error = null)
        if (!wrote) return CapabilityResult.Failed(PlatformError.StorageUnavailable)
        protect()
        return CapabilityResult.Available(Unit)
    }

    /** Re-applied after every write: an atomic replace creates a new file with default attributes. */
    private fun protect() {
        fileManager.setAttributes(
            mapOf<Any?, Any?>(NSFileProtectionKey to NSFileProtectionComplete),
            ofItemAtPath = path,
            error = null,
        )
        NSURL.fileURLWithPath(path).setResourceValue(true, forKey = NSURLIsExcludedFromBackupKey, error = null)
    }
}
