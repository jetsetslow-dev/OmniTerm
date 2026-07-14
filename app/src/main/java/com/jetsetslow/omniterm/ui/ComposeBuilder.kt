package com.jetsetslow.omniterm.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Error
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.Fullscreen
import androidx.compose.material3.*
import androidx.activity.compose.BackHandler
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.jetsetslow.omniterm.ui.theme.OmniColors
import com.jetsetslow.omniterm.ui.theme.OmniFonts
import java.util.UUID

// ─────────────────────────────────────────────────────────────────────────────
// Model
//
// The builder edits two kinds of stack:
//   • NEW stacks created from scratch — there is no original file, so the whole
//     docker-compose.yml is generated from the structured model.
//   • EXISTING stacks opened via "Edit in Builder" — these carry [originalText],
//     the file exactly as read. Saving such a stack performs a SURGICAL splice:
//     only the fields the user actually changed are rewritten in place; every
//     other line (depends_on, healthcheck, deploy, anchors, comments, blank
//     lines, top-level volumes/networks…) is preserved byte-for-byte. A field's
//     location in the original is captured in [ComposeServiceDraft] line indices.
//
// A "Raw YAML" toggle is always available as the lossless escape hatch for files
// the structured editor cannot fully represent (anchors/aliases, flow style, …).
// ─────────────────────────────────────────────────────────────────────────────

data class ComposeServiceDraft(
    val id: String = UUID.randomUUID().toString(),
    var serviceName: String = "app",
    var image: String = "",
    var containerName: String = "",
    var restart: String = "",
    var command: String = "",
    var isCommentedOut: Boolean = false,
    var isExpanded: Boolean = true,
    val ports: MutableList<String> = mutableListOf(),
    val environment: MutableList<String> = mutableListOf(),
    val volumes: MutableList<String> = mutableListOf(),
    val networks: MutableList<String> = mutableListOf(),
    val dependsOn: MutableList<String> = mutableListOf(),
    // ── source mapping (existing-file edits only; -1 when synthesised) ──
    // The inclusive [start, end] line range this service block occupies in the
    // original file, the service's body indent, and the line index of each
    // scalar/array key so surgical splicing can find exactly what to replace.
    var srcStart: Int = -1,
    var srcEnd: Int = -1,
    var bodyIndent: Int = -1,
    val scalarLine: MutableMap<String, Int> = mutableMapOf(),
    val arraySpan: MutableMap<String, IntRange> = mutableMapOf(),
)

data class TopLevelVolumeDraft(
    val id: String = UUID.randomUUID().toString(),
    var name: String = "",
    var external: Boolean = false,
    var isCommentedOut: Boolean = false,
    // Source line range in the original file (-1 = synthesised / not yet on disk).
    var srcStart: Int = -1,
    var srcEnd: Int = -1,
)

data class TopLevelNetworkDraft(
    val id: String = UUID.randomUUID().toString(),
    var name: String = "",
    var driver: String = "",        // bridge | overlay | host | macvlan | …
    var external: Boolean = false,
    var isCommentedOut: Boolean = false,
    var srcStart: Int = -1,
    var srcEnd: Int = -1,
)

data class ComposeStackDraft(
    var projectName: String = "my_stack",
    // The compose top-level `name:` key (the Compose project name written INTO the file, e.g.
    // `name: example_stack`). Distinct from [projectName], which is the deploy directory / `-p`
    // flag. Blank means no `name:` line is written. On an existing file, -1 srcLine means it had none.
    var stackName: String = "",
    var stackNameSrcLine: Int = -1,
    val services: MutableList<ComposeServiceDraft> = mutableListOf(ComposeServiceDraft()),
    val topVolumes: MutableList<TopLevelVolumeDraft> = mutableListOf(),
    val topNetworks: MutableList<TopLevelNetworkDraft> = mutableListOf(),
    // Line index of the top-level `volumes:` / `networks:` header in the original file (-1 = absent).
    var volumesSrcHeader: Int = -1,
    var networksSrcHeader: Int = -1,
    // Non-null when editing a real on-disk file. Drives surgical (non-destructive) saves.
    var originalText: String? = null,
    // Absolute working directory of the stack being edited (empty for brand-new drafts).
    var workingDir: String = "",
    // Compose file name (defaults to docker-compose.yml; preserves a non-standard name on edit).
    var fileName: String = "docker-compose.yml",
    // ABSOLUTE path to the compose file. For an existing stack this is the exact file Docker
    // reported as running (so we never edit the wrong copy of a same-named stack); empty for new
    // drafts, where it's computed from the deploy directory + fileName at deploy time.
    var composeFilePath: String = "",
    // Comma-separated config file list reported by Compose labels. Existing stacks can be built
    // from multiple -f files; deploy must validate/up with the same chain while replacing only the
    // file being edited.
    var composeConfigFiles: String = "",
    // Container runtime that owns this stack: "docker", "podman", or blank for auto/new drafts.
    var runtime: String = "",
)

private fun String.unquoteYaml(): String =
    trim().removeSurrounding("\"").removeSurrounding("'")

private fun indentOfLine(s: String): Int = s.takeWhile { it == ' ' }.length

// Strip a trailing inline YAML comment (" #...") from a scalar value. Only fires when " #"
// appears after at least one non-space character AND the text after "#" doesn't look like an
// intentional value fragment (i.e. it's not "KEY=#value" style). This keeps env-var defaults
// like "${FOO:-#nope}" intact while removing cosmetic comments like "image: foo:1.0 #old".
private fun String.stripYamlInlineComment(): String {
    val ci = indexOf(" #")
    return if (ci > 0) substring(0, ci).trimEnd() else this
}

private fun isValidComposeName(value: String): Boolean =
    value.matches(Regex("""[A-Za-z0-9][A-Za-z0-9_.-]*"""))

private fun yamlPlainOrSingleQuoted(value: String): String {
    val trimmed = value.trim()
    if (trimmed.isEmpty()) return "''"
    val risky = trimmed.any { it == '\n' || it == '\r' || it == '\t' } ||
        trimmed.startsWith("#") || trimmed.startsWith("- ") || trimmed.startsWith("? ") ||
        trimmed.startsWith(": ") || trimmed.startsWith("{") || trimmed.startsWith("[") ||
        trimmed.startsWith("&") || trimmed.startsWith("*") || trimmed.startsWith("!") ||
        trimmed.startsWith("|") || trimmed.startsWith(">") || trimmed.startsWith("@") ||
        trimmed.startsWith("`") || trimmed.equals("null", ignoreCase = true) ||
        trimmed.equals("true", ignoreCase = true) || trimmed.equals("false", ignoreCase = true) ||
        trimmed.contains(" #") || trimmed.contains(": ") || trimmed.endsWith(":")
    return if (risky) "'${trimmed.replace("'", "''")}'" else trimmed
}

private fun yamlDoubleQuoted(value: String): String =
    "\"" + value.replace("\\", "\\\\").replace("\"", "\\\"") + "\""

// Keys that can appear directly under a service definition (Compose spec). Used to tell a
// commented-out service HEADER apart from a commented-out config block at a similar effective
// indent (manual comment styles shift the see-through indent by 1-2 columns, so indent alone
// can't discriminate "#   postgres:" from "  # ports:").
private val SERVICE_CONFIG_KEYS = setOf(
    "annotations", "attach", "blkio_config", "build", "cap_add", "cap_drop", "cgroup",
    "cgroup_parent", "command", "configs", "container_name", "cpu_count", "cpu_percent",
    "cpu_period", "cpu_quota", "cpu_rt_period", "cpu_rt_runtime", "cpu_shares", "cpus", "cpuset",
    "credential_spec", "depends_on", "deploy", "develop", "device_cgroup_rules", "devices", "dns",
    "dns_opt", "dns_search", "domainname", "entrypoint", "env_file", "environment", "expose",
    "extends", "external_links", "extra_hosts", "gpus", "group_add", "healthcheck", "hostname",
    "image", "init", "ipc", "isolation", "labels", "links", "logging", "mac_address", "mem_limit",
    "mem_reservation", "mem_swappiness", "memswap_limit", "network_mode", "networks",
    "oom_kill_disable", "oom_score_adj", "pid", "platform", "ports", "post_start", "pre_stop",
    "privileged", "profiles", "pull_policy", "read_only", "restart", "runtime", "scale", "secrets",
    "security_opt", "shm_size", "stdin_open", "stop_grace_period", "stop_signal", "storage_opt",
    "sysctls", "tmpfs", "tty", "ulimits", "user", "userns_mode", "uts", "volumes", "volumes_from",
    "working_dir",
)

// Same idea for entries under top-level volumes:/networks: — these keys are entry PROPERTIES,
// not entry names.
private val TOP_ENTRY_CONFIG_KEYS = setOf(
    "attachable", "config", "driver", "driver_opts", "enable_ipv6", "external", "internal",
    "ipam", "labels", "name",
)

