package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.ui.ComposeServiceDraft
import com.jetsetslow.omniterm.ui.ComposeStackDraft
import com.jetsetslow.omniterm.ui.parseDockerComposeYaml
import com.jetsetslow.omniterm.ui.reconcileTopLevelVolumes
import com.jetsetslow.omniterm.ui.renderComposeYaml
import com.jetsetslow.omniterm.ui.validateComposeDraft
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Drives the whole builder lifecycle — parse, validate, comment out, uncomment, edit, delete, add —
 * over a corpus covering every Compose file format still in the wild (v1, 2.x, 3.x, the Compose
 * Specification and podman-compose's extensions) and the constructs that real published stacks use:
 * YAML anchors and merge keys, anchored service headers, `build:`/`extends:` services, map-form and
 * long-syntax service keys, and environment interpolation.
 *
 * The fixtures are modelled on apache/airflow, getsentry/self-hosted, netbox-community/netbox-docker,
 * immich-app/immich and Freika/dawarich. Each one previously broke the editor in a different way:
 * an anchored header (`netbox: &netbox`) hid the service and promoted its first child key into a
 * service of its own; a merge key (`<<: *base`) read as a missing image; `${VAR}:/data` was declared
 * as a named volume; and rewriting a map-form `environment:` stranded the map under a fresh list.
 */
class ComposeCorpusRegressionTest {

    private fun load(name: String): String =
        javaClass.classLoader!!.getResourceAsStream("compose-corpus/$name")!!
            .bufferedReader().readText()

    /** Every fixture, with the services it must yield and the runtime it belongs to. */
    private data class Fixture(
        val file: String,
        val services: List<String>,
        val runtime: String = "",
        /** Validation issues that are CORRECT for this file as it stands. */
        val expectedIssues: List<String> = emptyList(),
    )

    private val fixtures = listOf(
        Fixture("spec-anchors.yml", listOf("netbox", "netbox-worker", "postgres", "redis")),
        Fixture("v3-swarm.yml", listOf("database", "api")),
        Fixture("v2-legacy.yml", listOf("web", "app", "db")),
        Fixture("podman-rootless.yml", listOf("frontend", "accel", "cache"), runtime = "podman"),
        Fixture("interpolation.yml", listOf("app", "journal")),
        Fixture(
            "v1-legacy.yml",
            emptyList(),
            expectedIssues = listOf(
                "No services: section. This looks like the Compose v1 format, " +
                    "which current Docker/Podman Compose cannot run — convert it in Raw YAML.",
            ),
        ),
    )

    /** Everything the structured editor claims about a service, for "nothing else moved" checks. */
    private fun snapshot(s: ComposeServiceDraft) = listOf(
        s.serviceName, s.image, s.containerName, s.restart, s.command, s.usernsMode,
        s.isCommentedOut.toString(),
        s.ports.toString(), s.environment.toString(), s.volumes.toString(),
        s.networks.toString(), s.dependsOn.toString(),
    ).joinToString("|")

    private fun snapshots(d: ComposeStackDraft) = d.services.associate { it.serviceName to snapshot(it) }

    private fun parse(f: Fixture) = parseDockerComposeYaml(
        load(f.file), "corpus", composeFilePath = "/srv/${f.file}", runtime = f.runtime,
    )

    // ── the corpus parses to exactly the services each file declares ──────────────────────────

    @Test
    fun every_fixture_parses_to_its_declared_services() {
        for (f in fixtures) {
            val draft = parse(f)
            assertEquals(f.file, f.services, draft.services.map { it.serviceName })
            // The netbox cascade: a service key that is really a config key means the indent scale
            // was captured by a service's child instead of the service itself.
            draft.services.forEach {
                assertFalse("${f.file}: '${it.serviceName}' is a config key, not a service", it.serviceName in setOf("depends_on", "healthcheck", "volumes", "command", "environment", "ports"))
            }
        }
    }

    @Test
    fun every_fixture_validates_exactly_as_expected() {
        for (f in fixtures) {
            assertEquals(f.file, f.expectedIssues, validateComposeDraft(parse(f)))
        }
    }

    @Test
    fun no_edit_round_trips_byte_for_byte() {
        for (f in fixtures) {
            val baseline = parse(f)
            assertEquals(f.file, load(f.file), renderComposeYaml(baseline.copy(), baseline))
        }
    }

    // ── commenting out ────────────────────────────────────────────────────────────────────────

    @Test
    fun commenting_out_any_service_leaves_every_other_service_untouched() {
        for (f in fixtures) {
            val baseline = parse(f)
            for (target in baseline.services) {
                val edited = reconcileTopLevelVolumes(
                    baseline.copy(
                        services = baseline.services
                            .map { if (it.id == target.id) it.copy(isCommentedOut = true) else it }
                            .toMutableList(),
                    ),
                )
                val reparsed = parseDockerComposeYaml(renderComposeYaml(edited, baseline), "x", runtime = f.runtime)
                val label = "${f.file}/${target.serviceName}"
                assertEquals(label, f.services, reparsed.services.map { it.serviceName })
                assertEquals(
                    "$label must be the only one commented out",
                    listOf(target.serviceName),
                    reparsed.services.filter { it.isCommentedOut }.map { it.serviceName },
                )
                val before = snapshots(baseline).filterKeys { it != target.serviceName }
                val after = snapshots(reparsed).filterKeys { it != target.serviceName }
                assertEquals(label, before, after)
            }
        }
    }

    @Test
    fun commenting_out_then_back_returns_the_original_model() {
        for (f in fixtures) {
            val baseline = parse(f)
            for (target in baseline.services) {
                val commented = baseline.copy(
                    services = baseline.services
                        .map { if (it.id == target.id) it.copy(isCommentedOut = true) else it }
                        .toMutableList(),
                )
                val afterComment = parseDockerComposeYaml(
                    renderComposeYaml(reconcileTopLevelVolumes(commented), baseline), "x", runtime = f.runtime,
                )
                val back = afterComment.copy(
                    services = afterComment.services
                        .map { if (it.serviceName == target.serviceName) it.copy(isCommentedOut = false) else it }
                        .toMutableList(),
                )
                val restored = parseDockerComposeYaml(
                    renderComposeYaml(reconcileTopLevelVolumes(back), afterComment), "x", runtime = f.runtime,
                )
                assertEquals("${f.file}/${target.serviceName}", snapshots(baseline), snapshots(restored))
            }
        }
    }

    /**
     * A block the author commented out by hand INSIDE a service must stay commented out after the
     * service is toggled off and back on. Uncommenting used to strip the single "#" those lines
     * still carried, resurrecting a disabled env block — secrets and all — at an indent that then
     * swallowed the sibling key above it.
     */
    @Test
    fun a_hand_commented_block_inside_a_service_is_never_resurrected() {
        val f = fixtures.first { it.file == "interpolation.yml" }
        val baseline = parse(f)
        val commented = baseline.copy(
            services = baseline.services
                .map { if (it.serviceName == "journal") it.copy(isCommentedOut = true) else it }
                .toMutableList(),
        )
        val offText = renderComposeYaml(reconcileTopLevelVolumes(commented), baseline)
        val off = parseDockerComposeYaml(offText, "x")
        val backOn = off.copy(
            services = off.services
                .map { if (it.serviceName == "journal") it.copy(isCommentedOut = false) else it }
                .toMutableList(),
        )
        val onText = renderComposeYaml(reconcileTopLevelVolumes(backOn), off)

        assertTrue("the disabled env block must still be a comment", onText.contains("#      - SECRET_KEY=redacted"))
        onText.split("\n").forEach {
            assertFalse("SECRET_KEY must never become live YAML: $it", it.trimStart().startsWith("- SECRET_KEY"))
        }
        val journal = parseDockerComposeYaml(onText, "x").services.first { it.serviceName == "journal" }
        assertEquals(emptyList<String>(), journal.environment)
        assertEquals(listOf("8000:8000"), journal.ports)
    }

    @Test
    fun commenting_out_a_depended_on_service_is_reported() {
        val baseline = parse(fixtures.first { it.file == "v3-swarm.yml" })
        val edited = baseline.copy(
            services = baseline.services
                .map { if (it.serviceName == "database") it.copy(isCommentedOut = true) else it }
                .toMutableList(),
        )
        // `api` reaches `database` through the MAP form of depends_on, which the editable list
        // cannot hold — the dependency is still real and Compose still refuses to start.
        assertTrue(validateComposeDraft(edited).contains("api depends on database, which is commented out."))
    }

    @Test
    fun commenting_out_an_anchor_source_is_reported() {
        val baseline = parse(fixtures.first { it.file == "spec-anchors.yml" })
        val edited = baseline.copy(
            services = baseline.services
                .map { if (it.serviceName == "netbox") it.copy(isCommentedOut = true) else it }
                .toMutableList(),
        )
        assertTrue(
            validateComposeDraft(edited)
                .contains("netbox-worker merges &netbox from netbox, which is commented out."),
        )
    }

    // ── editing ───────────────────────────────────────────────────────────────────────────────

    @Test
    fun editing_one_service_image_moves_nothing_else() {
        for (f in fixtures) {
            val baseline = parse(f)
            for (target in baseline.services) {
                val edited = baseline.copy(
                    services = baseline.services
                        .map { if (it.id == target.id) it.copy(image = "example/replaced:9.9") else it }
                        .toMutableList(),
                )
                val reparsed = parseDockerComposeYaml(renderComposeYaml(edited, baseline), "x", runtime = f.runtime)
                val label = "${f.file}/${target.serviceName}"
                assertEquals(label, f.services, reparsed.services.map { it.serviceName })
                assertEquals(
                    label, "example/replaced:9.9",
                    reparsed.services.first { it.serviceName == target.serviceName }.image,
                )
                assertEquals(
                    label,
                    snapshots(baseline).filterKeys { it != target.serviceName },
                    snapshots(reparsed).filterKeys { it != target.serviceName },
                )
            }
        }
    }

    @Test
    fun editing_ports_rewrites_only_that_block() {
        val f = fixtures.first { it.file == "interpolation.yml" }
        val baseline = parse(f)
        val edited = baseline.copy(
            services = baseline.services
                .map { if (it.serviceName == "journal") it.copy(ports = mutableListOf("9000:8000")) else it }
                .toMutableList(),
        )
        val out = renderComposeYaml(edited, baseline)
        val reparsed = parseDockerComposeYaml(out, "x")
        assertEquals(listOf("9000:8000"), reparsed.services.first { it.serviceName == "journal" }.ports)
        // The other service's interpolated rows and their trailing comments survive verbatim.
        assertTrue(out.contains("      - \"\${PROMETHEUS_PORT:-9394}:9394\" # exporter, uncomment if needed"))
        assertEquals(
            snapshots(baseline).filterKeys { it != "journal" },
            snapshots(reparsed).filterKeys { it != "journal" },
        )
    }

    @Test
    fun map_and_long_form_keys_are_never_rewritten_in_place() {
        val f = fixtures.first { it.file == "v3-swarm.yml" }
        val baseline = parse(f)
        val database = baseline.services.first { it.serviceName == "database" }
        // Long-syntax ports and a map-form environment are surfaced as empty, not as bogus rows.
        assertEquals(emptyList<String>(), database.ports)
        assertEquals(emptyList<String>(), database.environment)

        // Rows typed into them are reported and dropped, rather than spliced over the real block.
        val edited = baseline.copy(
            services = baseline.services.map {
                if (it.serviceName == "database") {
                    it.copy(environment = mutableListOf("EXTRA=1"), ports = mutableListOf("15432:5432"))
                } else {
                    it
                }
            }.toMutableList(),
        )
        val issues = validateComposeDraft(edited)
        assertTrue(issues.any { it.startsWith("database declares environment in map or long syntax") })
        assertTrue(issues.any { it.startsWith("database declares ports in map or long syntax") })
        val out = renderComposeYaml(edited, baseline)
        assertEquals(load(f.file), out)
    }

    // ── deleting and adding ───────────────────────────────────────────────────────────────────

    @Test
    fun deleting_any_service_leaves_every_other_service_untouched() {
        for (f in fixtures) {
            val baseline = parse(f)
            for (target in baseline.services) {
                val edited = reconcileTopLevelVolumes(
                    baseline.copy(services = baseline.services.filter { it.id != target.id }.toMutableList()),
                )
                val reparsed = parseDockerComposeYaml(renderComposeYaml(edited, baseline), "x", runtime = f.runtime)
                val label = "${f.file}/${target.serviceName}"
                assertEquals(label, f.services - target.serviceName, reparsed.services.map { it.serviceName })
                assertEquals(
                    label,
                    snapshots(baseline).filterKeys { it != target.serviceName },
                    snapshots(reparsed).filterKeys { it != target.serviceName },
                )
            }
        }
    }

    @Test
    fun adding_a_service_appends_it_without_disturbing_the_file() {
        for (f in fixtures.filter { it.services.isNotEmpty() }) {
            val baseline = parse(f)
            val added = ComposeServiceDraft(
                serviceName = "brand-new",
                image = "busybox:1.36",
                ports = mutableListOf("7070:7070"),
            )
            val edited = reconcileTopLevelVolumes(
                baseline.copy(services = (baseline.services + added).toMutableList()),
            )
            val reparsed = parseDockerComposeYaml(renderComposeYaml(edited, baseline), "x", runtime = f.runtime)
            assertEquals(f.file, f.services + "brand-new", reparsed.services.map { it.serviceName })
            assertEquals(
                f.file,
                snapshots(baseline),
                snapshots(reparsed).filterKeys { it != "brand-new" },
            )
            assertEquals(f.file, emptyList<String>(), validateComposeDraft(edited))
        }
    }

    /**
     * A blank starter row belongs to a NEW stack. Seeding one into a file that merely lacks a
     * `services:` section invented a service the file never had — and saving would have written it.
     */
    @Test
    fun a_file_without_a_services_section_gains_no_phantom_service() {
        val f = fixtures.first { it.file == "v1-legacy.yml" }
        val baseline = parse(f)
        assertEquals(emptyList<String>(), baseline.services.map { it.serviceName })
        assertFalse(baseline.hasServicesSection)
        assertEquals(load(f.file), renderComposeYaml(baseline.copy(), baseline))
    }
}
