@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package com.jetsetslow.omniterm.shared.platform

import com.jetsetslow.omniterm.shared.feature.ConflictResolution
import com.jetsetslow.omniterm.shared.feature.LocalFileGateway
import com.jetsetslow.omniterm.shared.feature.WidgetFleetSnapshot
import com.jetsetslow.omniterm.shared.feature.WidgetSnapshotCodec
import kotlinx.cinterop.addressOf
import kotlinx.cinterop.allocArrayOf
import kotlinx.cinterop.memScoped
import kotlinx.cinterop.usePinned
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import platform.Foundation.NSData
import platform.Foundation.NSFileHandle
import platform.Foundation.NSFileManager
import platform.Foundation.NSNotificationCenter
import platform.Foundation.NSOperationQueue
import platform.Foundation.NSURL
import platform.Foundation.NSUserDefaults
import platform.Foundation.closeFile
import platform.Foundation.create
import platform.Foundation.fileHandleForReadingAtPath
import platform.Foundation.fileHandleForWritingAtPath
import platform.Foundation.readDataOfLength
import platform.Foundation.writeData
import platform.UIKit.UIApplication
import platform.UIKit.UIApplicationDidBecomeActiveNotification
import platform.UIKit.UIApplicationDidEnterBackgroundNotification
import platform.posix.memcpy

/**
 * Known-host records stored in the Keychain (platform half of IOS-052's persistence).
 *
 * Host keys are not secrets, but they are the only thing standing between a user and a
 * man-in-the-middle, so they get the same protection class as credentials rather than living in
 * `NSUserDefaults` where any backup or file-level compromise could edit them.
 */
class IosKeychainKnownHostsStore(
    private val storage: SecretStorage = IosKeychainSecretStorage(service = KNOWN_HOSTS_SERVICE),
) : KnownHostsStore {

    override suspend fun find(alias: String): HostKey? {
        val stored = storage.read(alias)
        val bytes = (stored as? CapabilityResult.Available)?.value ?: return null
        val text = bytes.decodeToString()
        val separator = text.indexOf(' ')
        if (separator < 1) return null
        return HostKey(text.substring(0, separator), text.substring(separator + 1))
    }

    override suspend fun put(alias: String, key: HostKey) {
        storage.store(alias, "${key.algorithm} ${key.fingerprint}".encodeToByteArray())
    }

    override suspend fun remove(alias: String) {
        storage.remove(alias)
    }

    private companion object {
        const val KNOWN_HOSTS_SERVICE = "com.jetsetslow.omniterm.knownhosts"
    }
}

/**
 * Publishes the widget snapshot into the App Group container the WidgetKit extension reads
 * (platform half of IOS-065).
 *
 * The App Group is readable by every extension in the group, so only [WidgetFleetSnapshot] — which
 * carries no address, user, port, or secret reference — is ever written here.
 */
class IosAppGroupWidgetPublisher(
    private val appGroupId: String,
    private val onPublished: () -> Unit = {},
) : WidgetPublisher {
    private val defaults: NSUserDefaults? = NSUserDefaults(suiteName = appGroupId)

    override suspend fun publish(snapshot: WidgetSnapshot): CapabilityResult<Unit> {
        val store = defaults ?: return CapabilityResult.Unsupported("App Group $appGroupId is not available")
        store.setInteger(snapshot.generatedAtEpochMillis, forKey = KEY_GENERATED_AT)
        store.setInteger(snapshot.online.toLong(), forKey = KEY_ONLINE)
        store.setInteger(snapshot.total.toLong(), forKey = KEY_TOTAL)
        store.setBool(snapshot.stale, forKey = KEY_STALE)
        onPublished()
        return CapabilityResult.Available(Unit)
    }

    /** Writes the full row list. The extension reloads its timeline only when this value changes. */
    fun publishFleet(snapshot: WidgetFleetSnapshot): CapabilityResult<Unit> {
        val store = defaults ?: return CapabilityResult.Unsupported("App Group $appGroupId is not available")
        val encoded = WidgetSnapshotCodec.encode(snapshot)
        if (store.stringForKey(KEY_FLEET) == encoded) return CapabilityResult.Available(Unit)
        store.setObject(encoded, forKey = KEY_FLEET)
        onPublished()
        return CapabilityResult.Available(Unit)
    }

    fun readFleet(): WidgetFleetSnapshot? = WidgetSnapshotCodec.decode(defaults?.stringForKey(KEY_FLEET))

    private companion object {
        const val KEY_GENERATED_AT = "omniterm.widget.generatedAt"
        const val KEY_ONLINE = "omniterm.widget.online"
        const val KEY_TOTAL = "omniterm.widget.total"
        const val KEY_STALE = "omniterm.widget.stale"
        const val KEY_FLEET = "omniterm.widget.fleet"
    }
}

/**
 * Foreground/background visibility from `UIApplication` notifications (platform half of the
 * lifecycle contract). iOS suspends ordinary apps in the background, so the shared stores use this
 * to stop polling rather than to promise continued work.
 */
