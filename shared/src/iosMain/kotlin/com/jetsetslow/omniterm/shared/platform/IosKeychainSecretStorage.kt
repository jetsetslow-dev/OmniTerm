@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package com.jetsetslow.omniterm.shared.platform

import kotlinx.cinterop.CPointer
import kotlinx.cinterop.addressOf
import kotlinx.cinterop.alloc
import kotlinx.cinterop.allocArrayOf
import kotlinx.cinterop.cstr
import kotlinx.cinterop.memScoped
import kotlinx.cinterop.ptr
import kotlinx.cinterop.reinterpret
import kotlinx.cinterop.usePinned
import kotlinx.cinterop.value
import platform.CoreFoundation.CFDataCreate
import platform.CoreFoundation.CFDataGetBytePtr
import platform.CoreFoundation.CFDataGetLength
import platform.CoreFoundation.CFDataRef
import platform.CoreFoundation.CFDictionaryAddValue
import platform.CoreFoundation.CFDictionaryCreateMutable
import platform.CoreFoundation.CFDictionaryRef
import platform.CoreFoundation.CFMutableDictionaryRef
import platform.CoreFoundation.CFRelease
import platform.CoreFoundation.CFStringCreateWithCString
import platform.CoreFoundation.CFStringRef
import platform.CoreFoundation.CFTypeRefVar
import platform.CoreFoundation.kCFBooleanTrue
import platform.CoreFoundation.kCFStringEncodingUTF8
import platform.CoreFoundation.kCFTypeDictionaryKeyCallBacks
import platform.CoreFoundation.kCFTypeDictionaryValueCallBacks
import platform.Security.SecItemAdd
import platform.Security.SecItemCopyMatching
import platform.Security.SecItemDelete
import platform.Security.SecItemUpdate
import platform.Security.errSecItemNotFound
import platform.Security.errSecSuccess
import platform.Security.kSecAttrAccessible
import platform.Security.kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
import platform.Security.kSecAttrAccessibleWhenUnlockedThisDeviceOnly
import platform.Security.kSecAttrAccount
import platform.Security.kSecAttrService
import platform.Security.kSecClass
import platform.Security.kSecClassGenericPassword
import platform.Security.kSecMatchLimit
import platform.Security.kSecMatchLimitOne
import platform.Security.kSecReturnData
import platform.Security.kSecValueData
import platform.darwin.OSStatus
import platform.posix.memcpy

/**
 * Apple Keychain implementation of [SecretStorage] (platform half of IOS-060).
 *
 * Items are generic passwords under one service, with an accessibility class that keeps them on
 * this device only: OmniTerm never needs a credential while the device is locked, and
 * `ThisDeviceOnly` keeps secrets out of encrypted backups and iCloud Keychain sync — which is what
 * the security review requires of a credential that can open someone's server.
 *
 * The shared [SecretVault] owns namespacing, the authentication gate, and redaction; this class
 * only translates that contract into `SecItem*` calls and OSStatus values. Everything is built with
 * CoreFoundation types directly so no Foundation bridging can quietly retain a secret.
 */
