package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.ui.ComposeServiceDraft
import com.jetsetslow.omniterm.ui.ComposeStackDraft
import com.jetsetslow.omniterm.ui.composeDeployDropsServices
import com.jetsetslow.omniterm.ui.parseDockerComposeYaml
import com.jetsetslow.omniterm.ui.reconcileTopLevelVolumes
import com.jetsetslow.omniterm.ui.renderComposeYaml
import com.jetsetslow.omniterm.ui.validateComposeDraft
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Edits that an audit of the visual editor against 2,300 saves of real Compose files found Compose
 * refusing, or saving something other than what the form showed.
 */
class ComposeEditAuditRegressionTest {

    private fun parse(yaml: String) = parseDockerComposeYaml(yaml, "audit", "/srv/audit")

    private fun ComposeStackDraft.editing(name: String, change: (ComposeServiceDraft) -> ComposeServiceDraft) =
        copy(services = services.map { if (it.serviceName == name) change(it) else it }.toMutableList())

    private fun ComposeStackDraft.service(name: String) = services.single { it.serviceName == name }

    @Test
    fun renaming_a_service_saves_the_name_and_every_reference_follows_it() {
        val yaml = """
            services:
              db: &db
                image: postgres:16
              web:
                image: nginx
                depends_on:
                  - db
              worker:
                image: busybox
                depends_on:
                  db:
                    condition: service_healthy
              sidecar:
                image: busybox
                network_mode: "service:db"
              replica:
                extends:
                  service: db
        """.trimIndent()
        val baseline = parse(yaml)
        val renamed = baseline.editing("db") { it.copy(serviceName = "database") }
        assertEquals(emptyList<String>(), validateComposeDraft(renamed, baseline))

        val out = renderComposeYaml(renamed, baseline)
        assertTrue(out, out.contains("\n  database: &db\n"))
        assertTrue(out, out.contains("      - database\n"))
        assertTrue(out, out.contains("      database:\n        condition: service_healthy"))
        assertTrue(out, out.contains("network_mode: \"service:database\""))
        assertTrue(out, out.contains("      service: database"))
        assertFalse(out, Regex("\\bdb\\b").containsMatchIn(out.replace("&db", "")))

        val saved = parse(out)
        assertEquals(listOf("database", "web", "worker", "sidecar", "replica"), saved.services.map { it.serviceName })
        assertEquals(emptyList<String>(), validateComposeDraft(saved))
    }

    @Test
    fun a_key_nested_in_a_block_is_not_a_field_of_the_service() {
        val yaml = """
            services:
              app:
                image: app:1
                depends_on:
                  db:
                    condition: service_started
                    restart: true
              db:
                image: postgres
        """.trimIndent()
        val baseline = parse(yaml)
        assertEquals("", baseline.service("app").restart)

        val out = renderComposeYaml(baseline.editing("app") { it.copy(restart = "always") }, baseline)
        assertTrue(out, out.contains("  app:\n    restart: always\n    image: app:1\n"))
        assertTrue(out, out.contains("        restart: true"))
    }

    @Test
    fun setting_a_command_written_as_a_list_replaces_the_list() {
        val yaml = """
            services:
              prometheus:
                image: prom/prometheus
                command:
                  - '--config.file=/etc/prometheus/prometheus.yml'
                  - '--storage.tsdb.path=/prometheus'
                ports:
                  - 9090:9090
        """.trimIndent()
        val baseline = parse(yaml)
        val out = renderComposeYaml(baseline.editing("prometheus") { it.copy(command = "--web.enable-lifecycle") }, baseline)
        assertEquals(out, 1, Regex("(?m)^\\s*command:").findAll(out).count())
        assertFalse(out, out.contains("--config.file"))
        assertTrue(out, out.contains("    command: --web.enable-lifecycle\n    ports:"))
    }

    @Test
    fun a_text_block_is_text_not_keys_and_an_edit_replaces_it() {
        val yaml = """
            services:
              job:
                image: alpine
                command: >
                  sh -c "echo image: fake
                  && sleep 1"
                restart: "no"
        """.trimIndent()
        val baseline = parse(yaml)
        val job = baseline.service("job")
        assertEquals("alpine", job.image)
        assertEquals("no", job.restart)

        val out = renderComposeYaml(baseline.editing("job") { it.copy(command = "sleep 5") }, baseline)
        assertEquals(
            "services:\n  job:\n    image: alpine\n    command: sleep 5\n    restart: \"no\"",
            out,
        )
    }