class IosApplicationLifecycle : ApplicationLifecycle {
    override val visibility: Flow<ApplicationVisibility> = callbackFlow {
        val center = NSNotificationCenter.defaultCenter
        val queue = NSOperationQueue.mainQueue
        val foreground = center.addObserverForName(
            name = UIApplicationDidBecomeActiveNotification,
            `object` = null,
            queue = queue,
        ) { trySend(ApplicationVisibility.Foreground) }
        val background = center.addObserverForName(
            name = UIApplicationDidEnterBackgroundNotification,
            `object` = null,
            queue = queue,
        ) { trySend(ApplicationVisibility.Background) }
        awaitClose {
            center.removeObserver(foreground)
            center.removeObserver(background)
        }
    }
}

/** Opens a URL or a downloaded file with the system handler. */
class IosExternalViewer(
    private val urlForFile: (PlatformFile) -> String? = { it.token },
) : ExternalViewer {
    override suspend fun open(file: PlatformFile): CapabilityResult<Unit> {
        val url = urlForFile(file) ?: return CapabilityResult.Failed(PlatformError.NotFound)
        return openUrl(url)
    }

    override suspend fun openUrl(url: String): CapabilityResult<Unit> {
        val target = NSURL.URLWithString(url) ?: return CapabilityResult.Failed(PlatformError.Protocol("bad-url"))
        val application = UIApplication.sharedApplication
        if (!application.canOpenURL(target)) {
            return CapabilityResult.Unsupported("No installed app can open this link")
        }
        application.openURL(target, options = emptyMap<Any?, Any>(), completionHandler = null)
        return CapabilityResult.Available(Unit)
    }
}

/**
 * Local file access for transfers (platform half of IOS-032/IOS-062), rooted in the app's own
 * container. `KeepBoth` finds a free `name (n).ext` exactly like the Android/remote paste rule, and
 * a discarded partial is deleted so a cancelled download never looks complete.
 */
class IosLocalFileGateway(private val directory: String) : LocalFileGateway {
    private val fileManager = NSFileManager.defaultManager

    override suspend fun exists(name: String): Boolean = fileManager.fileExistsAtPath(pathFor(name))

    override suspend fun openSink(name: String, resolution: ConflictResolution): Pair<String, ByteSink> {
        val target = if (resolution == ConflictResolution.KeepBoth) freeName(name) else name
        val path = pathFor(target)
        if (fileManager.fileExistsAtPath(path)) fileManager.removeItemAtPath(path, null)
        fileManager.createFileAtPath(path, contents = null, attributes = null)
        val handle = NSFileHandle.fileHandleForWritingAtPath(path)
            ?: throw IllegalStateException("Cannot open $target for writing")
        return target to NSFileHandleSink(handle)
    }

    override suspend fun openSource(name: String): Pair<ByteSource, Long?> {
        val path = pathFor(name)
        val handle = NSFileHandle.fileHandleForReadingAtPath(path)
            ?: throw IllegalStateException("Cannot open $name for reading")
        val size = (fileManager.attributesOfItemAtPath(path, null)?.get("NSFileSize") as? Long)
        return NSFileHandleSource(handle) to size
    }

    override suspend fun discardPartial(name: String) {
        fileManager.removeItemAtPath(pathFor(name), null)
    }

    private fun pathFor(name: String): String = "${directory.trimEnd('/')}/$name"

    private fun freeName(name: String): String {
        val dot = name.lastIndexOf('.')
        val base = if (dot > 0) name.substring(0, dot) else name
        val extension = if (dot > 0) name.substring(dot) else ""
        var index = 1
        while (true) {
            val candidate = "$base ($index)$extension"
            if (!fileManager.fileExistsAtPath(pathFor(candidate))) return candidate
            index++
        }
    }
}

private class NSFileHandleSink(private val handle: NSFileHandle) : ByteSink {
    override suspend fun write(buffer: ByteArray, count: Int) {
        val slice = if (count == buffer.size) buffer else buffer.copyOf(count)
        handle.writeData(slice.toNSData())
    }

    override suspend fun close() {
        handle.closeFile()
    }
}

private class NSFileHandleSource(private val handle: NSFileHandle) : ByteSource {
    override suspend fun read(buffer: ByteArray): Int {
        val data: NSData = handle.readDataOfLength(buffer.size.toULong())
        val length = data.length.toInt()
        if (length == 0) return -1
        data.toByteArray().copyInto(buffer, endIndex = length)
        return length
    }

    override suspend fun close() {
        handle.closeFile()
    }
}

@OptIn(kotlinx.cinterop.BetaInteropApi::class)
private fun ByteArray.toNSData(): NSData = memScoped {
    if (isEmpty()) NSData() else NSData.create(bytes = allocArrayOf(this@toNSData), length = size.toULong())
}

private fun NSData.toByteArray(): ByteArray {
    val size = length.toInt()
    if (size == 0) return ByteArray(0)
    val result = ByteArray(size)
    result.usePinned { pinned -> memcpy(pinned.addressOf(0), bytes, length) }
    return result
}