class IosKeychainSecretStorage(
    private val service: String = DEFAULT_SERVICE,
    private val accessibility: SecretAccessibility = SecretAccessibility.WhenUnlockedThisDeviceOnly,
) : SecretStorage {

    override suspend fun store(key: String, value: ByteArray): CapabilityResult<Unit> {
        // Update before add: SecItemAdd on an existing account fails with errSecDuplicateItem, and
        // delete-then-add would leave the credential absent if the process died between the two.
        val updateStatus = useDictionary(3) { query ->
            query.putBase(key)
            useDictionary(1) { changes ->
                val data = value.toCFData()
                changes.put(kSecValueData, data, owned = true)
                SecItemUpdate(query, changes)
            }
        }
        if (updateStatus == errSecSuccess) return CapabilityResult.Available(Unit)
        if (updateStatus != errSecItemNotFound) return updateStatus.asFailure()

        val addStatus = useDictionary(5) { attributes ->
            attributes.putBase(key)
            attributes.put(kSecValueData, value.toCFData(), owned = true)
            attributes.put(kSecAttrAccessible, accessibility.attribute(), owned = false)
            SecItemAdd(attributes, null)
        }
        return if (addStatus == errSecSuccess) CapabilityResult.Available(Unit) else addStatus.asFailure()
    }

    override suspend fun read(key: String): CapabilityResult<ByteArray?> = memScoped {
        val holder = alloc<CFTypeRefVar>()
        val status = useDictionary(5) { query ->
            query.putBase(key)
            query.put(kSecReturnData, kCFBooleanTrue, owned = false)
            query.put(kSecMatchLimit, kSecMatchLimitOne, owned = false)
            SecItemCopyMatching(query, holder.ptr)
        }
        when (status) {
            errSecSuccess -> {
                val data: CFDataRef = holder.value?.reinterpret()
                    ?: return@memScoped CapabilityResult.Available(null)
                val bytes = data.toByteArray()
                // SecItemCopyMatching returns +1; the caller owns the copy it just made.
                CFRelease(data)
                CapabilityResult.Available(bytes)
            }
            // A missing item is not an error at this layer; SecretVault decides what absence means.
            errSecItemNotFound -> CapabilityResult.Available(null)
            else -> status.asFailure()
        }
    }

    override suspend fun remove(key: String): CapabilityResult<Unit> {
        val status = useDictionary(3) { query ->
            query.putBase(key)
            SecItemDelete(query)
        }
        // Deleting something already gone satisfies the caller's intent.
        return if (status == errSecSuccess || status == errSecItemNotFound) {
            CapabilityResult.Available(Unit)
        } else {
            status.asFailure()
        }
    }

    private fun CFMutableDictionaryRef?.putBase(key: String) {
        put(kSecClass, kSecClassGenericPassword, owned = false)
        put(kSecAttrService, service.toCFString(), owned = true)
        put(kSecAttrAccount, key.toCFString(), owned = true)
    }

    /**
     * Adds one entry. CFDictionary retains what it stores, so anything created here (`+1`) is
     * released immediately afterwards — otherwise every Keychain call would leak its query strings.
     */
    private fun CFMutableDictionaryRef?.put(key: CPointer<*>?, value: CPointer<*>?, owned: Boolean) {
        CFDictionaryAddValue(this, key, value)
        if (owned && value != null) CFRelease(value)
    }

    private inline fun <R> useDictionary(capacity: Int, block: (CFMutableDictionaryRef?) -> R): R {
        val dictionary = CFDictionaryCreateMutable(
            null,
            capacity.toLong(),
            kCFTypeDictionaryKeyCallBacks.ptr,
            kCFTypeDictionaryValueCallBacks.ptr,
        )
        return try {
            block(dictionary)
        } finally {
            if (dictionary != null) CFRelease(dictionary)
        }
    }

    private fun SecretAccessibility.attribute(): CFStringRef? = when (this) {
        SecretAccessibility.WhenUnlockedThisDeviceOnly -> kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecretAccessibility.AfterFirstUnlockThisDeviceOnly -> kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    }

    /**
     * Keychain OSStatus values are never surfaced verbatim: a platform error string must not become
     * business logic, and it must not reach a log carrying an item identifier.
     */
    private fun OSStatus.asFailure(): CapabilityResult<Nothing> = when (this) {
        ERR_SEC_INTERACTION_NOT_ALLOWED, ERR_SEC_AUTH_FAILED ->
            CapabilityResult.Failed(PlatformError.AuthenticationFailed)
        ERR_SEC_USER_CANCELED -> CapabilityResult.Failed(PlatformError.Cancelled)
        else -> CapabilityResult.Failed(PlatformError.StorageUnavailable)
    }

    private companion object {
        const val DEFAULT_SERVICE = "com.jetsetslow.omniterm.secrets"

        /** Device is locked, so the item cannot be read right now. */
        const val ERR_SEC_INTERACTION_NOT_ALLOWED: OSStatus = -25308
        const val ERR_SEC_USER_CANCELED: OSStatus = -128
        const val ERR_SEC_AUTH_FAILED: OSStatus = -25293
    }
}

/** Caller owns the result (`+1`). */
internal fun String.toCFString(): CFStringRef? =
    CFStringCreateWithCString(null, this, kCFStringEncodingUTF8)

/** Caller owns the result (`+1`). */
internal fun ByteArray.toCFData(): CFDataRef? = memScoped {
    val buffer = if (isEmpty()) null else allocArrayOf(this@toCFData)
    CFDataCreate(null, buffer?.reinterpret(), size.toLong())
}

internal fun CFDataRef.toByteArray(): ByteArray {
    val size = CFDataGetLength(this).toInt()
    if (size == 0) return ByteArray(0)
    val source = CFDataGetBytePtr(this) ?: return ByteArray(0)
    val result = ByteArray(size)
    result.usePinned { pinned -> memcpy(pinned.addressOf(0), source, size.toULong()) }
    return result
}