private fun isValidPortMapping(value: String): Boolean {
    val raw = value.trim().removeSurrounding("\"").removeSurrounding("'")
    if (raw.isBlank()) return false
    val portRegex = Regex("""^\d{1,5}(-\d{1,5})?$""")
    val parts = raw.split(":")
    val portParts = when (parts.size) {
        1 -> listOf(parts[0])
        2 -> parts
        3 -> parts.drop(1) // host ip:host:container
        else -> return false
    }
    return portParts.all { part ->
        val p = part.substringBefore("/").trim()
        portRegex.matches(p) && p.split("-").all { it.toIntOrNull()?.let { n -> n in 1..65535 } == true }
    }
}

fun validateComposeDraft(draft: ComposeStackDraft): List<String> {
    val issues = mutableListOf<String>()
    val activeServices = draft.services.filterNot { it.isCommentedOut }
    val names = activeServices.map { it.serviceName.trim() }
    val duplicates = names.filter { it.isNotBlank() }.groupingBy { it }.eachCount().filterValues { it > 1 }.keys
    for ((idx, svc) in draft.services.withIndex()) {
        if (svc.isCommentedOut) continue
        val label = svc.serviceName.ifBlank { "Service ${idx + 1}" }
        if (svc.serviceName.isBlank()) issues += "$label needs a service name."
        if (svc.serviceName.isNotBlank() && !isValidComposeName(svc.serviceName)) {
            issues += "$label has an invalid service name. Use letters, numbers, dots, dashes, or underscores."
        }
        if (!svc.isCommentedOut && svc.image.isBlank()) {
            issues += "$label needs an image in the visual editor. Use Raw YAML for build-only services."
        }
        svc.ports.filter { it.isNotBlank() && !isValidPortMapping(it) }.forEach {
            issues += "$label has an invalid port mapping: $it"
        }
        if (listOf(svc.ports, svc.environment, svc.volumes, svc.networks, svc.dependsOn).any { list -> list.any { it.isBlank() } }) {
            issues += "$label has empty list rows. Remove or fill them before deploy."
        }
    }
    duplicates.forEach { issues += "Duplicate active service name: $it" }
    val topVolumeNames = draft.topVolumes.filterNot { it.isCommentedOut }.map { it.name.trim() }
    val topNetworkNames = draft.topNetworks.filterNot { it.isCommentedOut }.map { it.name.trim() }
    topVolumeNames.filter { it.isBlank() }.forEach { _ -> issues += "Top-level volumes cannot have blank names." }
    topNetworkNames.filter { it.isBlank() }.forEach { _ -> issues += "Top-level networks cannot have blank names." }
    topVolumeNames.filter { it.isNotBlank() && !isValidComposeName(it) }.forEach {
        issues += "Top-level volume has an invalid name: $it"
    }
    topNetworkNames.filter { it.isNotBlank() && !isValidComposeName(it) }.forEach {
        issues += "Top-level network has an invalid name: $it"
    }
    topNetworkNames.filter { it.isNotBlank() }.groupingBy { it }.eachCount().filterValues { it > 1 }.keys
        .forEach { issues += "Duplicate top-level network name: $it" }
    topVolumeNames.filter { it.isNotBlank() }.groupingBy { it }.eachCount().filterValues { it > 1 }.keys
        .forEach { issues += "Duplicate top-level volume name: $it" }
    draft.topNetworks.filter { !it.isCommentedOut && it.external && it.driver.isNotBlank() }.forEach {
        issues += "${it.name.ifBlank { "Network" }} cannot set both external: true and driver."
    }
    return issues.distinct()
}

/**
 * Parse a compose file into the editable model while recording where every field lives in the
 * source so saves can be surgical. This parser is intentionally permissive: anything it does not
 * model is simply left out of the structured view but stays in [ComposeStackDraft.originalText],
 * which is what an existing-file save preserves.
 */
