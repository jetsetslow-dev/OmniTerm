package com.jetsetslow.omniterm

import java.security.Provider
import java.security.Security
import org.junit.rules.ExternalResource

/**
 * Robolectric puts Conscrypt first among the JVM's security providers and leaves it there, so a
 * plain test that runs after any Robolectric test in the same JVM gets Conscrypt's Ed25519 keys,
 * which JSch cannot use. This rule takes Conscrypt out for the test and puts it back after, so
 * the test sees the JDK's own providers whatever ran before it.
 */
class JdkSecurityProviders : ExternalResource() {
    private var removed: Pair<Provider, Int>? = null

    override fun before() {
        val providers = Security.getProviders()
        val index = providers.indexOfFirst { it.javaClass.name.startsWith("org.conscrypt.") }
        if (index < 0) return
        removed = providers[index] to index + 1
        Security.removeProvider(providers[index].name)
    }

    override fun after() {
        removed?.let { (provider, position) -> Security.insertProviderAt(provider, position) }
        removed = null
    }
}
