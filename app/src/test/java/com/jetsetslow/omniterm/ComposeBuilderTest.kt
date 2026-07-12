package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.ui.ComposeServiceDraft
import com.jetsetslow.omniterm.ui.ComposeStackDraft
import com.jetsetslow.omniterm.ui.TopLevelNetworkDraft
import com.jetsetslow.omniterm.ui.composeRawEditsDiffer
import com.jetsetslow.omniterm.ui.generateDockerComposeYaml
import com.jetsetslow.omniterm.ui.parseDockerComposeYaml
import com.jetsetslow.omniterm.ui.renderComposeYaml
import com.jetsetslow.omniterm.ui.validateComposeDraft
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ComposeBuilderTest {

    private val realFile = """
        # Reverse proxy stack
        version: "3.8"

        services:
          web:
            image: nginx:1.24
            container_name: web
            restart: unless-stopped
            ports:
              - "80:80"
              - "443:443"
            depends_on:
              - api
            healthcheck:               # builder does NOT model this
              test: ["CMD", "curl", "-f", "http://localhost"]
              interval: 30s
            deploy:
              resources:
                limits:
                  memory: 256M
          api:
            image: myapi:latest
            environment:
              - NODE_ENV=production
            networks:
              - backend

        networks:
          backend:
            driver: bridge
    """.trimIndent()

    @Test
    fun parses_modeled_fields() {
        val d = parseDockerComposeYaml(realFile, "proxy", "/srv/proxy", "docker-compose.yml")
        assertEquals(2, d.services.size)
        val web = d.services.first { it.serviceName == "web" }
        assertEquals("nginx:1.24", web.image)
        assertEquals("unless-stopped", web.restart)
        assertEquals(listOf("80:80", "443:443"), web.ports)
        assertEquals(listOf("api"), web.dependsOn)
        val api = d.services.first { it.serviceName == "api" }
        assertEquals(listOf("NODE_ENV=production"), api.environment)
    }

    @Test
    fun unchanged_save_is_identical() {
        val baseline = parseDockerComposeYaml(realFile, "proxy", "/srv/proxy")
        // No edits → byte-identical output (the whole point of surgical saving).
        val out = renderComposeYaml(baseline.copy(), baseline)
        assertEquals(realFile, out)
    }

    @Test
    fun editing_image_preserves_everything_else() {
        val baseline = parseDockerComposeYaml(realFile, "proxy", "/srv/proxy")
        val edited = baseline.copy(
            services = baseline.services.map {
                if (it.serviceName == "web") it.copy(image = "nginx:1.25") else it
            }.toMutableList(),
        )
        val out = renderComposeYaml(edited, baseline)

        assertTrue("new image written", out.contains("image: nginx:1.25"))
        assertFalse("old image gone", out.contains("nginx:1.24"))
        // Everything the builder doesn't model must survive verbatim.
        assertTrue(out.contains("healthcheck:"))
        assertTrue(out.contains("""test: ["CMD", "curl", "-f", "http://localhost"]"""))
        assertTrue(out.contains("memory: 256M"))
        assertTrue(out.contains("# Reverse proxy stack"))
        assertTrue(out.contains("driver: bridge"))
    }

    @Test
    fun editing_ports_replaces_only_that_block() {
        val baseline = parseDockerComposeYaml(realFile, "proxy", "/srv/proxy")
        val edited = baseline.copy(
            services = baseline.services.map {
                if (it.serviceName == "web") it.copy(ports = mutableListOf("8080:80")) else it
            }.toMutableList(),
        )
        val out = renderComposeYaml(edited, baseline)
        assertTrue(out.contains("\"8080:80\""))
        assertFalse(out.contains("\"443:443\""))
        // depends_on (which followed ports) must still be intact.
        assertTrue(out.contains("depends_on:"))
        assertTrue(out.contains("- api"))
    }

    @Test
    fun deleting_a_service_removes_its_block_only() {
        val baseline = parseDockerComposeYaml(realFile, "proxy", "/srv/proxy")
        val edited = baseline.copy(
            services = baseline.services.filter { it.serviceName != "api" }.toMutableList(),
        )
        val out = renderComposeYaml(edited, baseline)
        assertFalse("api service removed", out.contains("myapi:latest"))
        assertTrue("web service kept", out.contains("nginx:1.24"))
        assertTrue("top-level networks kept", out.contains("driver: bridge"))
    }

    @Test
    fun commenting_out_a_service_prefixes_its_block() {
        val baseline = parseDockerComposeYaml(realFile, "proxy", "/srv/proxy")
        val edited = baseline.copy(
            services = baseline.services.map {
                if (it.serviceName == "api") it.copy(isCommentedOut = true) else it
            }.toMutableList(),
        )
        val out = renderComposeYaml(edited, baseline)
        // The api block's lines are now commented; web is untouched.
        assertTrue(out.contains("#   image: myapi:latest") || out.contains("# image: myapi:latest"))
        assertTrue(out.contains("image: nginx:1.24"))
        assertFalse(out.contains("\n  image: nginx:1.24".let { "#$it" }))
    }

    @Test
    fun new_stack_generates_valid_structure() {
        val d = com.jetsetslow.omniterm.ui.ComposeStackDraft(
            projectName = "fresh",
            services = mutableListOf(
                ComposeServiceDraft(serviceName = "app", image = "busybox", ports = mutableListOf("9000:9000")),
            ),
        )
        val out = generateDockerComposeYaml(d)
        assertFalse("no obsolete version: key", out.contains("version:"))
        assertTrue(out.startsWith("services:"))
        assertTrue(out.contains("services:"))
        assertTrue(out.contains("  app:"))
        assertTrue(out.contains("image: busybox"))
        assertTrue(out.contains("- \"9000:9000\""))
    }

    @Test
    fun new_top_level_volume_is_inserted_under_existing_header() {
        val yaml = """
            volumes:
              existing:
                external: true

            services:
              app:
                image: busybox
        """.trimIndent()
        val baseline = parseDockerComposeYaml(yaml, "stack")
        val edited = baseline.copy(
            topVolumes = (baseline.topVolumes + com.jetsetslow.omniterm.ui.TopLevelVolumeDraft(name = "newdata")).toMutableList(),
        )
        val out = renderComposeYaml(edited, baseline)
        assertTrue(out.contains("volumes:\n  existing:\n    external: true\n  newdata:\n\nservices:"))
        assertFalse("new volume must not be emitted as a stray key at EOF", out.endsWith("\n  newdata:"))
    }

    @Test
    fun new_top_level_network_is_inserted_under_existing_header() {
        // realFile already has a networks: section with one entry at the bottom.
        val baseline = parseDockerComposeYaml(realFile, "proxy", "/srv/proxy")
        val edited = baseline.copy(
            topNetworks = (baseline.topNetworks + TopLevelNetworkDraft(name = "frontend", driver = "bridge")).toMutableList(),
        )
        val out = renderComposeYaml(edited, baseline)
        assertTrue(
            "new network appended inside the existing networks: section",
            out.contains("networks:\n  backend:\n    driver: bridge\n  frontend:\n    driver: bridge"),
        )
    }

    @Test
    fun new_top_level_network_section_is_appended_after_services() {
        val yaml = """
            services:
              app:
                image: busybox
        """.trimIndent()
        val baseline = parseDockerComposeYaml(yaml, "stack")
        val edited = baseline.copy(
            topNetworks = (baseline.topNetworks + TopLevelNetworkDraft(name = "backend", driver = "bridge")).toMutableList(),
        )
        val out = renderComposeYaml(edited, baseline)
        assertTrue("section comes after the services block", out.indexOf("networks:") > out.indexOf("image: busybox"))
        assertTrue(out.contains("networks:\n  backend:\n    driver: bridge"))
        assertTrue("service block untouched", out.contains("services:\n  app:\n    image: busybox"))
    }

    @Test
    fun raw_to_visual_switch_prompts_only_when_raw_text_was_edited() {
        val baseline = parseDockerComposeYaml(realFile, "proxy", "/srv/proxy")
        // Entering Raw mode seeds the editor with the rendered text, so switching straight
        // back must NOT raise the "Leave Raw YAML?" confirmation.
        assertFalse(composeRawEditsDiffer(realFile, baseline.copy(), baseline))
        // Any raw edit must raise it — that's what protects raw edits from a silent discard.
        assertTrue(composeRawEditsDiffer(realFile + "\n# touched", baseline.copy(), baseline))
    }

    @Test
    fun raw_to_visual_switch_is_clean_for_unedited_new_stack() {
        val d = ComposeStackDraft(
            projectName = "fresh",
            services = mutableListOf(ComposeServiceDraft(serviceName = "app", image = "busybox")),
        )
        val seeded = generateDockerComposeYaml(d)
        assertFalse(composeRawEditsDiffer(seeded, d, null))
        assertTrue(composeRawEditsDiffer(seeded + "\nvolumes:", d, null))
    }

    // Anchors/merge keys, x- extensions, env_file, profiles, labels, block scalars, map-form
    // environment and long-syntax ports are all things the visual builder does NOT model.
    private val gnarlyFile = """
        x-defaults: &defaults
          restart: unless-stopped
          logging:
            driver: json-file

        services:
          app:
            <<: *defaults
            image: app:1.0
            env_file:
              - .env
            profiles:
              - prod
            labels:
              com.example.role: "frontend"
            command: |
              sh -c "
              echo hello
              "
          db:
            image: postgres:16
            environment:
              POSTGRES_DB: app
              POSTGRES_PASSWORD: secret
            ports:
              - target: 5432
                published: 5432
                protocol: tcp
    """.trimIndent()

    @Test
    fun unsupported_yaml_constructs_survive_unchanged_save() {
        val baseline = parseDockerComposeYaml(gnarlyFile, "gnarly", "/srv/gnarly")
        assertEquals(gnarlyFile, renderComposeYaml(baseline.copy(), baseline))
    }

    @Test
    fun unsupported_yaml_constructs_survive_editing_another_field() {
        val baseline = parseDockerComposeYaml(gnarlyFile, "gnarly", "/srv/gnarly")
        val edited = baseline.copy(
            services = baseline.services.map {
                if (it.serviceName == "app") it.copy(image = "app:2.0") else it
            }.toMutableList(),
        )
        val out = renderComposeYaml(edited, baseline)
        assertTrue(out.contains("image: app:2.0"))
        assertFalse(out.contains("app:1.0"))
        listOf(
            "x-defaults: &defaults",
            "<<: *defaults",
            "env_file:",
            "- .env",
            "profiles:",
            "- prod",
            "com.example.role: \"frontend\"",
            "command: |",
            "echo hello",
            "POSTGRES_DB: app",
            "POSTGRES_PASSWORD: secret",
            "- target: 5432",
            "published: 5432",
            "protocol: tcp",
        ).forEach { assertTrue("must preserve: $it", out.contains(it)) }
    }

    @Test
    fun validation_blocks_duplicate_services_and_bad_ports() {
        val d = com.jetsetslow.omniterm.ui.ComposeStackDraft(
            services = mutableListOf(
                ComposeServiceDraft(serviceName = "web", image = "nginx", ports = mutableListOf("8080:80")),
                ComposeServiceDraft(serviceName = "web", image = "", ports = mutableListOf("99999:80")),
            ),
        )
        val issues = validateComposeDraft(d).joinToString("\n")
        assertTrue(issues.contains("Duplicate active service name: web"))
        assertTrue(issues.contains("needs an image"))
        assertTrue(issues.contains("invalid port mapping"))
    }

    @Test
    fun generated_yaml_quotes_values_that_would_be_comments_or_mappings() {
        val d = ComposeStackDraft(
            stackName = "stack",
            services = mutableListOf(
                ComposeServiceDraft(
                    serviceName = "app",
                    image = "busybox",
                    command = "sh -c: echo hi # keep",
                    environment = mutableListOf("TOKEN=abc # not a yaml comment"),
                    ports = mutableListOf("127.0.0.1:8080:80/tcp"),
                ),
            ),
        )
        val out = generateDockerComposeYaml(d)
        assertTrue(out.contains("command: 'sh -c: echo hi # keep'"))
        assertTrue(out.contains("- 'TOKEN=abc # not a yaml comment'"))
        assertTrue(out.contains("- \"127.0.0.1:8080:80/tcp\""))
    }

    @Test
    fun validation_blocks_bad_top_level_volume_and_network_names() {
        val d = ComposeStackDraft(
            services = mutableListOf(ComposeServiceDraft(serviceName = "app", image = "busybox")),
            topVolumes = mutableListOf(
                com.jetsetslow.omniterm.ui.TopLevelVolumeDraft(name = ""),
                com.jetsetslow.omniterm.ui.TopLevelVolumeDraft(name = "bad name"),
            ),
            topNetworks = mutableListOf(
                TopLevelNetworkDraft(name = "front", driver = "bridge", external = true),
                TopLevelNetworkDraft(name = "front"),
            ),
        )
        val issues = validateComposeDraft(d).joinToString("\n")
        assertTrue(issues.contains("Top-level volumes cannot have blank names."))
        assertTrue(issues.contains("Top-level volume has an invalid name: bad name"))
        assertTrue(issues.contains("Duplicate top-level network name: front"))
        assertTrue(issues.contains("front cannot set both external: true and driver."))
    }

    @Test
    fun commented_out_services_do_not_block_visual_validation() {
        val yaml = """
            services:
              app:
                image: busybox
            # broken_old_service:
            #   image:
            #   ports:
            #     - "99999:80"
        """.trimIndent()
        val draft = parseDockerComposeYaml(yaml, "stack")

        assertTrue(draft.services.any { it.serviceName == "broken_old_service" && it.isCommentedOut })
        assertTrue(validateComposeDraft(draft).isEmpty())
    }

    @Test
    fun editing_active_service_preserves_commented_services_and_x_extensions() {
        val yaml = """
            x-common: &common
              restart: unless-stopped

            services:
              app:
                <<: *common
                image: app:1.0
            # old_app:
            #   image: old/app:1.0
            #   ports:
            #     - "99999:80"
        """.trimIndent()
        val baseline = parseDockerComposeYaml(yaml, "stack")
        val edited = baseline.copy(
            services = baseline.services.map {
                if (it.serviceName == "app") it.copy(image = "app:2.0") else it
            }.toMutableList(),
        )

        val out = renderComposeYaml(edited, baseline)
        assertTrue(out.contains("x-common: &common"))
        assertTrue(out.contains("<<: *common"))
        assertTrue(out.contains("image: app:2.0"))
        assertTrue(out.contains("# old_app:"))
        assertTrue(out.contains("#     - \"99999:80\""))
    }
}