fun parseDockerComposeYaml(
    yaml: String,
    projectName: String,
    workingDir: String = "",
    fileName: String = "docker-compose.yml",
    composeFilePath: String = "",
    composeConfigFiles: String = "",
    runtime: String = "",
): ComposeStackDraft {
    val lines = yaml.split("\n")
    val draft = ComposeStackDraft(
        projectName = projectName,
        services = mutableListOf(),
        originalText = yaml.ifBlank { null },
        composeFilePath = composeFilePath,
        workingDir = workingDir,
        fileName = fileName,
        composeConfigFiles = composeConfigFiles,
        runtime = runtime,
    )

    var inServices = false
    var inTopVolumes = false
    var inTopNetworks = false
    var current: ComposeServiceDraft? = null
    var currentTopVol: TopLevelVolumeDraft? = null
    var currentTopNet: TopLevelNetworkDraft? = null
    var serviceIndent = -1            // indent of service-name keys (e.g. 2)
    var topSectionItemIndent = -1     // indent of keys directly under volumes:/networks: (e.g. 2)
    var arrayKey = ""                 // current "- " list context (ports/environment/…)
    var arrayKeyLine = -1

    fun indentOf(s: String) = s.takeWhile { it == ' ' }.length
    fun finish() {
        current?.let {
            // A single commented key-only line with no body and no modeled fields is just a
            // comment that happens to look like a service header ("# Database:" in a note),
            // not a commented-out service. Keep it out of the structured view.
            val phantom = it.isCommentedOut && it.srcStart == it.srcEnd &&
                it.image.isBlank() && it.containerName.isBlank() && it.restart.isBlank() &&
                it.command.isBlank() &&
                listOf(it.ports, it.environment, it.volumes, it.networks, it.dependsOn).all { l -> l.isEmpty() }
            if (!phantom) draft.services.add(it)
            current = null
        }
    }
    fun finishTopVol() { currentTopVol?.let { draft.topVolumes.add(it); currentTopVol = null } }
    fun finishTopNet() { currentTopNet?.let { draft.topNetworks.add(it); currentTopNet = null } }

    for ((idx, raw) in lines.withIndex()) {
        if (raw.isBlank()) continue
        val isCommented = raw.trimStart().startsWith("#")
        // For commented service blocks we "see through" the comment by replacing the leading run of
        // "#" and the single space some authors put after it with spaces, preserving the ORIGINAL
        // column alignment. Compose files are commented out by prefixing each line with "# " in place
        // of (usually) one or two indent spaces, so e.g. "  webui:" -> "# webui:" and
        // "    image: x" -> "#   image: x". Mapping "#"+optional-space back to spaces of equal width
        // restores the real indent so commented and live services share one indent scale. Without
        // this, a commented service set serviceIndent to a bogus value and every later live service
        // was skipped (the reported "comment-out does nothing / only one service parsed" bug).
        val effective = if (isCommented) {
            val lead = raw.takeWhile { it == ' ' }
            val afterSpaces = raw.substring(lead.length)            // starts with '#'
            val hashes = afterSpaces.takeWhile { it == '#' }
            var rest = afterSpaces.substring(hashes.length)
            val spaceAfterHash = if (rest.startsWith(" ")) 1 else 0
            rest = rest.substring(spaceAfterHash)
            // width consumed by "#"(es) + optional space, mapped to that many spaces
            " ".repeat(lead.length + hashes.length + spaceAfterHash) + rest
        } else raw
        val content = effective.trim()
        if (content.isEmpty()) continue
        val indent = indentOf(effective)

        // top-level key (indent 0). `name: x` is the Compose project name; `services:` opens the
        // service map; `volumes:`/`networks:` open their respective top-level sections; any other
        // top-level key ends whichever section is active. Sections can appear in any order and may
        // repeat (unusual, but valid YAML merges them in practice — we just parse sequentially).
        if (indent == 0) {
            if (!content.startsWith("-") && content.contains(":")) {
                val k = content.substringBefore(":").trim()
                if (k == "name") {
                    val v = content.substringAfter(":").trim().unquoteYaml().stripYamlInlineComment()
                    if (v.isNotEmpty()) { draft.stackName = v; draft.stackNameSrcLine = idx }
                    finish(); finishTopVol(); finishTopNet()
                    inServices = false; inTopVolumes = false; inTopNetworks = false
                    serviceIndent = -1; topSectionItemIndent = -1
                    continue
                }
            }
            if (content.endsWith(":")) {
                val sectionKey = content.removeSuffix(":").trim()
                finish(); finishTopVol(); finishTopNet()
                inServices = sectionKey == "services"
                inTopVolumes = sectionKey == "volumes"
                inTopNetworks = sectionKey == "networks"
                if (inTopVolumes) draft.volumesSrcHeader = idx
                if (inTopNetworks) draft.networksSrcHeader = idx
                serviceIndent = -1; topSectionItemIndent = -1
                continue
            }
        }

        // ── top-level volumes: section ──
        if (inTopVolumes && !inServices && !inTopNetworks) {
            if (content.endsWith(":") && !content.startsWith("-")) {
                val keyName = content.removeSuffix(":").unquoteYaml()
                // Only LIVE entries establish the section's indent scale: a manually commented
                // entry ("  # db_storage:") see-throughs to a shifted indent and used to set a
                // bogus scale, swallowing every live entry after it. Commented entries are
                // matched by a tolerance window + name check instead.
                val isEntry = if (!isCommented) {
                    if (topSectionItemIndent == -1) topSectionItemIndent = indent
                    indent == topSectionItemIndent
                } else {
                    val max = if (topSectionItemIndent == -1) 4 else topSectionItemIndent + 2
                    indent in 1..max && isValidComposeName(keyName) && keyName !in TOP_ENTRY_CONFIG_KEYS
                }
                if (isEntry) {
                    finishTopVol()
                    currentTopVol = TopLevelVolumeDraft(
                        name = keyName,
                        isCommentedOut = isCommented,
                        srcStart = idx, srcEnd = idx,
                    )
                    continue
                }
            }
            val vol = currentTopVol
            if (vol != null) {
                // Comment lines around a live entry aren't part of it (often a commented-out
                // sibling or a section note); only the entry's real lines extend its span.
                if (isCommented && !vol.isCommentedOut) continue
                vol.srcEnd = idx
                if (content.contains(":") && !content.startsWith("-")) {
                    val k = content.substringBefore(":").trim()
                    val v = content.substringAfter(":").trim().unquoteYaml()
                    if (k == "external" && v == "true") vol.external = true
                }
            }
            continue
        }

        // ── top-level networks: section ──
        if (inTopNetworks && !inServices && !inTopVolumes) {
            if (content.endsWith(":") && !content.startsWith("-")) {
                val keyName = content.removeSuffix(":").unquoteYaml()
                val isEntry = if (!isCommented) {
                    if (topSectionItemIndent == -1) topSectionItemIndent = indent
                    indent == topSectionItemIndent
                } else {
                    val max = if (topSectionItemIndent == -1) 4 else topSectionItemIndent + 2
                    indent in 1..max && isValidComposeName(keyName) && keyName !in TOP_ENTRY_CONFIG_KEYS
                }
                if (isEntry) {
                    finishTopNet()
                    currentTopNet = TopLevelNetworkDraft(
                        name = keyName,
                        isCommentedOut = isCommented,
                        srcStart = idx, srcEnd = idx,
                    )
                    continue
                }
            }
            val net = currentTopNet
            if (net != null) {
                if (isCommented && !net.isCommentedOut) continue
                net.srcEnd = idx
                if (content.contains(":") && !content.startsWith("-")) {
                    val k = content.substringBefore(":").trim()
                    val v = content.substringAfter(":").trim().unquoteYaml()
                    when (k) {
                        "driver" -> if (v.isNotBlank()) net.driver = v
                        "external" -> if (v == "true") net.external = true
                    }
                }
            }
            continue
        }

        if (!inServices) continue

        // service header (first indented key level under services:)
        if (content.endsWith(":")) {
            val keyName = content.removeSuffix(":").unquoteYaml()
            val isHeader = if (!isCommented) {
                if (serviceIndent == -1) serviceIndent = indent
                indent == serviceIndent
            } else {
                // Manually commented services rarely follow the app's exact "# " convention
                // ("#  svc:", "  # svc:", "#   svc:" are all common), so their see-through
                // indent lands 1-2 columns off the live service column. Accept a commented
                // key-only line as a service header when it sits near that column, names a
                // valid service, and isn't a service config key (which would instead be a
                // commented block INSIDE a service, e.g. "#   ports:"). Commented headers
                // never establish the indent scale — only live services do.
                val max = if (serviceIndent == -1) 4 else serviceIndent + 2
                indent in 1..max && isValidComposeName(keyName) &&
                    keyName !in SERVICE_CONFIG_KEYS && !keyName.startsWith("x-")
            }
            if (isHeader) {
                finish()
                current = ComposeServiceDraft(
                    serviceName = keyName,
                    isCommentedOut = isCommented,
                    isExpanded = false,
                    srcStart = idx,
                    srcEnd = idx,
                )
                arrayKey = ""
                continue
            }
        }

        val svc = current ?: continue
        // Comment lines in a LIVE service are not part of it: interior notes are spanned over
        // automatically when real lines follow, and trailing comment blocks (usually a manually
        // commented-out service below) must never be absorbed into the live service's span or
        // parsed as its fields — that's what made edits/deletes/toggles eat those blocks.
        if (isCommented && !svc.isCommentedOut) continue
        svc.srcEnd = idx
        if (svc.bodyIndent == -1 && indent > serviceIndent && !content.startsWith("-")) svc.bodyIndent = indent

        // list item under the current array key
        if (content.startsWith("-")) {
            val item = content.removePrefix("-").trim().unquoteYaml()
            when (arrayKey) {
                "ports" -> svc.ports.add(item)
                "environment" -> svc.environment.add(item)
                "volumes" -> svc.volumes.add(item)
                "networks" -> svc.networks.add(item)
                "depends_on" -> svc.dependsOn.add(item)
            }
            if (arrayKey.isNotEmpty()) {
                val prev = svc.arraySpan[arrayKey]
                svc.arraySpan[arrayKey] = (prev?.first ?: arrayKeyLine)..idx
            }
            continue
        }

        // a key under the service
        if (content.contains(":")) {
            val key = content.substringBefore(":").trim()
            val value = content.substringAfter(":").trim().unquoteYaml().stripYamlInlineComment()
            arrayKey = ""
            if (value.isEmpty()) {
                // block key whose value is on following lines (a list or map)
                when (key) {
                    "ports", "environment", "volumes", "networks", "depends_on" -> {
                        arrayKey = key; arrayKeyLine = idx
                        svc.arraySpan[key] = idx..idx
                    }
                }
            } else {
                when (key) {
                    "image" -> { svc.image = value; svc.scalarLine["image"] = idx }
                    "container_name" -> { svc.containerName = value; svc.scalarLine["container_name"] = idx }
                    "restart" -> { svc.restart = value; svc.scalarLine["restart"] = idx }
                    "command" -> { svc.command = value; svc.scalarLine["command"] = idx }
                    // Inline KEY=VALUE handled when it appears as an environment list item above.
                }
            }
        }
    }
    finish()
    finishTopVol()
    finishTopNet()
    if (draft.services.isEmpty()) draft.services.add(ComposeServiceDraft())
    return draft
}

/** Generate one service's YAML block (2-space service key, 4-space body), no trailing newline. */
private fun generateServiceBlock(svc: ComposeServiceDraft): String {
    val sb = StringBuilder()
    val name = svc.serviceName.ifBlank { "service" }
    val c = if (svc.isCommentedOut) "# " else ""
    sb.append("$c  $name:\n")
    fun scalar(k: String, v: String) { if (v.isNotBlank()) sb.append("$c    $k: ${yamlPlainOrSingleQuoted(v)}\n") }
    scalar("image", svc.image)
    scalar("container_name", svc.containerName)
    scalar("restart", svc.restart)
    scalar("command", svc.command)
    fun list(k: String, items: List<String>, quote: Boolean) {
        val v = items.filter { it.isNotBlank() }
        if (v.isEmpty()) return
        sb.append("$c    $k:\n")
        for (it in v) sb.append(if (quote) "$c      - ${yamlDoubleQuoted(it)}\n" else "$c      - ${yamlPlainOrSingleQuoted(it)}\n")
    }
    list("ports", svc.ports, quote = true)
    list("environment", svc.environment, quote = false)
    list("volumes", svc.volumes, quote = false)
    list("networks", svc.networks, quote = false)
    list("depends_on", svc.dependsOn, quote = false)
    return sb.toString().trimEnd('\n')
}

/** Generate a full compose file from scratch (used for brand-new stacks only). */
fun generateDockerComposeYaml(draft: ComposeStackDraft): String {
    val sb = StringBuilder()
    // No top-level `version:` — it's obsolete in the Compose Spec and recent Docker/Podman Compose
    // print a deprecation warning for it. Omitting it keeps deploy output clean.
    if (draft.stackName.isNotBlank()) sb.append("name: ${yamlPlainOrSingleQuoted(draft.stackName)}\n")
    sb.append("services:\n")
    for (svc in draft.services) {
        sb.append(generateServiceBlock(svc))
        sb.append("\n")
    }
    val vols = draft.topVolumes.filter { it.name.isNotBlank() }
    if (vols.isNotEmpty()) {
        sb.append("\nvolumes:\n")
        for (v in vols) {
            val c = if (v.isCommentedOut) "# " else ""
            sb.append("${c}  ${v.name}:\n")
            if (v.external) sb.append("${c}    external: true\n")
        }
    }
    val nets = draft.topNetworks.filter { it.name.isNotBlank() }
    if (nets.isNotEmpty()) {
        sb.append("\nnetworks:\n")
        for (n in nets) {
            val c = if (n.isCommentedOut) "# " else ""
            sb.append("${c}  ${n.name}:\n")
            if (n.driver.isNotBlank()) sb.append("${c}    driver: ${yamlPlainOrSingleQuoted(n.driver)}\n")
            if (n.external) sb.append("${c}    external: true\n")
        }
    }
    return sb.toString()
}