    @Test
    fun a_comment_after_a_key_does_not_hide_its_block() {
        val yaml = """
            services: # the stack
              pihole:
                image: pihole/pihole
                volumes: # data that survives upgrades
                  - ./etc-pihole:/etc/pihole
        """.trimIndent()
        val baseline = parse(yaml)
        assertEquals(listOf("./etc-pihole:/etc/pihole"), baseline.service("pihole").volumes)

        val out = renderComposeYaml(
            baseline.editing("pihole") { it.copy(volumes = (it.volumes + "./dnsmasq:/etc/dnsmasq.d").toMutableList()) },
            baseline,
        )
        assertEquals(out, 1, Regex("(?m)^\\s*volumes:").findAll(out).count())
        assertEquals(listOf("./etc-pihole:/etc/pihole", "./dnsmasq:/etc/dnsmasq.d"), parse(out).service("pihole").volumes)
    }

    @Test
    fun a_new_service_takes_the_indentation_of_the_file() {
        val yaml = "services:\n minecraft:\n   image: itzg/minecraft-server\n   ports:\n     - \"25565:25565\"\n"
        val baseline = parse(yaml)
        val added = baseline.copy(
            services = (baseline.services + ComposeServiceDraft(serviceName = "backup", image = "alpine", ports = mutableListOf("8080:80")))
                .toMutableList(),
        )
        val out = renderComposeYaml(added, baseline)
        assertTrue(out, out.contains("\n backup:\n   image: alpine\n   ports:\n     - \"8080:80\""))
        assertEquals(listOf("minecraft", "backup"), parse(out).services.map { it.serviceName })
    }

    @Test
    fun commenting_out_the_only_user_of_a_volume_keeps_the_section_valid_and_reverses_exactly() {
        val yaml = """
            services:
              prometheus:
                image: prom/prometheus
                volumes:
                  - prom_data:/prometheus
              grafana:
                image: grafana/grafana
            volumes:
              prom_data:
        """.trimIndent()
        val baseline = parse(yaml)
        val commented = reconcileTopLevelVolumes(baseline.editing("prometheus") { it.copy(isCommentedOut = true) })
        val out = renderComposeYaml(commented, baseline)
        assertTrue(out, out.contains("\nvolumes: {}\n"))
        assertFalse(out, Regex("(?m)^  prom_data:").containsMatchIn(out))

        val reread = parse(out)
        assertTrue(reread.service("prometheus").isCommentedOut)
        assertEquals(listOf(true), reread.topVolumes.map { it.isCommentedOut })
        val restored = reconcileTopLevelVolumes(reread.editing("prometheus") { it.copy(isCommentedOut = false) })
        assertEquals(yaml, renderComposeYaml(restored, reread))
    }

    @Test
    fun list_rows_are_quoted_when_they_need_it() {
        val yaml = "services:\n  app:\n    image: app\n    environment:\n      - A=1\n"
        val baseline = parse(yaml)
        val out = renderComposeYaml(
            baseline.editing("app") { it.copy(environment = mutableListOf("A=1", "NOTE=see #3", "*glob")) },
            baseline,
        )
        assertTrue(out, out.contains("      - 'NOTE=see #3'\n      - '*glob'"))
        assertEquals(listOf("A=1", "NOTE=see #3", "*glob"), parse(out).service("app").environment)
    }

    @Test
    fun validation_catches_what_compose_refuses() {
        val yaml = """
            services:
              web:
                image: nginx
                depends_on:
                  - api
                networks:
                  - front
                  - front
              api:
                image: api
                network_mode: host
                networks:
                  - back
                depends_on:
                  - web
              cache:
                image: redis
                network_mode: "service:vpn"
              child:
                extends: base
        """.trimIndent()
        val issues = validateComposeDraft(parse(yaml))
        assertTrue(issues.toString(), "web lists front twice under networks." in issues)
        assertTrue(issues.toString(), "api sets both network_mode and networks. Compose allows only one of them." in issues)
        assertTrue(issues.toString(), "cache uses the network of vpn, which this file does not define." in issues)
        assertTrue(issues.toString(), "child extends base, which this file does not define." in issues)
        assertTrue(issues.toString(), issues.any { it.startsWith("Dependency cycle: web → api → web.") })
    }

