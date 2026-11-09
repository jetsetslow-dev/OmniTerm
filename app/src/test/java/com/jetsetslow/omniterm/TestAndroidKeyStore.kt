package com.jetsetslow.omniterm

import android.security.keystore.KeyGenParameterSpec
import org.junit.rules.ExternalResource
import java.io.InputStream
import java.io.OutputStream
import java.security.Key
import java.security.KeyStoreSpi
import java.security.SecureRandom
import java.security.Security
import java.security.cert.Certificate
import java.security.spec.AlgorithmParameterSpec
import java.util.Collections
import java.util.Date
import java.util.Enumeration
import java.util.concurrent.ConcurrentHashMap
import javax.crypto.KeyGeneratorSpi
import javax.crypto.SecretKey
import javax.crypto.spec.SecretKeySpec

/**
 * An in-memory `AndroidKeyStore` for Robolectric tests, which have none, so the repository can
 * save passwords and private keys as the app does. It holds AES keys only, as `SecretStore` makes
 * them, and is removed again after each test.
 */
class TestAndroidKeyStore : ExternalResource() {
    override fun before() {
        keys.clear()
        Security.removeProvider(NAME)
        Security.addProvider(Store.Provider())
    }

    override fun after() {
        Security.removeProvider(NAME)
        keys.clear()
    }

    internal class Store : KeyStoreSpi() {
        class Provider : java.security.Provider(NAME, 1.0, "In-memory AndroidKeyStore for tests") {
            init {
                put("KeyStore.$NAME", Store::class.java.name)
                put("KeyGenerator.AES", Generator::class.java.name)
            }
        }

        override fun engineGetKey(alias: String, password: CharArray?): Key? = keys[alias]
        override fun engineGetCertificateChain(alias: String?): Array<Certificate>? = null
        override fun engineGetCertificate(alias: String?): Certificate? = null
        override fun engineGetCreationDate(alias: String?): Date? = null
        override fun engineSetKeyEntry(alias: String, key: Key, password: CharArray?, chain: Array<out Certificate>?) { keys[alias] = key }
        override fun engineSetKeyEntry(alias: String?, key: ByteArray?, chain: Array<out Certificate>?) = throw UnsupportedOperationException()
        override fun engineSetCertificateEntry(alias: String?, cert: Certificate?) = throw UnsupportedOperationException()
        override fun engineDeleteEntry(alias: String) { keys.remove(alias) }
        override fun engineAliases(): Enumeration<String> = Collections.enumeration(keys.keys.toList())
        override fun engineContainsAlias(alias: String): Boolean = keys.containsKey(alias)
        override fun engineSize(): Int = keys.size
        override fun engineIsKeyEntry(alias: String): Boolean = keys.containsKey(alias)
        override fun engineIsCertificateEntry(alias: String?): Boolean = false
        override fun engineGetCertificateAlias(cert: Certificate?): String? = null
        override fun engineStore(stream: OutputStream?, password: CharArray?) = Unit
        override fun engineLoad(stream: InputStream?, password: CharArray?) = Unit
    }

    /** Makes an AES key and keeps it under the alias its `KeyGenParameterSpec` names. */
    internal class Generator : KeyGeneratorSpi() {
        private var alias: String? = null

        override fun engineInit(random: SecureRandom?) = Unit
        override fun engineInit(keysize: Int, random: SecureRandom?) = Unit
        override fun engineInit(params: AlgorithmParameterSpec?, random: SecureRandom?) {
            alias = (params as? KeyGenParameterSpec)?.keystoreAlias
        }

        override fun engineGenerateKey(): SecretKey {
            val key = SecretKeySpec(ByteArray(32).also { SecureRandom().nextBytes(it) }, "AES")
            alias?.let { keys[it] = key }
            return key
        }
    }

    private companion object {
        const val NAME = "AndroidKeyStore"
        val keys = ConcurrentHashMap<String, Key>()
    }
}