/**
 * Produce the YAML to write for [draft]. For an existing file this is a SURGICAL update of
 * [ComposeStackDraft.originalText]: only fields whose value changed are rewritten in place, so
 * everything the builder doesn't model stays exactly as it was. New drafts fall back to a full
 * generate.
 */
fun renderComposeYaml(draft: ComposeStackDraft, parsedFrom: ComposeStackDraft?): String {
    val original = draft.originalText
    if (original == null || parsedFrom == null) return generateDockerComposeYaml(draft)

    val lines = original.split("\n")
    // Editing is index-stable: each original line keeps its slot. A slot holds either the
    // (possibly rewritten) line, or null when that line is deleted. Brand-new lines for a service
    // are appended to its anchor slot via [insertAfter] so they emit right after that original
    // line, WITHOUT shifting any other slot's index. The whole thing is flattened once at the end.
    val slot = arrayUListOfLines(lines)             // MutableList<String?> sized to lines
    val insertAfter = HashMap<Int, MutableList<String>>()   // anchorIndex → extra lines after it
    val prepend = mutableListOf<String>()                   // lines emitted before everything else
    fun insert(at: Int, text: String) {
        val anchor = at.coerceIn(0, lines.lastIndex.coerceAtLeast(0))
        insertAfter.getOrPut(anchor) { mutableListOf() }.add(text)
    }

    val originals = parsedFrom.services.associateBy { it.id }
    fun indentStr(n: Int) = " ".repeat(n.coerceAtLeast(0))

    // Top-level `name:` — surgically update/add/remove (it lives at indent 0, outside any service).
    if (draft.stackName != parsedFrom.stackName) {
        val nameLine = parsedFrom.stackNameSrcLine
        when {
            // existing name line → rewrite or delete it
            nameLine in slot.indices && slot[nameLine] != null -> {
                slot[nameLine] = if (draft.stackName.isBlank()) null else "name: ${draft.stackName}"
            }
            // no name line yet → insert one just before the `services:` line. If `services:` is the
            // very first line, prepend by emitting before slot 0 (handled via the prepend list).
            draft.stackName.isNotBlank() -> {
                val servicesIdx = lines.indexOfFirst { it.trimEnd() == "services:" }
                if (servicesIdx > 0) {
                    insert(servicesIdx - 1, "name: ${draft.stackName}")
                } else {
                    prepend.add("name: ${draft.stackName}")
                }
            }
        }
    }

    // Services the user deleted in the builder: blank out their entire original span.
    val keptIds = draft.services.mapTo(HashSet()) { it.id }
    for (src in parsedFrom.services) {
        if (src.id !in keptIds && src.srcStart >= 0) {
            for (i in src.srcStart..src.srcEnd) if (i in slot.indices) slot[i] = null
        }
    }

    for (svc in draft.services) {
        val src = originals[svc.id] ?: continue   // new services are emitted after the loop
        val bodyIndent = if (svc.bodyIndent > 0) svc.bodyIndent else 4

        // Comment-state toggle across the whole original block. We comment by putting "# " at
        // COLUMN 0 and consuming up to two leading indent spaces, matching the convention compose
        // files use (e.g. "  webui:" -> "# webui:", "    image: x" -> "#   image: x"). This keeps
        // the body's relative indentation and is exactly reversible by the parser's #→space mapping.
        if (svc.isCommentedOut != src.isCommentedOut && src.srcStart >= 0) {
            if (svc.isCommentedOut) {
                for (i in src.srcStart..src.srcEnd) {
                    if (i !in slot.indices) continue
                    val line = slot[i] ?: continue
                    if (line.trimStart().startsWith("#")) continue
                    val lead = line.takeWhile { it == ' ' }
                    val drop = minOf(2, lead.length)             // "# " replaces up to 2 indent spaces
                    slot[i] = "# " + line.substring(drop)
                }
            } else {
                // Uncomment: strip each line's comment prefix ("#"s + one space, wherever the
                // author put them), then shift the whole block so the header lands on the
                // canonical 2-space service column with every line's RELATIVE indent kept.
                // Naive per-line prefix stripping left manually-commented blocks ("#  svc:",
                // "  # svc:") with the header and body at inconsistent sibling indents,
                // which is invalid YAML.
                fun strip(line: String): String =
                    line.trimStart().dropWhile { it == '#' }.removePrefix(" ")
                val header = slot[src.srcStart] ?: lines.getOrNull(src.srcStart) ?: ""
                val delta = 2 - indentOfLine(strip(header))
                for (i in src.srcStart..src.srcEnd) {
                    if (i !in slot.indices) continue
                    val line = slot[i] ?: continue
                    if (!line.trimStart().startsWith("#")) continue
                    val stripped = strip(line)
                    val ind = (indentOfLine(stripped) + delta).coerceAtLeast(0)
                    slot[i] = " ".repeat(ind) + stripped.trimStart()
                }
            }
        }

        fun applyScalar(key: String, newVal: String, oldVal: String) {
            if (newVal == oldVal) return
            val lineIdx = src.scalarLine[key]
            if (lineIdx != null && lineIdx in slot.indices && slot[lineIdx] != null) {
                if (newVal.isBlank()) { slot[lineIdx] = null; return }      // cleared → drop the line
                val ind = slot[lineIdx]!!.takeWhile { it == ' ' || it == '#' }
                slot[lineIdx] = "$ind$key: $newVal"
            } else if (newVal.isNotBlank()) {
                insert(src.srcStart, "${indentStr(bodyIndent)}$key: $newVal")  // add after header
            }
        }
        applyScalar("image", svc.image, src.image)
        applyScalar("container_name", svc.containerName, src.containerName)
        applyScalar("restart", svc.restart, src.restart)
        applyScalar("command", svc.command, src.command)

        fun applyArray(key: String, items: List<String>, old: List<String>, quote: Boolean) {
            val cleaned = items.filter { it.isNotBlank() }
            if (cleaned == old.filter { it.isNotBlank() }) return
            val span = src.arraySpan[key]
            val block = buildList {
                if (cleaned.isNotEmpty()) {
                    add("${indentStr(bodyIndent)}$key:")
                    for (it in cleaned) add("${indentStr(bodyIndent + 2)}- ${if (quote) "\"$it\"" else it}")
                }
            }
            if (span != null) {
                for (i in span) if (i in slot.indices) slot[i] = null         // drop old block
                if (block.isNotEmpty() && span.first in slot.indices) slot[span.first] = block.joinToString("\n")
            } else if (block.isNotEmpty()) {
                insert(src.srcEnd, block.joinToString("\n"))
            }
        }
        applyArray("ports", svc.ports, src.ports, quote = true)
        applyArray("environment", svc.environment, src.environment, quote = false)
        applyArray("volumes", svc.volumes, src.volumes, quote = false)
        applyArray("networks", svc.networks, src.networks, quote = false)
        applyArray("depends_on", svc.dependsOn, src.dependsOn, quote = false)
    }

    // ── Top-level volumes ──
    val origTopVols = parsedFrom.topVolumes.associateBy { it.id }
    val keptVolIds = draft.topVolumes.mapTo(HashSet()) { it.id }
    fun volumeBlock(v: TopLevelVolumeDraft): List<String> {
        val c = if (v.isCommentedOut) "# " else ""
        return buildList {
            add("${c}  ${v.name}:")
            if (v.external) add("${c}    external: true")
        }
    }
    // Delete removed entries
    for (src in parsedFrom.topVolumes) {
        if (src.id !in keptVolIds && src.srcStart >= 0) {
            for (i in src.srcStart..src.srcEnd) if (i in slot.indices) slot[i] = null
        }
    }
    // Update existing entries (name, external, or comment-state changed)
    for (vol in draft.topVolumes) {
        val src = origTopVols[vol.id] ?: continue
        if (vol.name == src.name && vol.external == src.external && vol.isCommentedOut == src.isCommentedOut) continue
        if (src.srcStart in slot.indices) {
            val c = if (vol.isCommentedOut) "# " else ""
            val newBlock = buildString {
                append("${c}  ${vol.name}:")
                if (vol.external) append("\n${c}    external: true")
            }
            slot[src.srcStart] = newBlock
            for (i in (src.srcStart + 1)..src.srcEnd) if (i in slot.indices) slot[i] = null
        }
    }
    // Handle the volumes: header — add it if entries now exist but the header was absent
    val newTopVols = draft.topVolumes.filter { it.name.isNotBlank() && it.id !in origTopVols }
    val hasExistingVolHeader = parsedFrom.volumesSrcHeader >= 0
    if (hasExistingVolHeader && newTopVols.isNotEmpty()) {
        val anchor = parsedFrom.topVolumes.maxOfOrNull { it.srcEnd } ?: parsedFrom.volumesSrcHeader
        newTopVols.forEach { insert(anchor, volumeBlock(it).joinToString("\n")) }
    }
    // If the header exists but all volumes are now gone, null out the header line
    if (hasExistingVolHeader && draft.topVolumes.none { it.name.isNotBlank() }) {
        val hIdx = parsedFrom.volumesSrcHeader
        if (hIdx in slot.indices) slot[hIdx] = null
    }

    // ── Top-level networks ──
    val origTopNets = parsedFrom.topNetworks.associateBy { it.id }
    val keptNetIds = draft.topNetworks.mapTo(HashSet()) { it.id }
    fun networkBlock(n: TopLevelNetworkDraft): List<String> {
        val c = if (n.isCommentedOut) "# " else ""
        return buildList {
            add("${c}  ${n.name}:")
            if (n.driver.isNotBlank()) add("${c}    driver: ${n.driver}")
            if (n.external) add("${c}    external: true")
        }
    }
    for (src in parsedFrom.topNetworks) {
        if (src.id !in keptNetIds && src.srcStart >= 0) {
            for (i in src.srcStart..src.srcEnd) if (i in slot.indices) slot[i] = null
        }
    }
    for (net in draft.topNetworks) {
        val src = origTopNets[net.id] ?: continue
        if (net.name == src.name && net.driver == src.driver && net.external == src.external && net.isCommentedOut == src.isCommentedOut) continue
        if (src.srcStart in slot.indices) {
            val c = if (net.isCommentedOut) "# " else ""
            val newBlock = buildString {
                append("${c}  ${net.name}:")
                if (net.driver.isNotBlank()) append("\n${c}    driver: ${net.driver}")
                if (net.external) append("\n${c}    external: true")
            }
            slot[src.srcStart] = newBlock
            for (i in (src.srcStart + 1)..src.srcEnd) if (i in slot.indices) slot[i] = null
        }
    }
    if (parsedFrom.networksSrcHeader >= 0 && draft.topNetworks.none { it.name.isNotBlank() }) {
        val hIdx = parsedFrom.networksSrcHeader
        if (hIdx in slot.indices) slot[hIdx] = null
    }
    val brandNewNets = draft.topNetworks.filter { it.name.isNotBlank() && it.id !in origTopNets }
    if (parsedFrom.networksSrcHeader >= 0 && brandNewNets.isNotEmpty()) {
        val anchor = parsedFrom.topNetworks.maxOfOrNull { it.srcEnd } ?: parsedFrom.networksSrcHeader
        brandNewNets.forEach { insert(anchor, networkBlock(it).joinToString("\n")) }
    }

    // Flatten: prepended lines, then each surviving slot followed by anything inserted after it.
    val sb = StringBuilder()
    var firstOut = true
    fun emit(line: String) { if (!firstOut) sb.append("\n"); sb.append(line); firstOut = false }
    prepend.forEach { emit(it) }
    for (i in lines.indices) {
        slot[i]?.let { emit(it) }
        insertAfter[i]?.forEach { emit(it) }
    }

    // Brand-new services (added in the builder, no source mapping) are appended as fresh blocks.
    for (svc in draft.services) {
        if (svc.id in originals) continue
        if (svc.serviceName.isBlank() && svc.image.isBlank()) continue   // skip empty placeholder rows
        generateServiceBlock(svc).split("\n").forEach { emit(it) }
    }

    // Brand-new top-level volumes (no srcStart) — append as a fresh section or into the existing header.
    val brandNewVols = draft.topVolumes.filter { it.name.isNotBlank() && it.id !in origTopVols }
    if (brandNewVols.isNotEmpty() && !hasExistingVolHeader) {
        emit("\nvolumes:")
        for (v in brandNewVols) volumeBlock(v).forEach { emit(it) }
    }

    // Brand-new top-level networks
    if (brandNewNets.isNotEmpty() && parsedFrom.networksSrcHeader < 0) {
        emit("\nnetworks:")
        for (n in brandNewNets) networkBlock(n).forEach { emit(it) }
    }

    return sb.toString()
}