    @Test
    fun validation_catches_a_dependency_left_dangling_and_a_stack_left_empty() {
        val baseline = parse("services:\n  db:\n    image: postgres\n  web:\n    image: nginx\n    depends_on:\n      db:\n        condition: service_healthy\n")
        val withoutDb = baseline.copy(services = baseline.services.filterNot { it.serviceName == "db" }.toMutableList())
        assertTrue("web depends on db, which this file does not define." in validateComposeDraft(withoutDb, baseline))

        val allCommented = baseline.copy(services = baseline.services.map { it.copy(isCommentedOut = true) }.toMutableList())
        assertTrue(validateComposeDraft(allCommented, baseline).any { it.startsWith("No active services.") })

        // Another -f file of the stack may define the service, so a multi-file stack is not flagged.
        val multiFile = withoutDb.copy(composeConfigFiles = "/srv/audit/compose.yml,/srv/audit/compose.override.yml")
        assertFalse(validateComposeDraft(multiFile, baseline).any { "does not define" in it })
    }

    @Test
    fun links_volumes_from_namespaces_and_flow_extends_follow_a_rename_and_are_checked() {
        val yaml = """
            services:
              service:
                image: postgres
              app:
                image: app
                links:
                  - service:db
                volumes_from:
                  - service:ro
                  - container:legacy
                ipc: service:service
                pid: "service:service"
              copy:
                extends: { service: service }
        """.trimIndent()
        val baseline = parse(yaml)
        val renamed = baseline.editing("service") { it.copy(serviceName = "postgres") }
        assertEquals(emptyList<String>(), validateComposeDraft(renamed, baseline))
        val out = renderComposeYaml(renamed, baseline)
        assertTrue(out, out.contains("      - postgres:db\n"))
        assertTrue(out, out.contains("      - postgres:ro\n      - container:legacy\n"))
        assertTrue(out, out.contains("    ipc: service:postgres\n    pid: \"service:postgres\"\n"))
        assertTrue(out, out.contains("    extends: { service: postgres }"))
        assertEquals(emptyList<String>(), validateComposeDraft(parse(out)))

        val commented = baseline.editing("service") { it.copy(isCommentedOut = true) }
        val issues = validateComposeDraft(commented, baseline)
        for (expected in listOf(
            "app links to service, which is commented out.",
            "app takes volumes from service, which is commented out.",
            "app shares the IPC namespace of service, which is commented out.",
            "app shares the process namespace of service, which is commented out.",
            "copy extends service, which is commented out.",
        )) assertTrue(issues.toString(), expected in issues)
    }

    @Test
    fun a_map_form_environment_is_edited_as_rows_and_saved_as_a_map() {
        val yaml = """
            services:
              mc:
                image: itzg/minecraft-server
                environment:
                  EULA: "TRUE"   # required
                  MEMORY: 2G
                  "discovery.type": single-node
                  PASSTHROUGH:
        """.trimIndent()
        val baseline = parse(yaml)
        assertEquals(listOf("EULA=TRUE", "MEMORY=2G", "discovery.type=single-node", "PASSTHROUGH"), baseline.service("mc").environment)
        assertEquals(emptyList<String>(), validateComposeDraft(baseline))

        val edited = baseline.editing("mc") {
            it.copy(environment = mutableListOf("EULA=TRUE", "MEMORY=4G", "discovery.type=single-node", "PASSTHROUGH", "TZ=Europe/Berlin"))
        }
        val out = renderComposeYaml(edited, baseline)
        assertEquals(
            yaml.replace("      MEMORY: 2G", "      MEMORY: \"4G\"") + "\n      TZ: \"Europe/Berlin\"",
            out,
        )
        assertEquals(edited.service("mc").environment, parse(out).service("mc").environment)

        val twice = baseline.editing("mc") { it.copy(environment = (it.environment + "MEMORY=8G").toMutableList()) }
        assertTrue("mc sets MEMORY twice under environment." in validateComposeDraft(twice))
    }

    @Test
    fun container_names_replicas_and_profiles_are_checked_as_compose_does() {
        val yaml = """
            services:
              worker:
                image: worker
                container_name: worker
                deploy:
                  replicas: 3
              base:
                image: alpine
                container_name: shared
              child:
                extends: base
              api:
                image: api
                depends_on:
                  - debug
              debug:
                image: busybox
                profiles: [debug, tools]
        """.trimIndent()
        val issues = validateComposeDraft(parse(yaml))
        assertTrue(issues.toString(), "worker sets container_name, so it cannot run 3 replicas. Container names must be unique." in issues)
        assertTrue(issues.toString(), "More than one service uses the container name shared." in issues)
        assertTrue(issues.toString(), "api depends on debug, which starts only with the profile debug or tools." in issues)
    }

