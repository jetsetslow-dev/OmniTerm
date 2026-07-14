package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.ui.parseDockerComposeYaml
import com.jetsetslow.omniterm.ui.renderComposeYaml
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A synthetic indentation fixture with services commented out by hand in three
 * different styles ("#  admin-ui:", "# metrics-agent:", "  # web-a:", "#   database:"),
 * plus manually commented top-level volumes ("  # dns_cache:"). Pins the regression where
 * everything commented below a live service was absorbed into that service's source span, so
 * editing/deleting/toggling the live service destroyed the commented blocks — and the volumes
 * section lost all its live entries to the same indent confusion.
 */
class ComposeIndentationRegressionTest {

    private fun load(): String =
        javaClass.classLoader!!.getResourceAsStream("compose_indentation_fixture.yml")!!
            .bufferedReader().readText()

    private val liveServices = listOf(
        "primary-api", "edge-agent", "code-editor", "secure-tunnel",
        "mesh-agent", "reverse-proxy", "file-browser",
    )
    private val commentedServices = listOf(
        "admin-ui", "metrics-agent", "device-bridge", "web-a", "web-b",
        "database", "workflow-engine", "model-runtime", "model-loader", "db-init", "dns-helper",
    )

    @Test
    fun parses_live_and_manually_commented_services() {
        val d = parseDockerComposeYaml(load(), "indentation_fixture", "/srv/fixtures/indentation")
        val byName = d.services.associateBy { it.serviceName }
        for (n in liveServices) {
            assertTrue("live service '$n' parsed", byName.containsKey(n))
            assertFalse("'$n' must be live", byName.getValue(n).isCommentedOut)
        }
        for (n in commentedServices) {
            assertTrue("commented service '$n' parsed; got ${byName.keys}", byName.containsKey(n))
            assertTrue("'$n' must be commented", byName.getValue(n).isCommentedOut)
        }
        // Spot-check fields seen through the comment prefix.
        assertEquals("registry.example.invalid/admin-ui:1.0", byName.getValue("admin-ui").image)
        assertEquals(listOf("8081:80"), byName.getValue("web-a").ports)
        assertEquals("registry.example.invalid/database:1.0", byName.getValue("database").image)
    }

    @Test
    fun live_service_span_excludes_trailing_commented_blocks() {
        val d = parseDockerComposeYaml(load(), "indentation_fixture", "/srv/fixtures/indentation")
        val lines = load().split("\n")
        for (n in liveServices) {
            val svc = d.services.first { it.serviceName == n }
            val lastLine = lines[svc.srcEnd]
            assertFalse(
                "'$n' span must end on its own line, not a comment (ends on: '$lastLine')",
                lastLine.trimStart().startsWith("#"),
            )
        }
    }

    @Test
    fun editing_a_live_service_preserves_commented_blocks_below_it() {
        val baseline = parseDockerComposeYaml(load(), "indentation_fixture", "/srv/fixtures/indentation")
        val edited = baseline.copy(
            services = baseline.services.map {
                if (it.serviceName == "file-browser") it.copy(restart = "unless-stopped") else it
            }.toMutableList(),
        )
        val out = renderComposeYaml(edited, baseline)
        assertTrue(out.contains("restart: unless-stopped"))
        // The hand-commented web/database blocks below file-browser survive verbatim.
        assertTrue(out.contains("  # web-a:"))
        assertTrue(out.contains("  # web-b:"))
        assertTrue(out.contains("#   database:"))
        assertTrue(out.contains("#     image: registry.example.invalid/database:1.0"))
    }

    @Test
    fun deleting_a_live_service_keeps_commented_blocks_below_it() {
        val baseline = parseDockerComposeYaml(load(), "indentation_fixture", "/srv/fixtures/indentation")
        val edited = baseline.copy(
            services = baseline.services.filter { it.serviceName != "file-browser" }.toMutableList(),
        )
        val out = renderComposeYaml(edited, baseline)
        assertFalse("file-browser removed", out.contains("registry.example.invalid/file-browser:1.0"))
        assertTrue("commented web-a survives", out.contains("  # web-a:"))
        assertTrue("commented database survives", out.contains("#   database:"))
    }