/** Helper to build a fixed-size mutable slot list seeded from [lines]. */
private fun arrayUListOfLines(lines: List<String>): MutableList<String?> =
    MutableList(lines.size) { lines[it] }

/**
 * True when leaving Raw YAML mode would silently discard edits: the raw editor's text no longer
 * matches what the visual form renders from [draft] against [parsedBaseline]. Drives the
 * "Leave Raw YAML?" confirmation in [ComposeBuilder]; pure so the behaviour is unit-testable.
 */
fun composeRawEditsDiffer(rawText: String, draft: ComposeStackDraft, parsedBaseline: ComposeStackDraft?): Boolean =
    rawText != renderComposeYaml(draft, parsedBaseline)

@Composable
fun ComposeBuilder(viewModel: AppViewModel) {
    val active = viewModel.activeComposeDraft
    // STABLE seed key identifying a distinct edit session. It must NOT change on every keystroke —
    // otherwise mirroring edits back to the ViewModel (below) would re-seed the parsed baseline to
    // the already-edited draft, so the surgical diff would see "no changes" and silently drop edits
    // (this is the class of bug behind "comment toggle doesn't reflect / save"). For an existing
    // file the absolute path is a perfect stable identity; a brand-new draft uses a constant so its
    // in-progress state survives recompositions, and "New / Clear" (active == null) resets it.
    val seedKey = when {
        active == null -> "::cleared::"
        active.composeFilePath.isNotBlank() -> "file:${active.composeFilePath}"
        else -> "::new::"
    }

    // Immutable parsed baseline for surgical diffing — captured ONCE per edit session.
    val parsedBaseline = remember(seedKey) { active }
    var draft by remember(seedKey) { mutableStateOf(active ?: ComposeStackDraft()) }

    // Mirror local edits back to the ViewModel so switching tabs doesn't lose them.
    LaunchedEffect(draft) {
        if (viewModel.activeComposeDraft !== draft) viewModel.activeComposeDraft = draft
    }

    var rawMode by remember(seedKey) { mutableStateOf(false) }
    var rawText by remember(seedKey) { mutableStateOf(draft.originalText ?: generateDockerComposeYaml(draft)) }
    // When true, the Raw YAML editor opens as a full-screen overlay matching the SFTP file editor's
    // look/feel (same chrome, find/replace, go-to-line, word-wrap). Edits write straight to rawText.
    var rawFullScreen by remember(seedKey) { mutableStateOf(false) }

    var deploying by remember { mutableStateOf(false) }
    var result by remember { mutableStateOf<Pair<Boolean, String>?>(null) }
    val copyToClipboard = rememberClipboardCopy()

    val confirm = rememberConfirm()
    ConfirmHost(confirm)

    val isExisting = draft.originalText != null

    fun yamlToDeploy(): String =
        if (rawMode) rawText else renderComposeYaml(draft, parsedBaseline)

    fun isDirty(): Boolean {
        val initialYaml = parsedBaseline?.originalText ?: generateDockerComposeYaml(parsedBaseline ?: ComposeStackDraft())
        val currentYaml = yamlToDeploy()
        return currentYaml != initialYaml
    }

    fun attemptClearOrExit() {
        if (isDirty()) {
            confirm.ask(
                "Discard changes?",
                "You have unsaved changes to this stack. Discard them?",
                confirmLabel = "Discard"
            ) { viewModel.activeComposeDraft = null }
        } else {
            viewModel.activeComposeDraft = null
        }
    }

    BackHandler(enabled = true) {
        attemptClearOrExit()
    }

    val validationIssues = remember(draft, rawMode) {
        if (rawMode) emptyList() else validateComposeDraft(draft)
    }

    Box(modifier = Modifier.fillMaxSize()) {
    Column(modifier = Modifier.fillMaxSize()) {
        // ── outcome banner ──
        result?.let { (ok, msg) ->
            Row(
                modifier = Modifier.fillMaxWidth()
                    .background(if (ok) OmniColors.green.copy(alpha = 0.15f) else OmniColors.red.copy(alpha = 0.18f))
                    .padding(12.dp),
                verticalAlignment = Alignment.Top,
            ) {
                Icon(
                    if (ok) Icons.Filled.CheckCircle else Icons.Filled.Error,
                    contentDescription = null,
                    tint = if (ok) OmniColors.green else OmniColors.red,
                    modifier = Modifier.size(18.dp),
                )
                Spacer(Modifier.width(8.dp))
                Column(Modifier.weight(1f)) {
                    Text(
                        if (ok) "Stack deployed" else "Deploy failed — stack left unchanged",
                        fontWeight = FontWeight.Bold,
                        color = if (ok) OmniColors.green else OmniColors.red,
                    )
                    if (msg.isNotBlank()) {
                        Box(Modifier.heightIn(max = 140.dp).verticalScroll(rememberScrollState())) {
                            androidx.compose.foundation.text.selection.SelectionContainer {
                                Text(msg, fontFamily = OmniFonts.mono, fontSize = 11.sp, color = OmniColors.textPrimary)
                            }
                        }
                    }
                }
                if (msg.isNotBlank()) {
                    IconButton(onClick = { copyToClipboard(msg) }) {
                        Icon(Icons.Filled.ContentCopy, contentDescription = "Copy deploy output")
                    }
                }
                TextButton(onClick = { result = null }) { Text("Dismiss") }
            }
        }

        Column(
            modifier = Modifier.fillMaxWidth().weight(1f).verticalScroll(rememberScrollState()).padding(12.dp).imePadding(),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                Column {
                    Text("Compose Builder", fontWeight = FontWeight.Bold, fontSize = 20.sp, color = OmniColors.cyan)
                    Text(if (isExisting) "Editing existing stack" else "New stack", fontSize = 11.sp, color = OmniColors.textMuted)
                }
                if (active != null) {
                    TextButton(onClick = { attemptClearOrExit() }) { Text("New / Clear") }
                }
            }

            // ── compose file path (the exact file Docker reported — what we read/validate/deploy) ──
            if (isExisting && draft.composeFilePath.isNotBlank()) {
                Column(
                    Modifier.fillMaxWidth()
                        .clip(RoundedCornerShape(8.dp))
                        .background(OmniColors.bg1)
                        .border(1.dp, OmniColors.bg2, RoundedCornerShape(8.dp))
                        .padding(horizontal = 10.dp, vertical = 8.dp),
                ) {
                    Text("COMPOSE FILE", fontSize = 9.sp, fontWeight = FontWeight.Bold, letterSpacing = 1.sp, color = OmniColors.textMuted)
                    Text(
                        draft.composeFilePath,
                        fontFamily = OmniFonts.mono,
                        fontSize = 12.sp,
                        color = OmniColors.cyan,
                    )
                }
            }

            // ── view toggle ──
            val tabs = listOf("Visual", "Raw YAML")
            PrimaryTabRow(selectedTabIndex = if (rawMode) 1 else 0, containerColor = Color.Transparent) {
                tabs.forEachIndexed { i, t ->
                    Tab(
                            selected = (i == 1) == rawMode,
                            onClick = {
                                when {
                                    i == 1 && !rawMode -> {
                                        rawText = yamlToDeploy()    // sync visual → raw
                                        rawMode = true
                                    }
                                    i == 0 && rawMode && composeRawEditsDiffer(rawText, draft, parsedBaseline) -> {
                                        confirm.ask(
                                            "Leave Raw YAML?",
                                            "Raw YAML edits are not applied to the visual form. Switch back and ignore those raw edits for deploy?",
                                            confirmLabel = "Switch",
                                        ) { rawMode = false }
                                    }
                                    else -> rawMode = i == 1
                                }
                            },
                            text = { Text(t) },
                        )
                }
            }

            if (rawMode) {
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    if (isExisting) {
                        Text(
                            "Editing the file directly. Nothing is changed until you deploy, and the file is validated first.",
                            fontSize = 11.sp, color = OmniColors.textMuted,
                            modifier = Modifier.weight(1f),
                        )
                    } else {
                        Spacer(Modifier.weight(1f))
                    }
                    IconButton(onClick = { rawFullScreen = true }) {
                        Icon(Icons.Filled.Fullscreen, contentDescription = "Edit full screen", tint = OmniColors.cyan)
                    }
                }
                CodeEditor(
                    value = rawText,
                    onValueChange = { rawText = it },
                    fontSize = 12.sp,
                    language = CodeLanguage.YAML,
                    highlightMaxChars = viewModel.editorHighlightLimit,
                    modifier = Modifier.fillMaxWidth().height(420.dp),
                )
            } else {
                // Top-level compose `name:` (project name written into the file). Optional.
                OutlinedTextField(
                    value = draft.stackName,
                    onValueChange = { draft = draft.copy(stackName = it.trim()) },
                    label = { Text("Stack name (compose name: key, optional)") },
                    placeholder = { Text("e.g. example_stack") },
                    singleLine = true,
                    colors = omniTextFieldColors(),
                    modifier = Modifier.fillMaxWidth(),
                )
                    VisualEditor(draft) { draft = it }
                    if (validationIssues.isNotEmpty()) {
                        Column(
                            Modifier.fillMaxWidth()
                                .clip(RoundedCornerShape(8.dp))
                                .background(OmniColors.red.copy(alpha = 0.12f))
                                .border(1.dp, OmniColors.red.copy(alpha = 0.35f), RoundedCornerShape(8.dp))
                                .padding(10.dp),
                            verticalArrangement = Arrangement.spacedBy(4.dp),
                        ) {
                            Text("${validationIssues.size} issue(s) before deploy", fontWeight = FontWeight.Bold, color = OmniColors.red)
                            validationIssues.take(5).forEach {
                                Text("• $it", fontSize = 11.sp, color = OmniColors.textPrimary)
                            }
                        }
                    }
                    Spacer(Modifier.height(4.dp))
                var previewExpanded by remember { mutableStateOf(false) }
                Row(
                    Modifier.fillMaxWidth().clickable { previewExpanded = !previewExpanded },
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(
                        if (previewExpanded) Icons.Filled.ExpandLess else Icons.Filled.ExpandMore,
                        contentDescription = if (previewExpanded) "Collapse preview" else "Expand preview",
                        tint = OmniColors.cyan,
                    )
                    Spacer(Modifier.width(6.dp))
                    Text("Preview", fontWeight = FontWeight.Bold, color = OmniColors.cyan)
                }
                if (previewExpanded) {
                    Box(
                        Modifier.fillMaxWidth()
                            .clip(RoundedCornerShape(8.dp))
                            .background(OmniColors.bg1)
                            .border(1.dp, OmniColors.bg2, RoundedCornerShape(8.dp))
                            .padding(10.dp)
                            .horizontalScroll(rememberScrollState()),
                    ) {
                        Text(yamlToDeploy(), fontFamily = OmniFonts.mono, fontSize = 12.sp, color = OmniColors.textPrimary)
                    }
                }
            }

            // ── project name (deploy target dir for new stacks) ──
            if (!isExisting) {
                OutlinedTextField(
                    value = draft.projectName,
                    onValueChange = { draft = draft.copy(projectName = it) },
                    label = { Text("Project name (~/<name> deploy directory)") },
                    placeholder = { Text("e.g. my_stack") },
                    singleLine = true,
                    colors = omniTextFieldColors(),
                    modifier = Modifier.fillMaxWidth(),
                )
            }

            // ── container runtime ──
            // Only offered when the host has BOTH usable runtimes; with a single runtime the
            // on-host resolver already picks it. Existing stacks stay on the runtime that owns
            // them — deploying to the other one wouldn't update the running stack, it would start
            // a duplicate beside it — so the runtime is shown but not editable.
            val bothRuntimes = viewModel.availableContainerRuntimes.containsAll(setOf("docker", "podman"))
            if (!isExisting && bothRuntimes) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Text("Runtime", fontSize = 12.sp, color = OmniColors.textMuted)
                    // Blank runtime deploys via the auto-resolver, which prefers Docker — so
                    // Docker renders as the default selection until the user picks explicitly.
                    FilterChip(
                        selected = draft.runtime != "podman",
                        onClick = { draft = draft.copy(runtime = "docker") },
                        label = { Text("Docker") },
                    )
                    FilterChip(
                        selected = draft.runtime == "podman",
                        onClick = { draft = draft.copy(runtime = "podman") },
                        label = { Text("Podman") },
                    )
                }
            } else if (isExisting && bothRuntimes && draft.runtime.isNotBlank()) {
                Text(
                    "Runtime: ${draft.runtime} (owned by this runtime; redeploys stay on it)",
                    fontSize = 11.sp, color = OmniColors.textMuted,
                )
            }

            OmniButton(
                label = if (deploying) "Deploying…" else if (isExisting) "Validate & Deploy" else "Deploy Stack",
                color = OmniColors.amber,
                modifier = Modifier.fillMaxWidth(),
                    onClick = {
                        if (deploying) return@OmniButton
                        if (viewModel.selectedServer == null) { result = false to "No host selected."; return@OmniButton }
                        if (!rawMode && validationIssues.isNotEmpty()) {
                            result = false to validationIssues.joinToString("\n")
                            return@OmniButton
                        }
                        val yaml = yamlToDeploy()
                        val fileName = draft.fileName.ifBlank { "docker-compose.yml" }
                        val project = if (isExisting) draft.projectName else draft.stackName.ifBlank { draft.projectName.ifBlank { "stack" } }
                    // Always operate on the EXACT absolute compose-file path. For an existing stack
                    // this is the running file Docker reported; for a new stack, ~/<project>/<file>.
                    val composeFilePath = if (isExisting && draft.composeFilePath.isNotBlank()) {
                        draft.composeFilePath
                    } else {
                        "~/${draft.projectName.ifBlank { "stack" }}/$fileName"
                    }
                    confirm.ask(
                        if (isExisting) "Deploy changes?" else "Deploy stack?",
                            "Target file: $composeFilePath\n\nIt's validated first; the current file is backed up, and if the deploy fails the previous file is restored automatically.",
                        confirmLabel = "Deploy",
                    ) {
                        deploying = true
                        result = null
                            viewModel.deployComposeStack(
                                composeFilePath = composeFilePath,
                                project = project,
                                yaml = yaml,
                                workingDir = draft.workingDir,
                                configFiles = draft.composeConfigFiles,
                                runtime = draft.runtime,
                            ) { ok, out ->
                            deploying = false
                            result = ok to out
                        }
                    }
                },
            )
            Spacer(Modifier.height(32.dp))
        }
    }

        // Full-screen Raw YAML editor overlay — same chrome/operations as the SFTP file editor.
        if (rawFullScreen && rawMode) {
            FullScreenCodeEditor(
                title = draft.fileName.ifBlank { "docker-compose.yml" },
                value = rawText,
                onValueChange = { rawText = it },
                onClose = { rawFullScreen = false },
                onSave = { rawFullScreen = false },
                subtitle = "${rawText.count { it == '\n' } + 1} lines · ${rawText.length} chars",
                dirty = false,
                canSave = true,
                saveLabel = "Done",
                fontSize = 12.sp,
                language = CodeLanguage.YAML,
                highlightMaxChars = viewModel.editorHighlightLimit,
            )
        }
    }
}

