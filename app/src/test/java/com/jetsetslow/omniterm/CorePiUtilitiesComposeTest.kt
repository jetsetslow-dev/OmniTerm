package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.ui.parseDockerComposeYaml
import com.jetsetslow.omniterm.ui.renderComposeYaml
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The Core_Utilities stack running on the Pi host: services commented out BY HAND in three
 * different styles ("#  portainer:", "# portainer_agent:", "  # webserver1:", "#   postgres:"),
 * plus manually commented top-level volumes ("  # dockflare_data:"). Pins the reported bug:
 * everything commented below a live service was absorbed into that service's source span, so
 * editing/deleting/toggling the live service destroyed the commented blocks — and the volumes
 * section lost all its live entries to the same indent confusion.
 */
class CorePiUtilitiesComposeTest {

    private fun load(): String =
        javaClass.classLoader!!.getResourceAsStream("core_pi_utilities.yml")!!
            .bufferedReader().readText()

    private val liveServices = listOf(
        "dockhand", "newt", "code-server", "cloudflared_tunnel",
        "tailscale", "nginx-proxy-manager", "filebrowser",
    )
    private val commentedServices = listOf(
        "portainer", "portainer_agent", "wire-pod", "webserver1", "webserver2",
        "postgres", "n8n", "ollama", "model-loader", "db-init", "dockflare",
    )

    @Test
    fun parses_live_and_manually_commented_services() {
        val d = parseDockerComposeYaml(load(), "Core_Utilities", "/home/user/docker/Core_Utilities")
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
        assertEquals("portainer/portainer-ee:latest", byName.getValue("portainer").image)
        assertEquals(listOf("8081:80"), byName.getValue("webserver1").ports)
        assertEquals("postgres:16", byName.getValue("postgres").image)
    }

    @Test
    fun live_service_span_excludes_trailing_commented_blocks() {
        val d = parseDockerComposeYaml(load(), "Core_Utilities", "/home/user/docker/Core_Utilities")
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
        val baseline = parseDockerComposeYaml(load(), "Core_Utilities", "/home/user/docker/Core_Utilities")
        val edited = baseline.copy(
            services = baseline.services.map {
                if (it.serviceName == "filebrowser") it.copy(restart = "unless-stopped") else it
            }.toMutableList(),
        )
        val out = renderComposeYaml(edited, baseline)
        assertTrue(out.contains("restart: unless-stopped"))
        // The hand-commented webserver/postgres blocks below filebrowser survive verbatim.
        assertTrue(out.contains("  # webserver1:"))
        assertTrue(out.contains("  # webserver2:"))
        assertTrue(out.contains("#   postgres:"))
        assertTrue(out.contains("#     image: postgres:16"))
    }

    @Test
    fun deleting_a_live_service_keeps_commented_blocks_below_it() {
        val baseline = parseDockerComposeYaml(load(), "Core_Utilities", "/home/user/docker/Core_Utilities")
        val edited = baseline.copy(
            services = baseline.services.filter { it.serviceName != "filebrowser" }.toMutableList(),
        )
        val out = renderComposeYaml(edited, baseline)
        assertFalse("filebrowser removed", out.contains("filebrowser/filebrowser"))
        assertTrue("commented webserver1 survives", out.contains("  # webserver1:"))
        assertTrue("commented postgres survives", out.contains("#   postgres:"))
    }

    @Test
    fun commenting_a_live_service_does_not_touch_blocks_below_it() {
        val baseline = parseDockerComposeYaml(load(), "Core_Utilities", "/home/user/docker/Core_Utilities")
        val edited = baseline.copy(
            services = baseline.services.map {
                if (it.serviceName == "filebrowser") it.copy(isCommentedOut = true) else it
            }.toMutableList(),
        )
        val out = renderComposeYaml(edited, baseline)
        assertFalse(Regex("(?m)^  filebrowser:").containsMatchIn(out))
        assertTrue(Regex("(?m)^#\\s*filebrowser:").containsMatchIn(out))
        // The blocks below must keep their original single comment prefix — not gain another.
        assertTrue(out.contains("  # webserver1:"))
        assertFalse("webserver1 must not be double-commented", out.contains("# # webserver1:"))
        assertFalse(out.contains("#   # webserver1:"))
    }

    @Test
    fun uncommenting_a_manually_commented_service_yields_consistent_indents() {
        val baseline = parseDockerComposeYaml(load(), "Core_Utilities", "/home/user/docker/Core_Utilities")
        // wire-pod was commented by hand as "#  wire-pod:" / "#    image: ..." (skewed indents).
        val edited = baseline.copy(
            services = baseline.services.map {
                if (it.serviceName == "wire-pod") it.copy(isCommentedOut = false) else it
            }.toMutableList(),
        )
        val out = renderComposeYaml(edited, baseline)
        // Header lands on the canonical 2-space service column, body on 4 — same as siblings.
        assertTrue("header at service column", Regex("(?m)^  wire-pod:$").containsMatchIn(out))
        assertTrue("body at field column", Regex("(?m)^    image: ghcr\\.io/kercre123/wire-pod:main$").containsMatchIn(out))
        assertTrue(Regex("(?m)^    ports:$").containsMatchIn(out))
        assertTrue(Regex("(?m)^      - 444:443$").containsMatchIn(out))
        // Re-parsing the output must see wire-pod as a live sibling of tailscale.
        val reparsed = parseDockerComposeYaml(out, "Core_Utilities")
        val wirePod = reparsed.services.first { it.serviceName == "wire-pod" }
        assertFalse(wirePod.isCommentedOut)
        assertEquals("ghcr.io/kercre123/wire-pod:main", wirePod.image)
    }

    @Test
    fun volumes_section_keeps_live_entries_despite_leading_commented_entry() {
        val d = parseDockerComposeYaml(load(), "Core_Utilities", "/home/user/docker/Core_Utilities")
        val vols = d.topVolumes.associateBy { it.name }
        // The section STARTS with "  # dockflare_data:", which used to hijack the indent scale
        // and absorb every live volume below it.
        for (n in listOf("wire-pod-data", "wire-pod-model", "dockhand_data")) {
            assertTrue("live volume '$n' parsed; got ${vols.keys}", vols.containsKey(n))
            assertFalse("'$n' must be live", vols.getValue(n).isCommentedOut)
        }
        for (n in listOf("dockflare_data", "db_storage", "n8n_storage")) {
            assertTrue("commented volume '$n' parsed", vols.containsKey(n))
            assertTrue("'$n' must be commented", vols.getValue(n).isCommentedOut)
        }
        val nets = d.topNetworks.associateBy { it.name }
        assertTrue(nets.containsKey("home_network"))
        assertTrue(nets.getValue("home_network").external)
    }

    @Test
    fun no_edits_is_byte_identical() {
        val baseline = parseDockerComposeYaml(load(), "Core_Utilities", "/home/user/docker/Core_Utilities")
        assertEquals(load(), renderComposeYaml(baseline.copy(), baseline))
    }
}