    @Test
    fun commenting_a_live_service_does_not_touch_blocks_below_it() {
        val baseline = parseDockerComposeYaml(load(), "indentation_fixture", "/srv/fixtures/indentation")
        val edited = baseline.copy(
            services = baseline.services.map {
                if (it.serviceName == "file-browser") it.copy(isCommentedOut = true) else it
            }.toMutableList(),
        )
        val out = renderComposeYaml(edited, baseline)
        assertFalse(Regex("(?m)^  file-browser:").containsMatchIn(out))
        assertTrue(Regex("(?m)^#\\s*file-browser:").containsMatchIn(out))
        // The blocks below must keep their original single comment prefix — not gain another.
        assertTrue(out.contains("  # web-a:"))
        assertFalse("web-a must not be double-commented", out.contains("# # web-a:"))
        assertFalse(out.contains("#   # web-a:"))
    }

    @Test
    fun uncommenting_a_manually_commented_service_yields_consistent_indents() {
        val baseline = parseDockerComposeYaml(load(), "indentation_fixture", "/srv/fixtures/indentation")
        // device-bridge was commented by hand with deliberately skewed indents.
        val edited = baseline.copy(
            services = baseline.services.map {
                if (it.serviceName == "device-bridge") it.copy(isCommentedOut = false) else it
            }.toMutableList(),
        )
        val out = renderComposeYaml(edited, baseline)
        // Header lands on the canonical 2-space service column, body on 4 — same as siblings.
        assertTrue("header at service column", Regex("(?m)^  device-bridge:$").containsMatchIn(out))
        assertTrue("body at field column", Regex("(?m)^    image: registry\\.example\\.invalid/device-bridge:1\\.0$").containsMatchIn(out))
        assertTrue(Regex("(?m)^    ports:$").containsMatchIn(out))
        assertTrue(Regex("(?m)^      - 444:443$").containsMatchIn(out))
        // Re-parsing the output must see device-bridge as a live sibling.
        val reparsed = parseDockerComposeYaml(out, "indentation_fixture")
        val deviceBridge = reparsed.services.first { it.serviceName == "device-bridge" }
        assertFalse(deviceBridge.isCommentedOut)
        assertEquals("registry.example.invalid/device-bridge:1.0", deviceBridge.image)
    }

    @Test
    fun volumes_section_keeps_live_entries_despite_leading_commented_entry() {
        val d = parseDockerComposeYaml(load(), "indentation_fixture", "/srv/fixtures/indentation")
        val vols = d.topVolumes.associateBy { it.name }
        // The section starts with "  # dns_cache:", which used to hijack the indent scale
        // and absorb every live volume below it.
        for (n in listOf("bridge_data", "bridge_model", "api_data")) {
            assertTrue("live volume '$n' parsed; got ${vols.keys}", vols.containsKey(n))
            assertFalse("'$n' must be live", vols.getValue(n).isCommentedOut)
        }
        for (n in listOf("dns_cache", "database_data", "workflow_data")) {
            assertTrue("commented volume '$n' parsed", vols.containsKey(n))
            assertTrue("'$n' must be commented", vols.getValue(n).isCommentedOut)
        }
        val nets = d.topNetworks.associateBy { it.name }
        assertTrue(nets.containsKey("fixture_network"))
        assertTrue(nets.getValue("fixture_network").external)
    }

    @Test
    fun no_edits_is_byte_identical() {
        val baseline = parseDockerComposeYaml(load(), "indentation_fixture", "/srv/fixtures/indentation")
        assertEquals(load(), renderComposeYaml(baseline.copy(), baseline))
    }
}