/** Extract the named-volume name from a service volumes entry, or null for bind-mounts. */
private fun namedVolumeFrom(entry: String): String? {
    val raw = entry.trim()
    if (raw.isBlank() || raw.startsWith(".") || raw.startsWith("/")) return null
    val name = if (raw.contains(":")) raw.substringBefore(":").trim() else raw
    return name.ifBlank { null }
}

/**
 * After any service volume edit, ensure every named volume referenced by a service has a
 * corresponding entry in the top-level volumes list. New entries are appended; existing entries
 * (including those added manually in the top-level editor) are never removed by this function.
 */
/**
 * Reconcile the top-level volumes list against the current service definitions:
 *
 * - ADD: any named volume referenced by an active service that has no declaration yet gets one.
 * - COMMENT: any auto-generated declaration whose volume is only referenced by commented-out
 *   services gets commented out. Declarations from the original file are comment-toggled too,
 *   so the on-disk file stays consistent.
 * - UNCOMMENT: if a previously-commented volume is now referenced by at least one active service,
 *   its top-level entry is uncommented.
 * - PRUNE: auto-generated (srcStart == -1) entries that are not referenced by any service at all
 *   (active or commented) are removed entirely. On-disk entries are never deleted automatically.
 *
 * "Active" means not commented out. Bind-mounts (./… or /…) are ignored throughout.
 */
