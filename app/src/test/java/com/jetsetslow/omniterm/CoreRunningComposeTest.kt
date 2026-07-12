package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.ui.parseDockerComposeYaml
import com.jetsetslow.omniterm.ui.renderComposeYaml
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Synthetic adversarial fixture with a top-level `name:`, a `x-common: &common` anchor,
 * networks/volumes before services, build blocks, and comments between services. It preserves
 * the parser regression coverage without publishing a user's real infrastructure inventory.
 */
class CoreRunningComposeTest {

    private fun load(): String =
        javaClass.classLoader!!.getResourceAsStream("core_running.yml")!!
            .bufferedReader().readText()

    @Test
    fun parses_name_and_all_services() {
        val d = parseDockerComposeYaml(load(), "core_utilities", "/home/ubuntu/core")
        assertEquals("core_utilities", d.stackName)
        val names = d.services.map { it.serviceName }
        for (n in listOf("open-webui", "hawser", "parser-service", "actual-sync", "ollama", "model-loader", "actual-budget")) {
            assertTrue("expected '$n' in $names", names.contains(n))
        }
    }

    @Test
    fun unchanged_is_byte_identical() {
        val baseline = parseDockerComposeYaml(load(), "core_utilities", "/home/ubuntu/core")
        assertEquals(load(), renderComposeYaml(baseline.copy(), baseline))
    }

    @Test
    fun comment_out_the_six_services_the_user_wanted() {
        val baseline = parseDockerComposeYaml(load(), "core_utilities", "/home/ubuntu/core")
        val targets = setOf("actual-budget", "open-webui", "parser-service", "actual-sync", "ollama", "model-loader")
        val edited = baseline.copy(
            services = baseline.services.map {
                if (it.serviceName in targets) it.copy(isCommentedOut = true) else it
            }.toMutableList(),
        )
        val out = renderComposeYaml(edited, baseline)

        for (n in targets) {
            assertFalse("uncommented '$n:' must be gone", Regex("(?m)^  $n:").containsMatchIn(out))
            assertTrue("'$n' header must be commented", Regex("(?m)^#\\s*$n:").containsMatchIn(out))
        }
        // Anchor + top-level blocks + a kept service survive untouched.
        assertTrue(out.contains("x-common: &common"))
        assertTrue(out.contains("name: core_utilities"))
        assertTrue(Regex("(?m)^  hawser:").containsMatchIn(out))
        assertTrue(Regex("(?m)^  memos:").containsMatchIn(out))
        // The whole commented block (image/ports/env lines) of a target is commented, not just header.
        val actualBudgetBlock = out.substringAfter("# actual-budget:").substringBefore("\n  ")
        assertFalse("actual-budget body lines must not stay live",
            Regex("(?m)^    image:").containsMatchIn(actualBudgetBlock))
    }
}