    @Test
    fun a_map_form_depends_on_is_edited_as_rows_and_keeps_each_condition() {
        val yaml = """
            services:
              db:
                image: postgres
              cache:
                image: redis
              proxy:
                image: nginx
              backend:
                image: backend
                depends_on:
                  db:
                    condition: service_healthy
                    restart: true
                  cache:
                    condition: service_started
        """.trimIndent()
        val baseline = parse(yaml)
        assertEquals(listOf("db", "cache"), baseline.service("backend").dependsOn)

        val edited = baseline.editing("backend") { it.copy(dependsOn = mutableListOf("db", "proxy")) }
            .editing("db") { it.copy(serviceName = "postgres") }
        assertEquals(emptyList<String>(), validateComposeDraft(edited, baseline))
        val out = renderComposeYaml(edited, baseline)
        assertTrue(
            out,
            out.endsWith(
                "    depends_on:\n      postgres:\n        condition: service_healthy\n        restart: true\n" +
                    "      proxy:\n        condition: service_started",
            ),
        )
        assertEquals(listOf("postgres", "proxy"), parse(out).service("backend").dependsOn)
    }

    @Test
    fun commenting_or_renaming_a_top_level_entry_keeps_what_the_builder_does_not_show() {
        val yaml = """
            services:
              app:
                image: app
                networks:
                  - front
            volumes:
              data:
                driver_opts:
                  type: nfs
                  o: addr=10.0.0.2
            networks:
              front:
                ipam:
                  driver: default
                  config:
                    - subnet: 172.28.0.0/16
        """.trimIndent()
        val baseline = parse(yaml)
        // ipam's own driver is not the network's driver.
        assertEquals("", baseline.topNetworks.single().driver)

        val edited = baseline.copy(
            topVolumes = baseline.topVolumes.map { it.copy(isCommentedOut = true) }.toMutableList(),
            topNetworks = baseline.topNetworks.map { it.copy(name = "frontend", driver = "bridge") }.toMutableList(),
            services = baseline.services.map { it.copy(networks = mutableListOf("frontend")) }.toMutableList(),
        )
        val out = renderComposeYaml(edited, baseline)
        assertTrue(out, out.contains("volumes: {}\n#   data:\n#     driver_opts:\n#       type: nfs\n#       o: addr=10.0.0.2\n"))
        assertTrue(out, out.contains("  frontend:\n    driver: bridge\n    ipam:\n      driver: default\n      config:\n        - subnet: 172.28.0.0/16"))

        val reread = parse(out)
        val restored = reread.copy(topVolumes = reread.topVolumes.map { it.copy(isCommentedOut = false) }.toMutableList())
        assertTrue(renderComposeYaml(restored, reread).contains("volumes:\n  data:\n    driver_opts:\n      type: nfs\n      o: addr=10.0.0.2\n"))
    }

    @Test
    fun a_service_using_an_undeclared_volume_or_network_is_flagged() {
        val yaml = """
            services:
              app:
                image: app
                volumes:
                  - data:/data
                  - C:\\docker\\project:/src
                  - ${'$'}{HOST_DIR}:/host
                networks:
                  - default
                  - back
        """.trimIndent()
        val issues = validateComposeDraft(parse(yaml))
        assertTrue(issues.toString(), "app uses the volume data, which the volumes: section does not declare." in issues)
        assertTrue(issues.toString(), "app joins the network back, which the networks: section does not declare." in issues)
        assertEquals(issues.toString(), 2, issues.size)
    }

    @Test
    fun a_deploy_knows_when_it_drops_a_running_service() {
        val yaml = "services:\n  db:\n    image: postgres\n  web:\n    image: nginx\n"
        val baseline = parse(yaml)
        fun dropped(edited: ComposeStackDraft) = composeDeployDropsServices(renderComposeYaml(edited, baseline), baseline)
        assertFalse(dropped(baseline.editing("web") { it.copy(image = "nginx:1.27") }))
        assertTrue(dropped(baseline.editing("db") { it.copy(serviceName = "postgres") }))
        assertTrue(dropped(baseline.editing("db") { it.copy(isCommentedOut = true) }))
        assertTrue(dropped(baseline.copy(services = baseline.services.drop(1).toMutableList())))
        assertFalse("a new stack has nothing running", composeDeployDropsServices(yaml, ComposeStackDraft()))
    }
}