private fun reconcileTopLevelVolumes(draft: ComposeStackDraft): ComposeStackDraft {
    val activeRefs = draft.services
        .filter { !it.isCommentedOut }
        .flatMap { it.volumes }
        .mapNotNull { namedVolumeFrom(it) }
        .toSet()
    val allRefs = draft.services
        .flatMap { it.volumes }
        .mapNotNull { namedVolumeFrom(it) }
        .toSet()

    val existing = draft.topVolumes.toMutableList()
    val declaredNames = existing.map { it.name }.toMutableSet()

    // Add missing declarations for active services
    for (name in activeRefs) {
        if (name !in declaredNames) {
            existing += TopLevelVolumeDraft(name = name, isCommentedOut = false)
            declaredNames += name
        }
    }

    // Update comment state and prune orphans
    val result = mutableListOf<TopLevelVolumeDraft>()
    for (vol in existing) {
        when {
            vol.name in activeRefs ->
                // Referenced by an active service → must be uncommented
                result += if (vol.isCommentedOut) vol.copy(isCommentedOut = false) else vol
            vol.name in allRefs ->
                // Only referenced by commented-out services → comment it out
                result += if (!vol.isCommentedOut) vol.copy(isCommentedOut = true) else vol
            vol.srcStart >= 0 ->
                // Not referenced by anything, but came from the original file → keep as-is
                result += vol
            // else: auto-generated and no longer referenced at all → drop
        }
    }

    return if (result == draft.topVolumes) draft else draft.copy(topVolumes = result)
}

@Composable
private fun VisualEditor(draft: ComposeStackDraft, onChange: (ComposeStackDraft) -> Unit) {
    fun updateSvc(index: Int, transform: (ComposeServiceDraft) -> ComposeServiceDraft) {
        val list = draft.services.toMutableList()
        list[index] = transform(list[index])
        onChange(reconcileTopLevelVolumes(draft.copy(services = list)))
    }

    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        draft.services.forEachIndexed { index, svc ->
            OmniCard(
                modifier = Modifier.fillMaxWidth(),
                leftAccent = if (svc.isCommentedOut) OmniColors.textMuted else OmniColors.purple,
            ) {
                Column(Modifier.fillMaxWidth().padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Row(
                        Modifier.fillMaxWidth().clickable { updateSvc(index) { it.copy(isExpanded = !it.isExpanded) } },
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(
                                if (svc.isExpanded) Icons.Filled.ExpandLess else Icons.Filled.ExpandMore,
                                contentDescription = null, tint = OmniColors.cyan,
                            )
                            Spacer(Modifier.width(6.dp))
                            Text(
                                svc.serviceName.ifBlank { "Service ${index + 1}" },
                                fontWeight = FontWeight.Bold, fontFamily = OmniFonts.mono,
                                color = if (svc.isCommentedOut) OmniColors.textMuted else OmniColors.textPrimary,
                            )
                        }
                        when {
                            svc.image.isNotBlank() -> OmniTag(svc.image, color = OmniColors.cyan)
                            svc.containerName.isNotBlank() -> OmniTag(svc.containerName, color = OmniColors.textMuted)
                        }
                    }

                    if (svc.isExpanded) {
                        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Text("Comment out", fontSize = 12.sp, color = OmniColors.textMuted)
                                Switch(checked = svc.isCommentedOut, onCheckedChange = { v -> updateSvc(index) { it.copy(isCommentedOut = v) } })
                            }
                            IconButton(onClick = {
                                val list = draft.services.toMutableList()
                                list.removeAt(index)
                                onChange(reconcileTopLevelVolumes(draft.copy(services = list)))
                            }) { Icon(Icons.Filled.Delete, "Delete service", tint = OmniColors.red) }
                        }

                        Field("Service name", svc.serviceName, "web, db, api") { v -> updateSvc(index) { it.copy(serviceName = v) } }
                        Field("Image", svc.image, "nginx:latest") { v -> updateSvc(index) { it.copy(image = v) } }
                        Field("Container name", svc.containerName, "my-nginx") { v -> updateSvc(index) { it.copy(containerName = v) } }
                        Field("Restart policy", svc.restart, "unless-stopped / always / no") { v -> updateSvc(index) { it.copy(restart = v) } }
                        Field("Command", svc.command, "optional override") { v -> updateSvc(index) { it.copy(command = v) } }

                        ListEditor("Ports (host:container)", svc.ports, "8080:80") { n -> updateSvc(index) { it.copy(ports = n) } }
                        ListEditor("Environment (KEY=VALUE)", svc.environment, "NODE_ENV=production") { n -> updateSvc(index) { it.copy(environment = n) } }
                        ListEditor("Volumes (host:container)", svc.volumes, "./data:/var/lib/data") { n -> updateSvc(index) { it.copy(volumes = n) } }
                        ListEditor("Networks", svc.networks, "frontend") { n -> updateSvc(index) { it.copy(networks = n) } }
                        ListEditor("Depends on", svc.dependsOn, "db") { n -> updateSvc(index) { it.copy(dependsOn = n) } }
                    }
                }
            }
        }

        OmniButton(
            label = "Add service",
            color = OmniColors.green,
            modifier = Modifier.fillMaxWidth(),
            onClick = {
                val list = draft.services.toMutableList()
                list.add(ComposeServiceDraft(serviceName = "", isExpanded = true))
                onChange(draft.copy(services = list))
            },
        )

        TopLevelSectionsEditor(draft, onChange)
    }
}

