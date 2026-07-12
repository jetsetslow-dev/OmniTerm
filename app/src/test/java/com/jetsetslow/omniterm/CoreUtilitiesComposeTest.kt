package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.ui.parseDockerComposeYaml
import com.jetsetslow.omniterm.ui.renderComposeYaml
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Uses a synthetic core_utilities stack: a messy file with
 * pre-commented services, malformed lines, no top-level name, and services without images.
 * Pins the comment-out toggle (the reported bug) end to end.
 */
class CoreUtilitiesComposeTest {

    private fun load(): String =
        javaClass.classLoader!!.getResourceAsStream("core_utilities.yml")!!
            .bufferedReader().readText()

    @Test
    fun parses_all_services_with_correct_comment_state() {
        val d = parseDockerComposeYaml(load(), "core_utilities", "/home/ubuntu/core_utilities")
        val names = d.services.map { it.serviceName }
        // The active services we expect to find and be able to comment out:
        for (n in listOf("hawser", "parser-service", "actual-sync", "ollama", "model-loader", "actual-budget")) {
            assertTrue("expected service '$n' parsed; got $names", names.contains(n))
        }
        assertTrue(d.services.single { it.serviceName == "archived-ui" }.isCommentedOut)
    }

    @Test
    fun commenting_out_services_reflects_in_output() {
        val baseline = parseDockerComposeYaml(load(), "core_utilities", "/home/ubuntu/core_utilities")
        val targets = setOf("actual-budget", "parser-service", "actual-sync", "ollama", "model-loader")
        val edited = baseline.copy(
            services = baseline.services.map {
                if (it.serviceName in targets) it.copy(isCommentedOut = true) else it
            }.toMutableList(),
        )
        val out = renderComposeYaml(edited, baseline)

        // Each targeted service's header line must now be commented.
        for (n in targets) {
            assertTrue(
                "service '$n' header should be commented in output",
                out.contains("# $n:") || out.contains("#  $n:") || out.contains("#$n:"),
            )
            // And its original uncommented header must be gone.
            assertFalse("uncommented '$n:' should not remain", Regex("(?m)^  $n:").containsMatchIn(out))
        }
        // A non-targeted service stays uncommented.
        assertTrue("hawser stays active", Regex("(?m)^  hawser:").containsMatchIn(out))
        assertTrue("extension field preserved", out.contains("x-defaults: &defaults"))
        assertTrue("unknown field preserved", out.contains("x-unknown-field: preserved"))
        assertTrue("malformed line preserved", out.contains("deliberately malformed fixture line"))
        assertTrue("pre-commented block preserved", out.contains("#  archived-ui:"))
    }

    @Test
    fun no_edits_is_byte_identical() {
        val baseline = parseDockerComposeYaml(load(), "core_utilities", "/home/ubuntu/core_utilities")
        val out = renderComposeYaml(baseline.copy(), baseline)
        assertEquals(load(), out)
    }

    @Test
    fun adding_stack_name_inserts_it_before_services() {
        val baseline = parseDockerComposeYaml(load(), "core_utilities", "/home/ubuntu/core_utilities")
        assertEquals("", baseline.stackName)  // this file has no top-level name:
        val edited = baseline.copy(stackName = "core_utilities")
        val out = renderComposeYaml(edited, baseline)
        assertTrue("name: line added", out.contains("name: core_utilities"))
        // It must sit before services: and not disturb the rest.
        val nameIdx = out.split("\n").indexOfFirst { it.trim() == "name: core_utilities" }
        val svcIdx = out.split("\n").indexOfFirst { it.trim() == "services:" }
        assertTrue("name before services", nameIdx in 0 until svcIdx)
        assertTrue("services preserved", out.contains("  hawser:"))
    }

    @Test
    fun parses_and_preserves_existing_stack_name() {
        val withName = "name: core_utilities\nservices:\n  web:\n    image: nginx\n"
        val d = parseDockerComposeYaml(withName, "proj")
        assertEquals("core_utilities", d.stackName)
        // unchanged round-trip is identical
        assertEquals(withName, renderComposeYaml(d.copy(), d))
        // renaming rewrites only that line
        val renamed = renderComposeYaml(d.copy(stackName = "newname"), d)
        assertTrue(renamed.contains("name: newname"))
        assertFalse(renamed.contains("core_utilities"))
        assertTrue(renamed.contains("  web:"))
    }
}
