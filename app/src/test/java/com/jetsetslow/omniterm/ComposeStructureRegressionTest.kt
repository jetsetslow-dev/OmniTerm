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
class ComposeStructureRegressionTest {

    private fun load(): String =
        javaClass.classLoader!!.getResourceAsStream("compose_structure_fixture.yml")!!
            .bufferedReader().readText()

    @Test
    fun parses_name_and_all_services() {
        val d = parseDockerComposeYaml(load(), "structure_fixture", "/srv/fixtures/structure")
        assertEquals("structure_fixture", d.stackName)
        val names = d.services.map { it.serviceName }
        for (n in listOf("frontend", "worker", "local-builder", "sync-service", "model-runtime", "model-loader", "budget-service")) {
            assertTrue("expected '$n' in $names", names.contains(n))
        }
    }

    @Test
    fun unchanged_is_byte_identical() {
        val baseline = parseDockerComposeYaml(load(), "structure_fixture", "/srv/fixtures/structure")
        assertEquals(load(), renderComposeYaml(baseline.copy(), baseline))
    }

    @Test
    fun comments_selected_services() {
        val baseline = parseDockerComposeYaml(load(), "structure_fixture", "/srv/fixtures/structure")
        val targets = setOf("budget-service", "frontend", "local-builder", "sync-service", "model-runtime", "model-loader")
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
        assertTrue(out.contains("name: structure_fixture"))
        assertTrue(Regex("(?m)^  worker:").containsMatchIn(out))
        assertTrue(Regex("(?m)^  notes-service:").containsMatchIn(out))
        // The whole commented block (image/ports/env lines) of a target is commented, not just header.
        val budgetBlock = out.substringAfter("# budget-service:").substringBefore("\n  ")
        assertFalse("budget-service body lines must not stay live",
            Regex("(?m)^    image:").containsMatchIn(budgetBlock))
    }
}