@Composable
private fun TopLevelSectionsEditor(draft: ComposeStackDraft, onChange: (ComposeStackDraft) -> Unit) {
    // ── Top-level volumes ──
    OmniCard(modifier = Modifier.fillMaxWidth(), leftAccent = OmniColors.amber) {
        var expanded by remember { mutableStateOf(draft.topVolumes.isNotEmpty()) }
        Column(Modifier.fillMaxWidth().padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(
                Modifier.fillMaxWidth().clickable { expanded = !expanded },
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(
                        if (expanded) Icons.Filled.ExpandLess else Icons.Filled.ExpandMore,
                        contentDescription = null, tint = OmniColors.amber,
                    )
                    Spacer(Modifier.width(6.dp))
                    Text("Top-level volumes", fontWeight = FontWeight.Bold, fontFamily = OmniFonts.mono)
                }
                if (draft.topVolumes.isNotEmpty()) {
                    OmniTag("${draft.topVolumes.size}", color = OmniColors.amber)
                }
            }
            if (expanded) {
                Text(
                    "Named volumes referenced by services must be declared here. Set external: true to use a pre-existing volume Docker manages outside this stack.",
                    fontSize = 11.sp, color = OmniColors.textMuted,
                )
                draft.topVolumes.forEachIndexed { i, vol ->
                    val dimmed = vol.isCommentedOut
                    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        OutlinedTextField(
                            value = vol.name,
                            onValueChange = { v ->
                                val list = draft.topVolumes.toMutableList()
                                list[i] = vol.copy(name = v.trim())
                                onChange(draft.copy(topVolumes = list))
                            },
                            label = { Text("Volume name") },
                            placeholder = { Text("mydata") },
                            singleLine = true,
                            colors = omniTextFieldColors(),
                            modifier = Modifier.weight(1f).then(if (dimmed) Modifier.alpha(0.45f) else Modifier),
                        )
                        Column(horizontalAlignment = Alignment.CenterHorizontally) {
                            Text("Ext", fontSize = 10.sp, color = OmniColors.textMuted)
                            Switch(
                                checked = vol.external,
                                onCheckedChange = { v ->
                                    val list = draft.topVolumes.toMutableList()
                                    list[i] = vol.copy(external = v)
                                    onChange(draft.copy(topVolumes = list))
                                },
                            )
                        }
                        if (dimmed) {
                            Text("# commented", fontSize = 9.sp, color = OmniColors.textMuted, fontFamily = OmniFonts.mono)
                        }
                        IconButton(onClick = {
                            val list = draft.topVolumes.toMutableList()
                            list.removeAt(i)
                            onChange(draft.copy(topVolumes = list))
                        }) { Icon(Icons.Filled.Delete, "Remove volume", tint = OmniColors.red, modifier = Modifier.size(20.dp)) }
                    }
                }
                TextButton(onClick = {
                    val list = draft.topVolumes.toMutableList()
                    list.add(TopLevelVolumeDraft())
                    onChange(draft.copy(topVolumes = list))
                }) {
                    Icon(Icons.Filled.Add, null, modifier = Modifier.size(16.dp))
                    Spacer(Modifier.width(4.dp))
                    Text("Add volume", fontSize = 12.sp)
                }
            }
        }
    }

    // ── Top-level networks ──
    OmniCard(modifier = Modifier.fillMaxWidth(), leftAccent = OmniColors.cyan) {
        var expanded by remember { mutableStateOf(draft.topNetworks.isNotEmpty()) }
        Column(Modifier.fillMaxWidth().padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(
                Modifier.fillMaxWidth().clickable { expanded = !expanded },
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(
                        if (expanded) Icons.Filled.ExpandLess else Icons.Filled.ExpandMore,
                        contentDescription = null, tint = OmniColors.cyan,
                    )
                    Spacer(Modifier.width(6.dp))
                    Text("Top-level networks", fontWeight = FontWeight.Bold, fontFamily = OmniFonts.mono)
                }
                if (draft.topNetworks.isNotEmpty()) {
                    OmniTag("${draft.topNetworks.size}", color = OmniColors.cyan)
                }
            }
            if (expanded) {
                Text(
                    "Custom networks referenced by services must be declared here. Set a driver (bridge/overlay/…) or external: true to attach to a network Docker manages outside this stack.",
                    fontSize = 11.sp, color = OmniColors.textMuted,
                )
                draft.topNetworks.forEachIndexed { i, net ->
                    val dimmed = net.isCommentedOut
                    val dimMod = if (dimmed) Modifier.alpha(0.45f) else Modifier
                    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            OutlinedTextField(
                                value = net.name,
                                onValueChange = { v ->
                                    val list = draft.topNetworks.toMutableList()
                                    list[i] = net.copy(name = v.trim())
                                    onChange(draft.copy(topNetworks = list))
                                },
                                label = { Text("Network name") },
                                placeholder = { Text("frontend") },
                                singleLine = true,
                                colors = omniTextFieldColors(),
                                modifier = Modifier.weight(1f).then(dimMod),
                            )
                            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                                Text("Ext", fontSize = 10.sp, color = OmniColors.textMuted)
                                Switch(
                                    checked = net.external,
                                    onCheckedChange = { v ->
                                        val list = draft.topNetworks.toMutableList()
                                        list[i] = net.copy(external = v)
                                        onChange(draft.copy(topNetworks = list))
                                    },
                                )
                            }
                            if (dimmed) {
                                Text("# commented", fontSize = 9.sp, color = OmniColors.textMuted, fontFamily = OmniFonts.mono)
                            }
                            IconButton(onClick = {
                                val list = draft.topNetworks.toMutableList()
                                list.removeAt(i)
                                onChange(draft.copy(topNetworks = list))
                            }) { Icon(Icons.Filled.Delete, "Remove network", tint = OmniColors.red, modifier = Modifier.size(20.dp)) }
                        }
                        OutlinedTextField(
                            value = net.driver,
                            onValueChange = { v ->
                                val list = draft.topNetworks.toMutableList()
                                list[i] = net.copy(driver = v.trim())
                                onChange(draft.copy(topNetworks = list))
                            },
                            label = { Text("Driver (optional)") },
                            placeholder = { Text("bridge / overlay / macvlan") },
                            singleLine = true,
                            colors = omniTextFieldColors(),
                            modifier = Modifier.fillMaxWidth().then(dimMod),
                        )
                    }
                }
                TextButton(onClick = {
                    val list = draft.topNetworks.toMutableList()
                    list.add(TopLevelNetworkDraft())
                    onChange(draft.copy(topNetworks = list))
                }) {
                    Icon(Icons.Filled.Add, null, modifier = Modifier.size(16.dp))
                    Spacer(Modifier.width(4.dp))
                    Text("Add network", fontSize = 12.sp)
                }
            }
        }
    }
}

@Composable
private fun Field(label: String, value: String, placeholder: String, onChange: (String) -> Unit) {
    OutlinedTextField(
        value = value,
        onValueChange = onChange,
        label = { Text(label) },
        placeholder = { Text(placeholder) },
        singleLine = true,
        colors = omniTextFieldColors(),
        modifier = Modifier.fillMaxWidth(),
    )
}

@Composable
fun ListEditor(title: String, items: List<String>, placeholderText: String, onChange: (MutableList<String>) -> Unit) {
    Column(Modifier.fillMaxWidth().padding(top = 12.dp)) {
        Text(title, fontSize = 13.sp, color = OmniColors.cyan, fontWeight = FontWeight.Bold, modifier = Modifier.padding(bottom = 6.dp))
        Column(
            Modifier
                .fillMaxWidth()
                .padding(start = 12.dp)
                .clip(RoundedCornerShape(8.dp))
                .border(1.dp, OmniColors.bg2, RoundedCornerShape(8.dp))
                .padding(12.dp)
        ) {
            items.forEachIndexed { i, item ->
                Row(Modifier.fillMaxWidth().padding(vertical = 3.dp), verticalAlignment = Alignment.CenterVertically) {
                    OutlinedTextField(
                        value = item,
                        onValueChange = {
                            val n = items.toMutableList(); n[i] = it; onChange(n)
                        },
                        placeholder = { Text(placeholderText) },
                        singleLine = true,
                        colors = omniTextFieldColors(),
                        modifier = Modifier.weight(1f),
                    )
                    IconButton(onClick = {
                        val n = items.toMutableList(); n.removeAt(i); onChange(n)
                    }) { Icon(Icons.Filled.Delete, "Remove", tint = OmniColors.red, modifier = Modifier.size(20.dp)) }
                }
            }
            TextButton(onClick = { val n = items.toMutableList(); n.add(""); onChange(n) }) {
                Icon(Icons.Filled.Add, null, modifier = Modifier.size(16.dp))
                Spacer(Modifier.width(4.dp))
                Text("Add", fontSize = 12.sp)
            }
        }
    }
}
