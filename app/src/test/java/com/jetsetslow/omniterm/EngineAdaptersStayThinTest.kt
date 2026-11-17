package com.jetsetslow.omniterm

import com.google.common.truth.Truth.assertWithMessage
import org.junit.Test
import java.io.File

/**
 * SNMP and Proxmox reach their libraries through one thin adapter each, so a later engine (the Go
 * core on iOS, say) replaces that file alone: SNMP4J only in `Snmp4jEngine.kt`, and Proxmox's HTTP
 * and TLS only in `ProxmoxOkHttp.kt`. The rest of each feature talks to a plain Kotlin interface
 * with plain data classes. A source scan of imports and fully qualified names, so a new use
 * anywhere fails here.
 */
class EngineAdaptersStayThinTest {
    private val sources = generateSequence(File("").absoluteFile) { it.parentFile }
        .map { File(it, "app/src/main/java").takeIf(File::isDirectory) ?: File(it, "src/main/java") }
        .first { it.isDirectory }

    private val texts = sources.walkTopDown().filter { it.extension == "kt" }.associate { it.name to it.readText() }

    private fun naming(pkg: String) = texts.filterValues { Regex("""\b${Regex.escape(pkg)}\.""").containsMatchIn(it) }.keys

    @Test
    fun snmp4jStaysInItsAdapter() {
        assertWithMessage("files that use SNMP4J").that(naming("org.snmp4j")).containsExactly("Snmp4jEngine.kt")
    }

    @Test
    fun theFeaturesOwnFilesUseNoNetworkLibrary() {
        val libraries = listOf("org.snmp4j", "okhttp3", "okio", "com.squareup.moshi", "javax.net", "java.net", "java.security", "javax.crypto")
        for (file in listOf("SnmpDevices.kt", "SnmpScreen.kt", "ProxmoxApi.kt", "ProxmoxScreen.kt", "DeviceFormFields.kt", "JsonTree.kt")) {
            val used = libraries.filter { file in naming(it) }
            assertWithMessage("$file uses a network library").that(used).isEmpty()
        }
        assertWithMessage("Proxmox files that use OkHttp").that(naming("okhttp3").filter { "Proxmox" in it })
            .containsExactly("ProxmoxOkHttp.kt")
    }
}
