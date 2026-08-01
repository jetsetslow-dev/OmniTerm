package com.jetsetslow.omniterm.shared.feature

import com.jetsetslow.omniterm.shared.core.PlatformFamily
import com.jetsetslow.omniterm.shared.platform.CapabilityResult

/** The network-share protocols OmniTerm knows about. */
enum class ShareProtocol(val setting: String) {
    Smb("smb"),
    Ftp("ftp"),
    WebDav("webdav");

    companion object {
        fun fromSetting(value: String?): ShareProtocol? = entries.firstOrNull { it.setting == value }
    }
}

/**
 * Whether a protocol can actually be used on this platform right now.
 *
 * ADR 0003 targets full parity, but a protocol without a maintained implementation must say so.
 * `Unavailable` is deliberately not the same as "hidden": a share the user configured on Android
 * still appears on iOS, described as unavailable, so their data never silently disappears and an
 * operation on it never reports success.
 */
sealed interface ShareAvailability {
    data object Available : ShareAvailability
    data class Unavailable(val reason: String) : ShareAvailability
}

/**
 * Per-platform protocol support (IOS-054).
 *
 * Android supports all three today. iOS ships WebDAV, which is already shared through Ktor; SMB and
 * FTP wait for a maintained Apple-target implementation, each of which needs its own licensing, SBOM
 * entry, dependency-verification checksums, and protocol test suite before it may be enabled.
 *
 * When such an implementation lands, the only change here is flipping its entry — every caller
 * already handles the unavailable case, because there was never a path that assumed success.
 */
object NetworkShareCapability {
    private const val IOS_PENDING =
        "Not available on iOS yet. Your saved share is kept and will work once support ships."

    fun availability(protocol: ShareProtocol, platform: PlatformFamily): ShareAvailability = when (platform) {
        PlatformFamily.Android -> ShareAvailability.Available
        PlatformFamily.Ios -> when (protocol) {
            ShareProtocol.WebDav -> ShareAvailability.Available
            ShareProtocol.Smb, ShareProtocol.Ftp -> ShareAvailability.Unavailable(IOS_PENDING)
        }
        // An unknown platform must not be assumed capable.
        PlatformFamily.Unknown -> ShareAvailability.Unavailable("Unsupported platform")
    }

    fun isAvailable(protocol: ShareProtocol, platform: PlatformFamily): Boolean =
        availability(protocol, platform) is ShareAvailability.Available

    /**
     * Gate every share operation through this. It returns [CapabilityResult.Unsupported] rather than
     * throwing or returning a fake success, so a caller cannot accidentally report that an upload to
     * an unsupported share worked.
     */
    fun <T> guard(
        protocol: ShareProtocol,
        platform: PlatformFamily,
        operation: () -> CapabilityResult<T>,
    ): CapabilityResult<T> = when (val availability = availability(protocol, platform)) {
        ShareAvailability.Available -> operation()
        is ShareAvailability.Unavailable -> CapabilityResult.Unsupported(availability.reason)
    }

    /** Protocols to offer when the user adds a share; unsupported ones are not selectable. */
    fun selectableProtocols(platform: PlatformFamily): List<ShareProtocol> =
        ShareProtocol.entries.filter { isAvailable(it, platform) }
}
