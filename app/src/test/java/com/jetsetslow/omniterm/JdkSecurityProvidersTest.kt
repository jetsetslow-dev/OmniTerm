package com.jetsetslow.omniterm

import com.google.common.truth.Truth.assertThat
import com.jcraft.jsch.JSch
import com.jcraft.jsch.KeyPair
import java.security.Provider
import java.security.Security
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.Description
import org.junit.runners.model.Statement

/**
 * The certificate tests passed alone and failed in the full run, after a Robolectric test had put
 * Conscrypt first. This puts it first the same way, so the order the tests happen to run in no
 * longer decides whether the rule is exercised.
 */
class JdkSecurityProvidersTest {
    @Test
    fun ed25519KeysWorkWithConscryptFirstAndConscryptStaysFirstAfter() {
        val conscrypt = runCatching {
            Class.forName("org.conscrypt.Conscrypt").getMethod("newProvider").invoke(null) as Provider
        }.getOrNull()
        assumeTrue("Conscrypt's native library is not available on this host.", conscrypt != null)
        val leftBehind = Security.getProvider(conscrypt!!.name) == null
        if (leftBehind) Security.insertProviderAt(conscrypt, 1)
        try {
            val first = Security.getProviders().first()
            assertThat(first.name).isEqualTo(conscrypt.name)

            var publicKey = ByteArray(0)
            JdkSecurityProviders().apply(
                object : Statement() {
                    override fun evaluate() {
                        publicKey = KeyPair.genKeyPair(JSch(), KeyPair.ED25519).publicKeyBlob
                    }
                },
                Description.EMPTY,
            ).evaluate()

            assertThat(publicKey).isNotEmpty()
            assertThat(Security.getProviders().first()).isSameInstanceAs(first)
        } finally {
            if (leftBehind) Security.removeProvider(conscrypt.name)
        }
    }
}
