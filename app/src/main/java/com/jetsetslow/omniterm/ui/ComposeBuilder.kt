package com.jetsetslow.omniterm.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
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
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.jetsetslow.omniterm.ui.theme.OmniColors
import com.jetsetslow.omniterm.ui.theme.OmniFonts
import java.util.UUID
import androidx.compose.ui.res.stringResource
import com.jetsetslow.omniterm.R

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
    // Podman rootless UID/GID mapping. `keep-id` maps the SSH user's host identity into the
    // container; other values are preserved when parsing an existing Compose file.
    var usernsMode: String = "",
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
    // ── read-only facts the parser records about constructs the visual editor does NOT own ──
    // Never rendered; they exist so validation can reason about the real file.
    //
    // [anchorName] is the "&name" on this service's header ("netbox: &netbox") and [aliasRefs] the
    // anchors its body pulls in ("<<: *netbox"). [inheritsImage] is true when the service gets its
    // image from somewhere other than a literal `image:` line — a merge key, `extends:`, or
    // `build:` — so "needs an image" must not fire. [dependsOnRefs] lists every service depended
    // on INCLUDING the map form (`depends_on: {db: {condition: service_healthy}}`) that the
    // editable [dependsOn] list cannot hold.
    var anchorName: String = "",
    var inheritsImage: Boolean = false,
    val aliasRefs: MutableList<String> = mutableListOf(),
    val dependsOnRefs: MutableList<String> = mutableListOf(),
    // Array keys whose body is a MAP or long-form sequence (`environment: {KEY: v}`,
    // `ports: [- target: 5432]`). The list editor cannot represent them, so they are parsed as
    // empty and never rewritten — rewriting one in place produced a list glued on top of the
    // surviving map entries, i.e. invalid YAML.
    val unmodeledArrayKeys: MutableSet<String> = mutableSetOf(),
    // Body keys whose value is a block (a list, a map or a `|`/`>` text block) and the lines that
    // block spans. Setting `command` on a service that wrote it as a list duplicated the key
    // instead of replacing the list.
    val blockSpan: MutableMap<String, IntRange> = mutableMapOf(),
    // Every other service this one names outside the editable depends_on list: map-form depends_on
    // entries, links, volumes_from, `network_mode`/`ipc`/`pid: service:<name>` and a same-file
    // extends. Read only: validation checks each name, and a rename rewrites them in place.
    val serviceRefs: MutableList<ComposeServiceRef> = mutableListOf(),
    // `environment:` as a map (`KEY: value`). Its rows read as KEY=value; each original row's line
    // is kept so a save writes untouched rows back exactly as they were.
    var environmentIsMap: Boolean = false,
    val environmentRowLine: MutableMap<String, Int> = mutableMapOf(),
    // `depends_on:` as a map (`db: {condition: service_healthy}`). Its rows are the service names;
    // each original entry's lines, condition included, are kept so a save writes them back as they were.
    var dependsOnIsMap: Boolean = false,
    val dependsOnEntrySpan: MutableMap<String, IntRange> = mutableMapOf(),
    // Read only, for validation: `network_mode:`, the replica count (`scale:` or `deploy.replicas`)
    // and the profiles the service starts under.
    var networkMode: String = "",
    var replicas: Int = 1,
    val profiles: MutableList<String> = mutableListOf(),
)

/** A service named by another one at [line], under the key [via] (`links`, `extends`, …). */
data class ComposeServiceRef(val name: String, val line: Int, val via: String)

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
    // The entry's own `driver:` line (-1 when it has none), so changing the driver edits that line.
    var driverLine: Int = -1,
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
    // Whether the parsed file actually had a `services:` section. Compose file format v1 — the only
    // version without one — puts service names at the top level; Compose V2 and podman-compose both
    // refuse to run it. Format 2.x, 3.x and the current Compose Spec are structurally identical here
    // (`version:` is obsolete and merely informative), so they need no special casing.
    var hasServicesSection: Boolean = true,
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
    // podman-compose's supported x-podman.in_pod extension. Blank [podmanPodName] asks the
    // provider to use its stable default `pod_<project>` name.
    var podmanPodEnabled: Boolean = false,
    var podmanPodName: String = "",
    // Source positions allow existing YAML to be updated surgically.
    var xPodmanSrcHeader: Int = -1,
    var xPodmanInPodSrcLine: Int = -1,
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

// Value of a "- " list item. YAML only treats " #" as a comment OUTSIDE a quoted scalar, so a
// fully quoted item keeps its text verbatim while a plain one drops its trailing comment. Without
// this, `- "${PORT:-9394}:9394" # exporter` kept the comment inside the value: it failed port
// validation, and any later rewrite of that list re-quoted the whole thing (comment included),
// producing invalid YAML.
private fun String.unquoteYamlListItem(): String {
    val t = trim()
    val quoted = t.length >= 2 &&
        ((t.startsWith("\"") && t.endsWith("\"")) || (t.startsWith("'") && t.endsWith("'")))
    return if (quoted) t.substring(1, t.length - 1) else t.stripYamlInlineComment().unquoteYaml()
}

// The scalar after a key's colon. A comment alone is no value at all: `volumes: # data` opens a
// block, and reading "# data" as its value hid the list below it, so a later edit wrote a second
// `volumes:` key. A quoted value keeps its text when a comment trails it.
private fun yamlValueAfterKey(content: String): String {
    val rest = content.substringAfter(":").trim()
    if (rest.startsWith("#")) return ""
    val quote = rest.firstOrNull()?.takeIf { it == '"' || it == '\'' }
    if (quote != null) {
        val close = rest.indexOf(quote, 1)
        if (close > 0 && rest.substring(close + 1).trim().let { it.isEmpty() || it.startsWith("#") }) {
            return rest.substring(1, close)
        }
    }
    return rest.stripYamlInlineComment().unquoteYaml()
}

// A top-level `volumes: {}` / `networks: {}`. It is what the renderer leaves when every entry under
// a section is commented out: a bare header with only comments below it is null, which Compose
// rejects with "volumes must be a mapping".
private fun isEmptyFlowMapping(content: String): Boolean =
    content.substringAfter(":").trim().stripYamlInlineComment() == "{}"

// The indent a line has once a leading comment marker is read as spaces, as the parser sees it.
private fun seeThroughIndent(line: String): Int {
    val lead = line.takeWhile { it == ' ' }
    val rest = line.substring(lead.length)
    if (!rest.startsWith("#")) return lead.length
    val hashes = rest.takeWhile { it == '#' }.length
    val afterHashes = rest.substring(hashes)
    val space = if (afterHashes.startsWith(" ")) 1 else 0
    return lead.length + hashes + space + indentOfLine(afterHashes.substring(space))
}

// A KEY=value row as a map-form environment entry. A row with no "=" passes the variable through
// from the shell that runs Compose, which the map form writes as a key with no value.
private fun yamlEnvironmentEntry(row: String): String {
    val name = yamlPlainOrSingleQuoted(row.substringBefore("=").trim())
    return if ("=" in row) "$name: ${yamlDoubleQuoted(row.substringAfter("="))}" else "$name:"
}

// [line] with the service [ref] names renamed to [newName]. The search starts past the key, so a
// service called "service" in `network_mode: service:service` is the name, not the prefix.
private fun renameServiceRef(line: String, ref: ComposeServiceRef, newName: String): String {
    val keyColon = line.indexOf(':')
    val from = when (ref.via) {
        "depends_on" -> 0
        "links", "volumes_from" -> line.indexOf('-') + 1
        "network_mode", "ipc", "pid" -> line.indexOf("service:", keyColon + 1).takeIf { it >= 0 }?.plus("service:".length)
        // `extends: web`, `service: web` inside a block extends, or `extends: { service: web }`.
        else -> if (line.substring(keyColon + 1).trimStart().startsWith("{")) {
            Regex("""service\s*:""").find(line, keyColon + 1)?.let { it.range.last + 1 }
        } else keyColon + 1
    } ?: return line
    val match = Regex("(?<![A-Za-z0-9_.-])${Regex.escape(ref.name)}(?![A-Za-z0-9_.-])").find(line, from) ?: return line
    return line.replaceRange(match.range, newName)
}

// The indent and any comment marker a line starts with.
private fun linePrefix(line: String): String = line.substring(0, line.length - line.trimStart(' ', '#').length)

// [line] with the key at its start renamed to [newKey], keeping its indent, comment marker, quotes,
// anchor and trailing comment.
private fun renameYamlKey(line: String, newKey: String): String {
    val start = line.indexOfFirst { it != ' ' && it != '#' }
    val colon = line.indexOf(':', start.coerceAtLeast(0))
    if (start < 0 || colon < 0) return line
    val quote = line[start].takeIf { it == '"' || it == '\'' }
    return line.substring(0, start) + (if (quote != null) "$quote$newKey$quote" else newKey) + line.substring(colon)
}

// A YAML anchor ("&name") or alias ("*name") standing alone as a line's value.
private val ANCHOR_ONLY = Regex("""^&\S+$""")
private val ALIAS_ONLY = Regex("""^\*(\S+)$""")

/**
 * The key of a BLOCK mapping line — `web:` or, when the author anchors it for reuse, `web: &web` —
 * or null when the line is a scalar (`image: nginx`) or a list item.
 *
 * An anchor lives on the key's own line, so an anchored header no longer ends with ":". Testing
 * for a trailing colon therefore made `netbox: &netbox` invisible as a service header, and the
 * indent scale was handed to its first child key instead — `depends_on:`, `healthcheck:` and
 * `volumes:` each parsed as a service of their own (seen in netbox-docker).
 */
private fun blockKeyOf(content: String): String? {
    if (content.startsWith("-") || !content.contains(":")) return null
    val key = content.substringBefore(":").trim()
    if (key.isEmpty() || key.contains(" ")) return null
    val rest = content.substringAfter(":").trim().stripYamlInlineComment()
    return if (rest.isEmpty() || rest.startsWith("#") || ANCHOR_ONLY.matches(rest)) key else null
}

/** The anchor name declared on a block key line, or "" when it declares none. */
private fun anchorOf(content: String): String =
    content.substringAfter(":", "").trim().stripYamlInlineComment()
        .takeIf { ANCHOR_ONLY.matches(it) }?.removePrefix("&").orEmpty()

// Service keys the builder models as an editable list of scalars.
private val MODELED_ARRAY_KEYS = setOf("ports", "environment", "volumes", "networks", "depends_on")

// A list item that is really a mapping entry — Compose's long syntax, e.g. "- target: 5432".
// YAML opens a mapping only on a colon followed by WHITESPACE, which is what separates the long
// form from a short-syntax volume ("journal_data:/data") or port ("8000:8000").
private val LONG_FORM_ITEM = Regex("""^[A-Za-z_][A-Za-z0-9_.-]*:\s+\S""")

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

// A list row as written to a file: ports always double-quoted (YAML 1.1 reads 22:22 as a number in
// base 60), anything else plain unless it needs quoting to stay one string.
private fun yamlListItem(value: String, quote: Boolean): String =
    if (quote) yamlDoubleQuoted(value) else yamlPlainOrSingleQuoted(value)

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

private val FLOW_EXTENDS_SERVICE = Regex("(?:^|[,{]\\s*)service\\s*:\\s*([^,}]+)")
private val FLOW_EXTENDS_FILE = Regex("(?:^|[,{]\\s*)file\\s*:")
private val FLOW_EXTERNAL_TRUE = Regex("(?:^|[,{]\\s*)external\\s*:\\s*true(?:\\s*[,}]|$)")
private val FLOW_DRIVER = Regex("(?:^|[,{]\\s*)driver\\s*:\\s*([^,}]+)")

// Compose interpolates ${VAR}, ${VAR:-default} and $VAR from the environment/.env before it ever
// reads the value, so what a mapping resolves to is unknowable here.
// The closing brace must be escaped: Android's regex engine is ICU, not the JDK's, and ICU rejects a
// bare "}" outside a character class as a syntax error. Desktop JVM tolerates it, so this compiles
// clean in unit tests and only throws once it reaches a device.
private val YAML_INTERPOLATION = Regex("""\$\{[^}]*\}|\$[A-Za-z_][A-Za-z0-9_]*""")
private const val INTERPOLATION_MASK = "\u0001"

private fun isValidPortMapping(value: String): Boolean {
    val unquoted = value.trim().stripYamlInlineComment()
        .removeSurrounding("\"").removeSurrounding("'").trim()
    if (unquoted.isBlank()) return false
    // Mask interpolations to a single sentinel BEFORE splitting on ":". A default value carries its
    // own colon ("${DAWARICH_APP_PORT:-3001}:3000"), so an unmasked split saw three segments and
    // validated the literal "-3001}" as a port number — a false "invalid port mapping" on a file
    // Compose accepts. Masked, the structure is still checked and only the variable part is trusted.
    val raw = YAML_INTERPOLATION.replace(unquoted, INTERPOLATION_MASK)
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
        if (p.contains(INTERPOLATION_MASK)) return@all true
        portRegex.matches(p) && p.split("-").all { it.toIntOrNull()?.let { n -> n in 1..65535 } == true }
    }
}

/**
 * Old name → new name for each service renamed in [draft] since [baseline]. A name another service
 * now holds is left out, since references to it still mean that service.
 */
internal fun composeServiceRenames(draft: ComposeStackDraft, baseline: ComposeStackDraft?): Map<String, String> {
    if (baseline == null) return emptyMap()
    val before = baseline.services.associateBy { it.id }
    val names = draft.services.map { it.serviceName.trim() }.toSet()
    return draft.services.mapNotNull { svc ->
        val old = before[svc.id]?.serviceName?.trim() ?: return@mapNotNull null
        val new = svc.serviceName.trim()
        if (old != new && new.isNotEmpty() && old !in names) old to new else null
    }.toMap()
}

// The services this one waits for: the editable rows, or every name the parser read when the file
// uses a long form the rows cannot hold.
private fun ComposeServiceDraft.dependencyNames(): List<String> =
    if ("depends_on" in unmodeledArrayKeys) dependsOnRefs else dependsOn

// What a reference under [via] is called in a message: "<service> <phrase> <name>".
private fun serviceRefPhrase(via: String): String = when (via) {
    "links" -> "links to"
    "volumes_from" -> "takes volumes from"
    "network_mode" -> "uses the network of"
    "ipc" -> "shares the IPC namespace of"
    "pid" -> "shares the process namespace of"
    "extends" -> "extends"
    else -> "depends on"
}

/**
 * What would stop [draft] from deploying. [baseline] is the draft as parsed from the file, so a
 * renamed service's references count as following it, the way the saved file writes them.
 */
fun validateComposeDraft(draft: ComposeStackDraft, baseline: ComposeStackDraft? = null): List<String> {
    val issues = mutableListOf<String>()
    // Compose file format v1 (services at the top level, no `services:` key) is the one version
    // neither Docker Compose V2 nor podman-compose can run, and the visual editor cannot show it.
    // Say so instead of presenting an empty stack the user might then save over the real file.
    if (!draft.hasServicesSection) {
        issues += "No services: section. This looks like the Compose v1 format, " +
            "which current Docker/Podman Compose cannot run — convert it in Raw YAML."
    }
    val activeServices = draft.services.filterNot { it.isCommentedOut }
    // Compose has nothing to run once every service is deleted or commented out, and the file it
    // is left with (`services:` holding only comments) is one it refuses to read.
    if (draft.hasServicesSection && activeServices.isEmpty()) {
        issues += "No active services. Compose needs at least one — add a service or uncomment one."
    }
    val names = activeServices.map { it.serviceName.trim() }
    val duplicates = names.filter { it.isNotBlank() }.groupingBy { it }.eachCount().filterValues { it > 1 }.keys
    for ((idx, svc) in draft.services.withIndex()) {
        if (svc.isCommentedOut) continue
        val label = svc.serviceName.ifBlank { "Service ${idx + 1}" }
        if (svc.serviceName.isBlank()) issues += "$label needs a service name."
        if (svc.serviceName.isNotBlank() && !isValidComposeName(svc.serviceName)) {
            issues += "$label has an invalid service name. Use letters, numbers, dots, dashes, or underscores."
        }
        // A service can legitimately have no `image:` line: `build:` produces one, `extends:` and a
        // `<<: *base` merge inherit one. Demanding a literal image failed every anchor-based file
        // (Airflow, Sentry, netbox) on services Compose itself accepts.
        if (svc.image.isBlank() && !svc.inheritsImage) {
            issues += "$label needs an image in the visual editor. Use Raw YAML for build-only services."
        }
        svc.ports.filter { it.isNotBlank() && !isValidPortMapping(it) }.forEach {
            issues += "$label has an invalid port mapping: $it"
        }
        if (listOf(svc.ports, svc.environment, svc.volumes, svc.networks, svc.dependsOn).any { list -> list.any { it.isBlank() } }) {
            issues += "$label has empty list rows. Remove or fill them before deploy."
        }
        // Compose refuses a networks or depends_on list that names something twice, and a map
        // cannot hold one environment variable twice.
        listOf("networks" to svc.networks, "depends_on" to svc.dependsOn).forEach { (key, list) ->
            list.map { it.trim() }.filter { it.isNotBlank() }.groupingBy { it }.eachCount().filterValues { it > 1 }.keys
                .forEach { issues += "$label lists $it twice under $key." }
        }
        if (svc.environmentIsMap) {
            svc.environment.filter { it.isNotBlank() }.map { it.substringBefore("=").trim() }
                .groupingBy { it }.eachCount().filterValues { it > 1 }.keys
                .forEach { issues += "$label sets $it twice under environment." }
        }
        if (svc.networkMode.isNotBlank() && (svc.networks.any { it.isNotBlank() } || "networks" in svc.unmodeledArrayKeys)) {
            issues += "$label sets both network_mode and networks. Compose allows only one of them."
        }
        // Rows typed into a list the file expresses as a map/long syntax are dropped on save
        // rather than written, because writing them would strand the original entries.
        svc.unmodeledArrayKeys.filter { key ->
            when (key) {
                "ports" -> svc.ports
                "environment" -> svc.environment
                "volumes" -> svc.volumes
                "networks" -> svc.networks
                else -> svc.dependsOn
            }.any { it.isNotBlank() }
        }.forEach {
            issues += "$label declares $it in map or long syntax. Edit it in Raw YAML — rows added here are not saved."
        }
    }
    duplicates.forEach { issues += "Duplicate active service name: $it" }

    // Commenting a service out silently breaks whatever still points at it. Both references are
    // resolved against services the file actually defines, so a merge of an anchor declared by a
    // top-level x- extension (which the builder does not model) never produces a false alarm.
    val liveNames = activeServices.map { it.serviceName.trim() }.toSet()
    val commentedByAnchor = draft.services.filter { it.isCommentedOut && it.anchorName.isNotBlank() }
        .associateBy { it.anchorName }
    val commentedNames = draft.services.filter { it.isCommentedOut }.map { it.serviceName.trim() }.toSet()
    // A save rewrites every reference to a renamed service, so references follow renames here too.
    val renames = composeServiceRenames(draft, baseline)
    fun followed(name: String) = name.trim().let { renames[it] ?: it }
    // Another -f file of the stack may define the service, so only a single-file stack can tell
    // that a name is missing rather than defined elsewhere.
    val singleFile = !draft.composeConfigFiles.contains(",")
    fun missing(name: String) = name.isNotBlank() && name !in liveNames && (singleFile || name in commentedNames)
    fun reason(name: String) = if (name in commentedNames) "which is commented out" else "which this file does not define"
    val byName = activeServices.associateBy { it.serviceName.trim() }
    val declaredVolumes = draft.topVolumes.filterNot { it.isCommentedOut }.map { it.name.trim() }.toSet()
    val declaredNetworks = draft.topNetworks.filterNot { it.isCommentedOut }.map { it.name.trim() }.toSet()
    // A same-file extends hands the extending service everything the base has, its depends_on and
    // container_name included.
    fun ComposeServiceDraft.base(): ComposeServiceDraft? =
        serviceRefs.firstOrNull { it.via == "extends" }?.let { byName[followed(it.name)] }
    // Compose starts what a service links to, takes volumes from or shares a namespace with first,
    // just as it does with depends_on.
    fun ComposeServiceDraft.startsAfter(): List<String> =
        (dependencyNames() + serviceRefs.filter { it.via != "depends_on" && it.via != "extends" }.map { it.name } +
            base()?.takeIf { it !== this }?.dependencyNames().orEmpty()).map(::followed)
    for (svc in activeServices) {
        val label = svc.serviceName.ifBlank { "A service" }
        svc.aliasRefs.mapNotNull { commentedByAnchor[it] }.forEach {
            issues += "$label merges &${it.anchorName} from ${it.serviceName}, which is commented out."
        }
        svc.dependencyNames().map(::followed).filter(::missing).distinct()
            .forEach { issues += "$label depends on $it, ${reason(it)}." }
        svc.serviceRefs.filter { it.via != "depends_on" }.map { it.via to followed(it.name) }.distinct()
            .filter { missing(it.second) }
            .forEach { (via, name) -> issues += "$label ${serviceRefPhrase(via)} $name, ${reason(name)}." }
        // A service with no profiles starts by default; one it waits for that has profiles does not,
        // and Compose then reports it as undefined.
        if (svc.profiles.isEmpty()) {
            svc.startsAfter().distinct().mapNotNull { byName[it] }.filter { it.profiles.isNotEmpty() }.forEach {
                issues += "$label depends on ${it.serviceName}, which starts only with the profile " +
                    "${it.profiles.joinToString(" or ")}."
            }
        }
        // Compose refuses a named volume or network that the top level does not declare.
        if (singleFile) {
            svc.volumes.mapNotNull(::namedVolumeFrom).filter { it !in declaredVolumes }.distinct()
                .forEach { issues += "$label uses the volume $it, which the volumes: section does not declare." }
            svc.networks.map { it.trim() }.filter { it.isNotBlank() && it != "default" && it !in declaredNetworks }.distinct()
                .forEach { issues += "$label joins the network $it, which the networks: section does not declare." }
        }
        val containerName = svc.containerName.ifBlank { svc.base()?.containerName.orEmpty() }
        val replicas = if (svc.replicas != 1) svc.replicas else svc.base()?.replicas ?: 1
        if (containerName.isNotBlank() && replicas > 1) {
            issues += "$label sets container_name, so it cannot run $replicas replicas. Container names must be unique."
        }
    }
    activeServices.mapNotNull { svc -> svc.containerName.ifBlank { svc.base()?.containerName.orEmpty() }.takeIf { it.isNotBlank() } }
        .groupingBy { it }.eachCount().filterValues { it > 1 }.keys
        .forEach { issues += "More than one service uses the container name $it." }
    composeDependencyCycle(activeServices.associate { svc ->
        svc.serviceName.trim() to svc.startsAfter().filter { it in liveNames }
    })?.let { issues += "Dependency cycle: ${it.joinToString(" → ")}. Compose cannot start any of these services." }
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
    if (draft.runtime == "podman" && draft.podmanPodEnabled &&
        draft.podmanPodName.isNotBlank() && !isValidComposeName(draft.podmanPodName)
    ) {
        issues += "Pod name has invalid characters. Use letters, numbers, dots, dashes, or underscores."
    }
    return issues.distinct()
}

// The first loop in [graph] (service → services it waits for), as a path that ends where it began.
private fun composeDependencyCycle(graph: Map<String, List<String>>): List<String>? {
    val done = mutableSetOf<String>()
    val path = mutableListOf<String>()
    fun visit(node: String): List<String>? {
        val at = path.indexOf(node)
        if (at >= 0) return path.subList(at, path.size) + node
        if (!done.add(node)) return null
        path += node
        for (next in graph[node].orEmpty()) visit(next)?.let { return it }
        path.removeAt(path.lastIndex)
        return null
    }
    for (node in graph.keys) visit(node)?.let { return it }
    return null
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
    var sawServicesSection = false
    var inTopVolumes = false
    var inTopNetworks = false
    var inXPodman = false
    var current: ComposeServiceDraft? = null
    var currentTopVol: TopLevelVolumeDraft? = null
    var currentTopNet: TopLevelNetworkDraft? = null
    var serviceIndent = -1            // indent of service-name keys (e.g. 2)
    var topSectionItemIndent = -1     // indent of keys directly under volumes:/networks: (e.g. 2)
    var entryPropIndent = -1          // indent of the current entry's own properties

    // Whether a "name:" line starts an entry of the top-level volumes:/networks: section. Only LIVE
    // entries establish the section's indent scale: a manually commented entry ("  # db_storage:")
    // see-throughs to a shifted indent and used to set a bogus scale, swallowing every live entry
    // after it. Commented entries are matched by a tolerance window + name check instead.
    fun isTopSectionEntry(keyName: String, indent: Int, isCommented: Boolean): Boolean =
        if (!isCommented) {
            if (topSectionItemIndent == -1) topSectionItemIndent = indent
            indent == topSectionItemIndent
        } else {
            val max = if (topSectionItemIndent == -1) 4 else topSectionItemIndent + 2
            indent in 1..max && isValidComposeName(keyName) && keyName !in TOP_ENTRY_CONFIG_KEYS
        }
    var arrayKey = ""                 // current "- " list context (ports/environment/…)
    var arrayKeyLine = -1
    var arrayKeyIndent = -1           // indent of the current array key, to spot its body's shape
    var dependsOnIndent = -1          // indent of a `depends_on:` whose body is a map
    var dependsOnEntryIndent = -1     // indent of that map's entry names
    var spanKey = ""                  // body key whose block value is still open
    var spanIsText = false            // that block is a `|`/`>` text block, not YAML structure
    var extendsFromFile = false       // the open `extends:` names a service in another file
    var envEntryIndent = -1           // indent of a map-form environment's entries
    var dependsOnEntry = ""           // the map-form depends_on entry whose lines are being read

    fun indentOf(s: String) = s.takeWhile { it == ' ' }.length
    fun finish() {
        current?.let {
            // A single commented key-only line with no body and no modeled fields is just a
            // comment that happens to look like a service header ("# Database:" in a note),
            // not a commented-out service. Keep it out of the structured view.
            val phantom = it.isCommentedOut && it.srcStart == it.srcEnd &&
                it.image.isBlank() && it.containerName.isBlank() && it.restart.isBlank() &&
                it.command.isBlank() && it.usernsMode.isBlank() &&
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
        // Any key at indent 0 CLOSES whichever section is open, then possibly opens a new one.
        // Closing unconditionally matters: a top-level key that carries an inline value
        // (`version: "3.8"`, `networks: {}`, `x-shared: &base`) used to fall through with the
        // previous section still open, so the next section's parser absorbed it as one of its own
        // entries and stretched that entry's source span over an unrelated line.
        if (indent == 0 && !content.startsWith("-") && content.contains(":")) {
            val k = content.substringBefore(":").trim()
            val sectionKey = blockKeyOf(content)
                ?: k.takeIf { (it == "volumes" || it == "networks") && isEmptyFlowMapping(content) }
            finish(); finishTopVol(); finishTopNet()
            inServices = sectionKey == "services"
            inTopVolumes = sectionKey == "volumes"
            inTopNetworks = sectionKey == "networks"
            inXPodman = sectionKey == "x-podman"
            if (inServices) sawServicesSection = true
            if (inTopVolumes) draft.volumesSrcHeader = idx
            if (inTopNetworks) draft.networksSrcHeader = idx
            if (inXPodman) draft.xPodmanSrcHeader = idx
            serviceIndent = -1; topSectionItemIndent = -1
            if (sectionKey == null && k == "name") {
                val v = yamlValueAfterKey(content)
                if (v.isNotEmpty()) { draft.stackName = v; draft.stackNameSrcLine = idx }
            }
            continue
        }

        // Podman Compose extension documented by podman-compose. `true` selects its default
        // pod_<project> name, `false` disables grouping, and any other scalar is a custom pod name.
        if (inXPodman && indent > 0 && content.contains(":")) {
            val key = content.substringBefore(":").trim()
            if (key == "in_pod") {
                val value = yamlValueAfterKey(content)
                draft.xPodmanInPodSrcLine = idx
                when {
                    value.equals("false", ignoreCase = true) -> {
                        draft.podmanPodEnabled = false
                        draft.podmanPodName = ""
                    }
                    value.equals("true", ignoreCase = true) || value.isBlank() -> {
                        draft.podmanPodEnabled = true
                        draft.podmanPodName = ""
                    }
                    else -> {
                        draft.podmanPodEnabled = true
                        draft.podmanPodName = value
                    }
                }
            }
            continue
        }

        // ── top-level volumes: section ──
        if (inTopVolumes && !inServices && !inTopNetworks) {
            if (content.contains(":") && !content.startsWith("-")) {
                val keyName = content.substringBefore(":").trim().unquoteYaml()
                val inlineValue = content.substringAfter(":").trim().stripYamlInlineComment()
                if (isTopSectionEntry(keyName, indent, isCommented)) {
                    finishTopVol()
                    entryPropIndent = -1
                    currentTopVol = TopLevelVolumeDraft(
                        name = keyName,
                        isCommentedOut = isCommented,
                        external = FLOW_EXTERNAL_TRUE.containsMatchIn(inlineValue),
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
                if (entryPropIndent == -1) entryPropIndent = indent
                // Only the entry's own properties: `driver_opts:` and `labels:` hold keys of their own.
                if (indent == entryPropIndent && content.contains(":") && !content.startsWith("-")) {
                    val k = content.substringBefore(":").trim()
                    val v = yamlValueAfterKey(content)
                    if (k == "external" && v == "true") vol.external = true
                }
            }
            continue
        }

        // ── top-level networks: section ──
        if (inTopNetworks && !inServices && !inTopVolumes) {
            if (content.contains(":") && !content.startsWith("-")) {
                val keyName = content.substringBefore(":").trim().unquoteYaml()
                val inlineValue = content.substringAfter(":").trim().stripYamlInlineComment()
                if (isTopSectionEntry(keyName, indent, isCommented)) {
                    finishTopNet()
                    entryPropIndent = -1
                    currentTopNet = TopLevelNetworkDraft(
                        name = keyName,
                        isCommentedOut = isCommented,
                        driver = FLOW_DRIVER.find(inlineValue)?.groupValues?.get(1)?.trim()?.unquoteYaml().orEmpty(),
                        external = FLOW_EXTERNAL_TRUE.containsMatchIn(inlineValue),
                        srcStart = idx, srcEnd = idx,
                    )
                    continue
                }
            }
            val net = currentTopNet
            if (net != null) {
                if (isCommented && !net.isCommentedOut) continue
                net.srcEnd = idx
                if (entryPropIndent == -1) entryPropIndent = indent
                // Only the entry's own properties: `ipam:` has a `driver:` of its own, which was
                // read as the network's driver.
                if (indent == entryPropIndent && content.contains(":") && !content.startsWith("-")) {
                    val k = content.substringBefore(":").trim()
                    val v = yamlValueAfterKey(content)
                    when (k) {
                        "driver" -> if (v.isNotBlank()) { net.driver = v; net.driverLine = idx }
                        "external" -> if (v == "true") net.external = true
                    }
                }
            }
            continue
        }

        if (!inServices) continue

        // service header (first indented key level under services:)
        val blockKey = blockKeyOf(content)
        if (blockKey != null) {
            val keyName = blockKey.unquoteYaml()
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
                    anchorName = anchorOf(content),
                )
                arrayKey = ""; arrayKeyIndent = -1
                dependsOnIndent = -1; dependsOnEntryIndent = -1
                spanKey = ""
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

        // A block value runs over every deeper line, plus a list written at its key's own indent.
        // The lines of a `|`/`>` text block are text, so nothing in them is read as a key.
        if (spanKey.isNotEmpty()) {
            val inside = indent > svc.bodyIndent ||
                (!spanIsText && indent == svc.bodyIndent && content.startsWith("-"))
            if (inside) {
                svc.blockSpan[spanKey] = svc.blockSpan.getValue(spanKey).first..idx
                if (spanIsText) continue
            } else {
                spanKey = ""
            }
        }

        // Drop an array key whose body turns out to be a map or Compose's long syntax. The list
        // editor cannot hold those, so they are surfaced as empty and — crucially — never
        // rewritten: splicing a freshly generated list over just the `key:` header left the map's
        // own entries stranded underneath it, which is invalid YAML.
        fun demoteArrayKey() {
            if (arrayKey.isEmpty()) return
            svc.unmodeledArrayKeys += arrayKey
            svc.arraySpan.remove(arrayKey)
            when (arrayKey) {
                "ports" -> svc.ports
                "environment" -> svc.environment.also { svc.environmentRowLine.clear(); svc.environmentIsMap = false }
                "depends_on" -> svc.dependsOn.also { svc.dependsOnEntrySpan.clear(); svc.dependsOnIsMap = false }
                "volumes" -> svc.volumes
                "networks" -> svc.networks
                else -> svc.dependsOn
            }.clear()
            arrayKey = ""; arrayKeyIndent = -1
        }

        // list item under the current array key
        if (content.startsWith("-")) {
            val item = content.removePrefix("-").trim().unquoteYamlListItem()
            if (arrayKey.isNotEmpty() && LONG_FORM_ITEM.containsMatchIn(item)) {
                if (arrayKey == "depends_on") svc.dependsOnRefs += item.substringBefore(":").trim()
                demoteArrayKey()
                continue
            }
            when (arrayKey) {
                "ports" -> svc.ports.add(item)
                "environment" -> svc.environment.add(item)
                "volumes" -> svc.volumes.add(item)
                "networks" -> svc.networks.add(item)
                "depends_on" -> { svc.dependsOn.add(item); svc.dependsOnRefs += item }
            }
            if (arrayKey.isNotEmpty()) {
                val prev = svc.arraySpan[arrayKey]
                svc.arraySpan[arrayKey] = (prev?.first ?: arrayKeyLine)..idx
            } else if (spanKey == "links" || spanKey == "volumes_from") {
                // `links: [db:alias]` and `volumes_from: [db:ro]` name a service before any colon;
                // `container:<name>` names a container instead.
                if (!item.startsWith("container:")) svc.serviceRefs += ComposeServiceRef(item.substringBefore(":").trim(), idx, spanKey)
            } else if (spanKey == "profiles") {
                svc.profiles += item
            }
            continue
        }

        // a key under the service
        if (content.contains(":")) {
            val key = content.substringBefore(":").trim()
            val value = yamlValueAfterKey(content)
            // `environment:` written as a map: each `KEY: value` entry is a row, shown as KEY=value
            // and saved back as an entry. A merge key, or anything nested deeper, is still unmodeled.
            if (arrayKey == "environment" && indent > arrayKeyIndent && key != "<<" &&
                (indent == envEntryIndent || (envEntryIndent == -1 && svc.environment.isEmpty())) &&
                value.firstOrNull() !in listOf('{', '[', '|', '>', '&', '*')
            ) {
                envEntryIndent = indent
                val name = key.unquoteYaml()
                val row = if (content.substringAfter(":").trim().let { it.isEmpty() || it.startsWith("#") }) name else "$name=$value"
                svc.environment += row
                svc.environmentRowLine[row] = idx
                svc.environmentIsMap = true
                svc.arraySpan["environment"] = svc.arraySpan.getValue("environment").first..idx
                continue
            }
            // `depends_on:` written as a map: each entry is a row named after the service, and the
            // condition lines under it belong to that entry.
            if (arrayKey == "depends_on" && indent > arrayKeyIndent && (svc.dependsOnIsMap || svc.dependsOn.isEmpty())) {
                if (dependsOnEntryIndent == -1) dependsOnEntryIndent = indent
                if (indent == dependsOnEntryIndent) {
                    dependsOnEntry = key.unquoteYaml()
                    svc.dependsOn += dependsOnEntry
                    svc.dependsOnRefs += dependsOnEntry
                    svc.serviceRefs += ComposeServiceRef(dependsOnEntry, idx, "depends_on")
                    svc.dependsOnEntrySpan[dependsOnEntry] = idx..idx
                } else if (dependsOnEntry.isNotEmpty()) {
                    svc.dependsOnEntrySpan[dependsOnEntry] = svc.dependsOnEntrySpan.getValue(dependsOnEntry).first..idx
                }
                svc.dependsOnIsMap = true
                svc.arraySpan["depends_on"] = svc.arraySpan.getValue("depends_on").first..idx
                continue
            }
            // A key nested INSIDE the open array key means that key's body is a map, not a list.
            if (arrayKey.isNotEmpty() && indent > arrayKeyIndent) demoteArrayKey() else arrayKey = ""
            // Map-form depends_on: its entry names are the real dependencies. Recorded read-only so
            // "commented out a service something still depends on" is catchable either way.
            if (dependsOnIndent >= 0 && indent > dependsOnIndent) {
                if (dependsOnEntryIndent == -1) dependsOnEntryIndent = indent
                if (indent == dependsOnEntryIndent) {
                    val name = key.unquoteYaml()
                    svc.dependsOnRefs += name
                    svc.serviceRefs += ComposeServiceRef(name, idx, "depends_on")
                }
            } else if (dependsOnIndent >= 0 && indent <= dependsOnIndent) {
                dependsOnIndent = -1; dependsOnEntryIndent = -1
            }
            // Only the service's own keys are its fields. A key nested deeper belongs to a block:
            // `restart: true` under a depends_on entry was read as the service's restart policy.
            // A hand-commented block may sit a column off its siblings, so it gets one column of slack.
            val atBody = if (svc.isCommentedOut) kotlin.math.abs(indent - svc.bodyIndent) <= 1 else indent == svc.bodyIndent
            if (!atBody) {
                if (key == "<<") ALIAS_ONLY.find(value)?.let { svc.aliasRefs += it.groupValues[1] }
                when {
                    spanKey == "extends" && key == "service" && !extendsFromFile ->
                        svc.serviceRefs += ComposeServiceRef(value, idx, "extends")
                    // The named service lives in another file.
                    spanKey == "extends" && key == "file" -> {
                        extendsFromFile = true
                        svc.serviceRefs.removeAll { it.via == "extends" }
                    }
                    spanKey == "deploy" && key == "replicas" -> svc.replicas = value.toIntOrNull() ?: svc.replicas
                }
                continue
            }
            val textBlock = value.startsWith("|") || value.startsWith(">")
            if (value.isEmpty() || textBlock) {
                // block key whose value is on following lines (a list, a map or a text block)
                svc.blockSpan[key] = idx..idx
                spanKey = key; spanIsText = textBlock
                if (key in MODELED_ARRAY_KEYS && !textBlock) {
                    arrayKey = key; arrayKeyLine = idx; arrayKeyIndent = indent
                    svc.arraySpan[key] = idx..idx
                    if (key == "depends_on") { dependsOnIndent = indent; dependsOnEntryIndent = -1; dependsOnEntry = "" }
                    if (key == "environment") envEntryIndent = -1
                }
                // `build:` as a block — the image is produced, not pulled.
                if (key == "build" || key == "extends") svc.inheritsImage = true
                if (key == "extends") extendsFromFile = false
            } else {
                when (key) {
                    "image" -> { svc.image = value; svc.scalarLine["image"] = idx }
                    "container_name" -> { svc.containerName = value; svc.scalarLine["container_name"] = idx }
                    "restart" -> { svc.restart = value; svc.scalarLine["restart"] = idx }
                    "command" -> { svc.command = value; svc.scalarLine["command"] = idx }
                    "userns_mode" -> { svc.usernsMode = value; svc.scalarLine["userns_mode"] = idx }
                    "network_mode" -> svc.networkMode = value
                    "scale" -> svc.replicas = value.toIntOrNull() ?: svc.replicas
                    // `profiles: [debug]`: the service starts only when one of them is asked for.
                    "profiles" -> svc.profiles += value.removeSurrounding("[", "]").split(",")
                        .map { it.trim().unquoteYaml() }.filter { it.isNotEmpty() }
                    // `<<: *base` merges another mapping in, so image/ports/… can come from there.
                    "<<" -> {
                        svc.inheritsImage = true
                        ALIAS_ONLY.find(value)?.let { svc.aliasRefs += it.groupValues[1] }
                    }
                    "build" -> svc.inheritsImage = true
                    // `extends: web` and `extends: {service: web}` name a service in this file,
                    // unless the flow form also names a `file:`.
                    "extends" -> {
                        svc.inheritsImage = true
                        val named = if (value.startsWith("{")) FLOW_EXTENDS_SERVICE.find(value)?.groupValues?.get(1)
                            ?.takeUnless { FLOW_EXTENDS_FILE.containsMatchIn(value) } else value
                        named?.trim()?.unquoteYaml()?.takeIf { it.isNotEmpty() }
                            ?.let { svc.serviceRefs += ComposeServiceRef(it, idx, "extends") }
                    }
                    // Run in another service's network, IPC or PID namespace.
                    "ipc", "pid" -> if (value.startsWith("service:")) {
                        svc.serviceRefs += ComposeServiceRef(value.removePrefix("service:").trim(), idx, key)
                    }
                    // Inline KEY=VALUE handled when it appears as an environment list item above.
                }
                if (key == "network_mode" && value.startsWith("service:")) {
                    svc.serviceRefs += ComposeServiceRef(value.removePrefix("service:").trim(), idx, key)
                }
            }
        }
    }
    finish()
    finishTopVol()
    finishTopNet()
    // podman-compose defaults to grouping in pod_<project> when x-podman.in_pod is absent.
    if (runtime == "podman" && draft.xPodmanSrcHeader < 0) draft.podmanPodEnabled = true
    draft.hasServicesSection = sawServicesSection || draft.originalText == null
    // The blank starter row is a UI seed for a NEW stack. Seeding it into a real file that simply
    // has no `services:` section (Compose format v1 puts services at the top level) invented an
    // "app" service the file never had, and a save would have appended it.
    if (draft.services.isEmpty() && draft.originalText == null) draft.services.add(ComposeServiceDraft())
    return draft
}

/** True when this draft would emit nothing but a bare `name:` key — not a service Compose accepts. */
private fun ComposeServiceDraft.isEmptyPlaceholder(): Boolean =
    image.isBlank() && containerName.isBlank() && restart.isBlank() && command.isBlank() &&
        usernsMode.isBlank() &&
        listOf(ports, environment, volumes, networks, dependsOn).all { l -> l.none { it.isNotBlank() } }

/**
 * Generate one service's YAML block, no trailing newline. The service key sits at [headerIndent] and
 * its body [step] further in, so a block added to an existing file matches the services around it.
 */
private fun generateServiceBlock(
    svc: ComposeServiceDraft,
    podmanRuntime: Boolean,
    headerIndent: Int = 2,
    step: Int = 2,
): String {
    val sb = StringBuilder()
    val name = svc.serviceName.ifBlank { "service" }
    val c = if (svc.isCommentedOut) "# " else ""
    val h = " ".repeat(headerIndent)
    val b = " ".repeat(headerIndent + step)
    sb.append("$c$h$name:\n")
    fun scalar(k: String, v: String) { if (v.isNotBlank()) sb.append("$c$b$k: ${yamlPlainOrSingleQuoted(v)}\n") }
    scalar("image", svc.image)
    scalar("container_name", svc.containerName)
    scalar("restart", svc.restart)
    scalar("command", svc.command)
    // `keep-id` is a Podman rootless mapping. Retain it in the draft while switching runtimes,
    // but never leak that Podman-only value into newly generated Docker YAML.
    if (podmanRuntime || svc.usernsMode != "keep-id") scalar("userns_mode", svc.usernsMode)
    fun list(k: String, items: List<String>, quote: Boolean) {
        val v = items.filter { it.isNotBlank() }
        if (v.isEmpty()) return
        sb.append("$c$b$k:\n")
        for (it in v) sb.append("$c$b  - ${yamlListItem(it, quote)}\n")
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
    if (draft.runtime == "podman") {
        val inPod = when {
            !draft.podmanPodEnabled -> "false"
            draft.podmanPodName.isBlank() -> "true"
            else -> yamlPlainOrSingleQuoted(draft.podmanPodName)
        }
        sb.append("x-podman:\n  in_pod: $inPod\n")
    }
    sb.append("services:\n")
    for (svc in draft.services) {
        sb.append(generateServiceBlock(svc, podmanRuntime = draft.runtime == "podman"))
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
    val appended = mutableListOf<String>()                  // blocks emitted after everything else
    fun insert(at: Int, text: String) {
        val anchor = at.coerceIn(0, lines.lastIndex.coerceAtLeast(0))
        insertAfter.getOrPut(anchor) { mutableListOf() }.add(text)
    }

    val originals = parsedFrom.services.associateBy { it.id }
    fun indentStr(n: Int) = " ".repeat(n.coerceAtLeast(0))
    val renames = composeServiceRenames(draft, parsedFrom)
    // The file's own indentation, read from its first live service, for blocks the builder adds.
    val styleService = parsedFrom.services.firstOrNull { !it.isCommentedOut && it.srcStart in lines.indices }
    val serviceHeaderIndent = styleService?.let { indentOfLine(lines[it.srcStart]) } ?: 2
    val serviceStep = styleService?.bodyIndent?.minus(serviceHeaderIndent)?.takeIf { it > 0 } ?: 2

    // Top-level `name:` — surgically update/add/remove (it lives at indent 0, outside any service).
    if (draft.stackName != parsedFrom.stackName) {
        val nameLine = parsedFrom.stackNameSrcLine
        when {
            // existing name line → rewrite or delete it
            nameLine in slot.indices && slot[nameLine] != null -> {
                slot[nameLine] = if (draft.stackName.isBlank()) null else "name: ${yamlPlainOrSingleQuoted(draft.stackName)}"
            }
            // no name line yet → insert one just before the `services:` line. If `services:` is the
            // very first line, prepend by emitting before slot 0 (handled via the prepend list).
            draft.stackName.isNotBlank() -> {
                val servicesIdx = servicesHeaderLine(lines)
                if (servicesIdx > 0) {
                    insert(servicesIdx - 1, "name: ${yamlPlainOrSingleQuoted(draft.stackName)}")
                } else {
                    prepend.add("name: ${yamlPlainOrSingleQuoted(draft.stackName)}")
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
        val bodyIndent = if (svc.bodyIndent > 0) svc.bodyIndent
        else (src.srcStart.takeIf { it in lines.indices }?.let { seeThroughIndent(lines[it]) } ?: 2) + serviceStep

        // Comment-state toggle across the whole original block. We comment by putting "# " at
        // COLUMN 0 and consuming up to two leading indent spaces, matching the convention compose
        // files use (e.g. "  webui:" -> "# webui:", "    image: x" -> "#   image: x"). This keeps
        // the body's relative indentation and is exactly reversible by the parser's #→space mapping.
        if (svc.isCommentedOut != src.isCommentedOut && src.srcStart >= 0) {
            if (svc.isCommentedOut) {
                for (i in src.srcStart..src.srcEnd) {
                    if (i !in slot.indices) continue
                    val line = slot[i] ?: continue
                    // Lines the AUTHOR had already commented out get a second "# " too. Skipping
                    // them made the operation lossy in one direction: uncommenting later stripped
                    // the single "#" they still carried and resurrected a block the author had
                    // deliberately disabled — an env block with real secrets, in the file that
                    // prompted this — at an indent that then swallowed the sibling key above it.
                    // A second level makes uncomment remove exactly what comment-out added.
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
                    // Still a comment after one level came off: it was a comment before the service
                    // was commented out, so restore it verbatim instead of promoting it to code.
                    if (stripped.trimStart().startsWith("#")) { slot[i] = stripped; continue }
                    val ind = (indentOfLine(stripped) + delta).coerceAtLeast(0)
                    slot[i] = " ".repeat(ind) + stripped.trimStart()
                }
            }
        }

        // Rename: rewrite the key on the header line the toggle above may have just changed.
        if (svc.serviceName.trim() != src.serviceName && svc.serviceName.isNotBlank() && src.srcStart in slot.indices) {
            slot[src.srcStart]?.let { slot[src.srcStart] = renameYamlKey(it, svc.serviceName.trim()) }
        }
        // Every other reference to a renamed service follows it (the depends_on list is mapped
        // where it is written below).
        for (ref in src.serviceRefs) {
            val new = renames[ref.name] ?: continue
            if (ref.line in slot.indices) slot[ref.line]?.let { slot[ref.line] = renameServiceRef(it, ref, new) }
        }

        // What a new line in this body starts with: copied from one of its key lines as they stand
        // after the toggle, so a commented or re-indented block gets lines that match it.
        val bodyPrefix = (src.scalarLine.filterKeys { "." !in it }.values +
            src.arraySpan.values.map { it.first } + src.blockSpan.values.map { it.first })
            .sorted()
            .firstNotNullOfOrNull { i -> slot.getOrNull(i)?.let(::linePrefix) }
            ?: when {
                svc.isCommentedOut -> "# " + indentStr(bodyIndent - 2)
                src.isCommentedOut -> indentStr(bodyIndent - seeThroughIndent(lines.getOrElse(src.srcStart) { "" }) + 2)
                else -> indentStr(bodyIndent)
            }

        fun applyScalar(key: String, newVal: String, oldVal: String) {
            if (newVal == oldVal) return
            val written = "$key: ${yamlPlainOrSingleQuoted(newVal)}"
            val lineIdx = src.scalarLine[key]
            val block = src.blockSpan[key]
            if (lineIdx != null && lineIdx in slot.indices && slot[lineIdx] != null) {
                if (newVal.isBlank()) { slot[lineIdx] = null; return }      // cleared → drop the line
                val ind = slot[lineIdx]!!.takeWhile { it == ' ' || it == '#' }
                slot[lineIdx] = "$ind$written"
            } else if (block != null && block.first in slot.indices && slot[block.first] != null) {
                // The file writes this key as a list or text block: the new value replaces all of it.
                val ind = slot[block.first]!!.takeWhile { it == ' ' || it == '#' }
                for (i in block) if (i in slot.indices) slot[i] = null
                if (newVal.isNotBlank()) slot[block.first] = "$ind$written"
            } else if (newVal.isNotBlank()) {
                insert(src.srcStart, "$bodyPrefix$written")  // add after header
            }
        }
        applyScalar("image", svc.image, src.image)
        applyScalar("container_name", svc.containerName, src.containerName)
        applyScalar("restart", svc.restart, src.restart)
        applyScalar("command", svc.command, src.command)
        // Strip Podman's `keep-id` only when the stack is known to be Docker. A blank runtime means
        // "not resolved yet", and treating that as Docker deleted the line from a Podman file the
        // moment any other field was touched.
        val renderedUsernsMode =
            if (draft.runtime == "docker" && svc.usernsMode == "keep-id") "" else svc.usernsMode
        applyScalar("userns_mode", renderedUsernsMode, src.usernsMode)

        fun applyArray(key: String, items: List<String>, old: List<String>, quote: Boolean) {
            // The file expresses this key as a map or long syntax; the list editor can't represent
            // it, so leave the original bytes alone instead of splicing a list over them.
            if (key in src.unmodeledArrayKeys) return
            val cleaned = items.filter { it.isNotBlank() }
                .map { if (key == "depends_on") renames[it.trim()] ?: it else it }
            if (cleaned == old.filter { it.isNotBlank() }) return
            val span = src.arraySpan[key]
            val block = buildList {
                if (cleaned.isNotEmpty()) {
                    add("$bodyPrefix$key:")
                    if (key == "environment" && src.environmentIsMap) {
                        // Untouched rows go back exactly as written; new or changed ones become
                        // `KEY: "value"` at the entries' indent.
                        val rowLine = { row: String -> src.environmentRowLine[row]?.let { slot.getOrNull(it) } }
                        val entryPrefix = src.environmentRowLine.values.minOrNull()?.let { slot.getOrNull(it) }
                            ?.let(::linePrefix) ?: "$bodyPrefix  "
                        for (row in cleaned) add(rowLine(row) ?: entryPrefix + yamlEnvironmentEntry(row))
                    } else if (key == "depends_on" && src.dependsOnIsMap) {
                        // Kept entries go back with their conditions; a new one waits for the
                        // service to start, the condition Compose requires each entry to name.
                        val renamedFrom = renames.entries.associate { (old, new) -> new to old }
                        val entryPrefix = src.dependsOnEntrySpan.values.minOfOrNull { it.first }?.let { slot.getOrNull(it) }
                            ?.let(::linePrefix) ?: "$bodyPrefix  "
                        for (row in cleaned) {
                            val kept = (src.dependsOnEntrySpan[row] ?: src.dependsOnEntrySpan[renamedFrom[row]])
                                ?.mapNotNull { slot.getOrNull(it) }
                            if (!kept.isNullOrEmpty()) {
                                addAll(kept)
                            } else {
                                add("$entryPrefix${yamlPlainOrSingleQuoted(row)}:")
                                add("$entryPrefix  condition: service_started")
                            }
                        }
                    } else {
                        for (it in cleaned) add("$bodyPrefix  - ${yamlListItem(it, quote)}")
                    }
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
    // Entries the builder writes take the indent the file's own entries use.
    fun entryIndent(srcStarts: List<Int>): String =
        indentStr(srcStarts.firstOrNull { it in lines.indices && !lines[it].trimStart().startsWith("#") }
            ?.let { indentOfLine(lines[it]) } ?: 2)
    val volIndent = entryIndent(parsedFrom.topVolumes.map { it.srcStart })
    fun volumeBlock(v: TopLevelVolumeDraft): List<String> {
        val c = if (v.isCommentedOut) "# " else ""
        return buildList {
            add("$c$volIndent${v.name}:")
            if (v.external) add("$c$volIndent  external: true")
        }
    }
    // Delete removed entries
    for (src in parsedFrom.topVolumes) {
        if (src.id !in keptVolIds && src.srcStart >= 0) {
            for (i in src.srcStart..src.srcEnd) if (i in slot.indices) slot[i] = null
        }
    }
    // An entry whose comment state or name changes is edited in place: commenting puts "# " before
    // each line, restoring strips one level and lines the entry up with [indent] again, and a rename
    // changes only the key. Rewriting the whole entry dropped what the builder does not show
    // (driver_opts, labels, ipam, name), so a volume lost its options when the one service using
    // it was commented out.
    fun editEntryInPlace(start: Int, end: Int, comment: Boolean?, newName: String?, indent: Int) {
        if (start !in slot.indices) return
        if (comment == true) {
            for (i in start..end) slot.getOrNull(i)?.let { slot[i] = "# $it" }
        } else if (comment == false) {
            fun strip(line: String) = line.trimStart().dropWhile { it == '#' }.removePrefix(" ")
            val delta = indent - indentOfLine(strip(slot[start] ?: lines[start]))
            for (i in start..end) {
                val line = slot.getOrNull(i) ?: continue
                if (!line.trimStart().startsWith("#")) continue
                val stripped = strip(line)
                // Commented before the entry was: it stays a comment.
                if (stripped.trimStart().startsWith("#")) { slot[i] = stripped; continue }
                slot[i] = " ".repeat((indentOfLine(stripped) + delta).coerceAtLeast(0)) + stripped.trimStart()
            }
        }
        if (newName != null) slot[start]?.let { slot[start] = renameYamlKey(it, newName) }
    }
    // Update existing entries. Turning external on or off still rewrites the entry: Compose refuses
    // an external volume that also sets a driver, options or labels.
    for (vol in draft.topVolumes) {
        val src = origTopVols[vol.id] ?: continue
        if (src.srcStart !in slot.indices) continue
        if (vol.external != src.external) {
            slot[src.srcStart] = volumeBlock(vol).joinToString("\n")
            for (i in (src.srcStart + 1)..src.srcEnd) if (i in slot.indices) slot[i] = null
        } else {
            editEntryInPlace(
                src.srcStart, src.srcEnd,
                comment = vol.isCommentedOut.takeIf { it != src.isCommentedOut },
                newName = vol.name.trim().takeIf { it != src.name && it.isNotEmpty() },
                indent = volIndent.length,
            )
        }
    }
    // Handle the volumes: header — add it if entries now exist but the header was absent
    val newTopVols = draft.topVolumes.filter { it.name.isNotBlank() && it.id !in origTopVols }
    val hasExistingVolHeader = parsedFrom.volumesSrcHeader >= 0
    if (hasExistingVolHeader && newTopVols.isNotEmpty()) {
        val anchor = parsedFrom.topVolumes.maxOfOrNull { it.srcEnd } ?: parsedFrom.volumesSrcHeader
        newTopVols.forEach { insert(anchor, volumeBlock(it).joinToString("\n")) }
    }
    if (hasExistingVolHeader) settleSectionHeader(slot, lines, parsedFrom.volumesSrcHeader, "volumes",
        draft.topVolumes.filter { it.name.isNotBlank() }.map { it.isCommentedOut })

    // ── Top-level networks ──
    val origTopNets = parsedFrom.topNetworks.associateBy { it.id }
    val keptNetIds = draft.topNetworks.mapTo(HashSet()) { it.id }
    val netIndent = entryIndent(parsedFrom.topNetworks.map { it.srcStart })
    fun networkBlock(n: TopLevelNetworkDraft): List<String> {
        val c = if (n.isCommentedOut) "# " else ""
        return buildList {
            add("$c$netIndent${n.name}:")
            if (n.driver.isNotBlank()) add("$c$netIndent  driver: ${yamlPlainOrSingleQuoted(n.driver)}")
            if (n.external) add("$c$netIndent  external: true")
        }
    }
    for (src in parsedFrom.topNetworks) {
        if (src.id !in keptNetIds && src.srcStart >= 0) {
            for (i in src.srcStart..src.srcEnd) if (i in slot.indices) slot[i] = null
        }
    }
    for (net in draft.topNetworks) {
        val src = origTopNets[net.id] ?: continue
        if (src.srcStart !in slot.indices) continue
        if (net.external != src.external) {
            slot[src.srcStart] = networkBlock(net).joinToString("\n")
            for (i in (src.srcStart + 1)..src.srcEnd) if (i in slot.indices) slot[i] = null
            continue
        }
        editEntryInPlace(
            src.srcStart, src.srcEnd,
            comment = net.isCommentedOut.takeIf { it != src.isCommentedOut },
            newName = net.name.trim().takeIf { it != src.name && it.isNotEmpty() },
            indent = netIndent.length,
        )
        // Then the driver, on the lines as the toggle above left them.
        if (net.driver != src.driver) {
            val written = "driver: ${yamlPlainOrSingleQuoted(net.driver)}"
            val line = src.driverLine.takeIf { it in slot.indices && slot[it] != null }
            when {
                line != null && net.driver.isBlank() -> slot[line] = null
                line != null -> slot[line] = slot[line]!!.takeWhile { it == ' ' || it == '#' } + written
                net.driver.isNotBlank() -> {
                    // Line up with the entry's first property, or one step in from its key.
                    val prefix = ((src.srcStart + 1)..src.srcEnd).firstNotNullOfOrNull { i -> slot.getOrNull(i)?.takeIf { it.isNotBlank() } }
                        ?.let(::linePrefix)
                        ?: ((if (net.isCommentedOut) "# " else "") + netIndent + "  ")
                    insert(src.srcStart, prefix + written)
                }
            }
        }
    }
    if (parsedFrom.networksSrcHeader >= 0) settleSectionHeader(slot, lines, parsedFrom.networksSrcHeader, "networks",
        draft.topNetworks.filter { it.name.isNotBlank() }.map { it.isCommentedOut })
    val brandNewNets = draft.topNetworks.filter { it.name.isNotBlank() && it.id !in origTopNets }
    if (parsedFrom.networksSrcHeader >= 0 && brandNewNets.isNotEmpty()) {
        val anchor = parsedFrom.topNetworks.maxOfOrNull { it.srcEnd } ?: parsedFrom.networksSrcHeader
        brandNewNets.forEach { insert(anchor, networkBlock(it).joinToString("\n")) }
    }

    // ── Podman pod grouping extension ──
    if (draft.runtime == "podman" &&
        (draft.podmanPodEnabled != parsedFrom.podmanPodEnabled ||
            draft.podmanPodName != parsedFrom.podmanPodName)
    ) {
        val inPod = when {
            !draft.podmanPodEnabled -> "false"
            draft.podmanPodName.isBlank() -> "true"
            else -> yamlPlainOrSingleQuoted(draft.podmanPodName)
        }
        when {
            parsedFrom.xPodmanInPodSrcLine in slot.indices ->
                slot[parsedFrom.xPodmanInPodSrcLine] = "  in_pod: $inPod"
            parsedFrom.xPodmanSrcHeader in slot.indices ->
                insert(parsedFrom.xPodmanSrcHeader, "  in_pod: $inPod")
            else -> prepend.add("x-podman:\n  in_pod: $inPod")
        }
    }

    // Brand-new services (added in the builder, no source mapping) go at the END OF THE SERVICES
    // SECTION, not the end of the file: `services:` is rarely the last section, so emitting them
    // last dropped the new service inside a trailing `volumes:`/`networks:` block, where it then
    // parsed as a top-level volume named after the service.
    val newServices = draft.services.filter { it.id !in originals && !it.isEmptyPlaceholder() }
    val servicesSectionEnd = parsedFrom.services.filter { it.srcEnd >= 0 }.maxOfOrNull { it.srcEnd }
        ?: servicesHeaderLine(lines).takeIf { it >= 0 }
    for (svc in newServices) {
        val block = generateServiceBlock(svc, draft.runtime == "podman", serviceHeaderIndent, serviceStep)
        if (servicesSectionEnd != null) insert(servicesSectionEnd, block) else appended += block
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
    appended.forEach { block -> block.split("\n").forEach { emit(it) } }

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

/**
 * The top-level [section] header at [header] once its entries are settled ([commented] holds each
 * one's state). With no entries left it goes. With entries that are all commented out it becomes
 * `section: {}`: a bare header over nothing but comments is null, which Compose rejects. It turns
 * back into a plain header as soon as one entry is live again.
 */
private fun settleSectionHeader(slot: MutableList<String?>, lines: List<String>, header: Int, section: String, commented: List<Boolean>) {
    if (header !in slot.indices || slot[header] == null) return
    val wasEmpty = isEmptyFlowMapping(lines[header])
    when {
        commented.isEmpty() -> slot[header] = null
        commented.all { it } && !wasEmpty -> slot[header] = "$section: {}"
        commented.any { !it } && wasEmpty -> slot[header] = "$section:"
    }
}

// The top-level `services:` line, or -1. A comment may follow the key.
private fun servicesHeaderLine(lines: List<String>): Int =
    lines.indexOfFirst { indentOfLine(it) == 0 && blockKeyOf(it.trim()) == "services" }

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
    val dismissKeyboard = rememberDismissKeyboard()
    val servers by viewModel.servers.collectAsStateWithLifecycle()
    val active = viewModel.activeComposeDraft
    val draftGeneration = viewModel.activeComposeGeneration
    val draftServerId = viewModel.activeComposeServerId
    val fullScreenEditorHost = LocalFullScreenEditorHost.current
    // STABLE seed key identifying a distinct edit session. It must NOT change on every keystroke —
    // otherwise mirroring edits back to the ViewModel (below) would re-seed the parsed baseline to
    // the already-edited draft, so the surgical diff would see "no changes" and silently drop edits
    // (this is the class of bug behind "comment toggle doesn't reflect / save"). For an existing
    // file the absolute path is a perfect stable identity; a brand-new draft uses a constant so its
    // in-progress state survives recompositions, and "New / Clear" (active == null) resets it.
    val seedKey = when {
        active == null -> "::cleared::$draftGeneration"
        active.composeFilePath.isNotBlank() -> "file:${active.composeFilePath}:$draftGeneration"
        else -> "::new::$draftGeneration"
    }

    // Immutable parsed baseline for surgical diffing — captured ONCE per edit session, and kept by
    // the host's draft so returning to a host diffs against what it was opened from, not its edits.
    val parsedBaseline = remember(seedKey) { viewModel.activeComposeBaseline }
    var draft by remember(seedKey) { mutableStateOf(active ?: ComposeStackDraft()) }
    // A host with exactly one usable runtime has no runtime picker. Pin new drafts to that runtime
    // once discovery completes so Podman-only controls are not accidentally hidden behind a blank
    // auto-resolver value.
    LaunchedEffect(seedKey, viewModel.availableContainerRuntimes) {
        if (active == null && draft.runtime.isBlank() &&
            viewModel.availableContainerRuntimes.size == 1
        ) {
            val onlyRuntime = viewModel.availableContainerRuntimes.single()
            draft = draft.copy(
                runtime = onlyRuntime,
                podmanPodEnabled = onlyRuntime == "podman",
            )
        }
    }

    // Mirror local edits back to the ViewModel so switching tabs doesn't lose them.
    LaunchedEffect(draft) {
        if (active == null) {
            viewModel.beginComposeDraft(draft)
        } else if (viewModel.activeComposeDraft !== draft) {
            viewModel.updateComposeDraft(draftGeneration, draft)
        }
    }

    val restoredRawState = viewModel.activeComposeRawSeedKey == seedKey
    var rawMode by remember(seedKey) {
        mutableStateOf(restoredRawState && viewModel.activeComposeRawMode)
    }
    var rawText by remember(seedKey) {
        mutableStateOf(
            if (restoredRawState) viewModel.activeComposeRawText
                ?: draft.originalText ?: generateDockerComposeYaml(draft)
            else draft.originalText ?: generateDockerComposeYaml(draft)
        )
    }
    // Persist in the same composition transaction. A queued LaunchedEffect from the previous tab
    // could otherwise run after a fast tab switch and overwrite the new mode with stale state.
    SideEffect {
        viewModel.rememberComposeRawState(seedKey, rawText, rawMode)
    }
    // When true, the Raw YAML editor opens as a full-screen overlay matching the SFTP file editor's
    // look/feel (same chrome, find/replace, go-to-line, word-wrap). Edits write straight to rawText.
    var rawFullScreen by remember(seedKey) { mutableStateOf(false) }

    DisposableEffect(seedKey, fullScreenEditorHost) {
        onDispose {
            if (rawFullScreen) fullScreenEditorHost.dismiss()
        }
    }

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

    // Clearing alone is the right outcome for the "New / Clear" button, which stays on this tab to
    // start a fresh stack. It is NOT enough for Back, which must also leave the tab -- see the
    // BackHandler below.
    fun clearDraft(exitBuilder: Boolean) {
        viewModel.clearActiveComposeDraft()
        if (exitBuilder) viewModel.activeInfraTab = INFRA_TAB_STACKS
    }

    fun attemptClearOrExit(exitBuilder: Boolean) {
        if (isDirty()) {
            confirm.ask(
                confirm.str(R.string.discard_changes),
                confirm.str(R.string.you_have_unsaved_changes_to_this),
                confirmLabel = confirm.str(R.string.discard)
            ) { clearDraft(exitBuilder) }
        } else {
            clearDraft(exitBuilder)
        }
    }

    // Back must end in a VISIBLE navigation, never in state mutation alone. Clearing the draft
    // leaves the user on the Builder tab, and this composable recreates an empty draft the moment
    // it sees `activeComposeDraft == null` (the mirror LaunchedEffect above, which exists so edits
    // survive a tab switch). A handler that only cleared therefore made the tab inescapable: every
    // press cleared the draft, immediately rebuilt it, and left the user exactly where they were
    // with no visible change at all. Returning to the Stacks tab breaks that loop and also
    // unregisters this handler, since the builder only composes on tab 1 -- so a second Back
    // reaches the app-level handler and leaves the screen as the user expects.
    //
    // The full-screen code editor installs its own BackHandler. Disable the builder-level handler
    // while that overlay is visible so Android Back closes only the editor instead of racing both
    // handlers and incorrectly offering to discard the entire compose draft.
    BackHandler(enabled = !rawFullScreen) {
        attemptClearOrExit(exitBuilder = true)
    }

    val validationIssues = remember(draft, rawMode, parsedBaseline) {
        if (rawMode) emptyList() else validateComposeDraft(draft, parsedBaseline)
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
                        if (ok) stringResource(R.string.stack_deployed) else stringResource(R.string.deploy_failed_stack_left_unchanged),
                        fontWeight = FontWeight.Bold,
                        color = if (ok) OmniColors.green else OmniColors.red,
                    )
                    if (msg.isNotBlank()) {
                        Box(Modifier.heightIn(max = 140.dp).verticalScrollWithIndicators(rememberScrollState())) {
                            androidx.compose.foundation.text.selection.SelectionContainer {
                                Text(msg, fontFamily = OmniFonts.mono, fontSize = 11.sp, color = OmniColors.textPrimary)
                            }
                        }
                    }
                }
                if (msg.isNotBlank()) {
                    IconButton(onClick = { copyToClipboard(msg) }) {
                        Icon(Icons.Filled.ContentCopy, contentDescription = stringResource(R.string.copy_deploy_output))
                    }
                }
                TextButton(onClick = { result = null }) { Text(stringResource(R.string.dismiss)) }
            }
        }

        Column(
            modifier = Modifier.fillMaxWidth().weight(1f).verticalScrollWithIndicators(rememberScrollState()).padding(12.dp).imePadding(),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                Column {
                    Text(stringResource(R.string.compose_builder), fontWeight = FontWeight.Bold, fontSize = 20.sp, color = OmniColors.cyan)
                    Text(if (isExisting) stringResource(R.string.editing_existing_stack) else stringResource(R.string.new_stack), fontSize = 11.sp, color = OmniColors.textMuted)
                }
                if (active != null) {
                    TextButton(onClick = { attemptClearOrExit(exitBuilder = false) }) { Text(stringResource(R.string.new_clear)) }
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
                    Text(stringResource(R.string.compose_file), fontSize = 9.sp, fontWeight = FontWeight.Bold, letterSpacing = 1.sp, color = OmniColors.textMuted)
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
                                        viewModel.rememberComposeRawState(seedKey, rawText, true)
                                    }
                                    i == 0 && rawMode && composeRawEditsDiffer(rawText, draft, parsedBaseline) -> {
                                        confirm.ask(
                                            confirm.str(R.string.leave_raw_yaml),
                                            confirm.str(R.string.raw_yaml_edits_are_not_applied),
                                            confirmLabel = confirm.str(R.string.switch_label),
                                        ) {
                                            rawMode = false
                                            viewModel.rememberComposeRawState(seedKey, rawText, false)
                                        }
                                    }
                                    else -> {
                                        rawMode = i == 1
                                        viewModel.rememberComposeRawState(seedKey, rawText, rawMode)
                                    }
                                }
                            },
                            text = { Text(t) },
                        )
                }
            }

            if (rawMode) {
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    if (isExisting) {
                        Text(stringResource(R.string.editing_the_file_directly_nothing_is),
                            fontSize = 11.sp, color = OmniColors.textMuted,
                            modifier = Modifier.weight(1f),
                        )
                    } else {
                        Spacer(Modifier.weight(1f))
                    }
                    IconButton(onClick = {
                        rawFullScreen = true
                        fullScreenEditorHost.show {
                            FullScreenCodeEditor(
                                title = draft.fileName.ifBlank { "docker-compose.yml" },
                                value = rawText,
                                onValueChange = { rawText = it },
                                onClose = {
                                    rawFullScreen = false
                                    fullScreenEditorHost.dismiss()
                                },
                                onSave = {
                                    rawFullScreen = false
                                    fullScreenEditorHost.dismiss()
                                },
                                subtitle = stringResource(R.string.lines_chars, rawText.count { it == '\n' } + 1, rawText.length),
                                dirty = false,
                                canSave = true,
                                saveLabel = "Done",
                                fontSize = 12.sp,
                                language = CodeLanguage.YAML,
                                highlightMaxChars = viewModel.editorHighlightLimit,
                            )
                        }
                    }) {
                        Icon(Icons.Filled.Fullscreen, contentDescription = stringResource(R.string.edit_full_screen), tint = OmniColors.cyan)
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
                    label = { Text(stringResource(R.string.stack_name_compose_name_key_optional)) },
                    placeholder = { Text(stringResource(R.string.e_g_example_stack)) },
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
                            Text(stringResource(R.string.issue_s_before_deploy, validationIssues.size), fontWeight = FontWeight.Bold, color = OmniColors.red)
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
                        contentDescription = if (previewExpanded) stringResource(R.string.collapse_preview) else stringResource(R.string.expand_preview),
                        tint = OmniColors.cyan,
                    )
                    Spacer(Modifier.width(6.dp))
                    Text(stringResource(R.string.preview), fontWeight = FontWeight.Bold, color = OmniColors.cyan)
                }
                if (previewExpanded) {
                    Box(
                        Modifier.fillMaxWidth()
                            .clip(RoundedCornerShape(8.dp))
                            .background(OmniColors.bg1)
                            .border(1.dp, OmniColors.bg2, RoundedCornerShape(8.dp))
                            .padding(10.dp)
                            .horizontalScrollWithIndicators(rememberScrollState()),
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
                    label = { Text(stringResource(R.string.project_name_name_deploy_directory)) },
                    placeholder = { Text(stringResource(R.string.e_g_my_stack)) },
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
                    Text(stringResource(R.string.runtime), fontSize = 12.sp, color = OmniColors.textMuted)
                    // Blank runtime deploys via the auto-resolver, which prefers Docker — so
                    // Docker renders as the default selection until the user picks explicitly.
                    FilterChip(
                        selected = draft.runtime != "podman",
                        onClick = { draft = draft.copy(runtime = "docker") },
                        label = { Text(stringResource(R.string.docker)) },
                    )
                    FilterChip(
                        selected = draft.runtime == "podman",
                        onClick = {
                            draft = draft.copy(
                                runtime = "podman",
                                // Match podman-compose's existing default when entering Podman for
                                // the first time; the modifier card can explicitly turn it off.
                                podmanPodEnabled = if (draft.runtime == "podman") {
                                    draft.podmanPodEnabled
                                } else {
                                    true
                                },
                            )
                        },
                        label = { Text(stringResource(R.string.podman)) },
                    )
                }
            } else if (isExisting && bothRuntimes && draft.runtime.isNotBlank()) {
                Text(
                    stringResource(R.string.runtime_owned_by_this_runtime_redeploys, draft.runtime),
                    fontSize = 11.sp, color = OmniColors.textMuted,
                )
            }

            // An offline host keeps its draft here, so the user can come back to it once it is up.
            // Found in the collected list so the note and Deploy follow the host going offline and
            // coming back; [AppViewModel.selectedServer] reads the list once and never updated them.
            val host = servers.find { it.id == viewModel.selectedServerId }
            val hostOnline = host != null && viewModel.isPickableHost(host)
            if (host != null && !hostOnline) {
                Text(
                    stringResource(R.string.compose_host_offline_draft_kept, host.name),
                    fontSize = 11.sp,
                    color = OmniColors.amber,
                    modifier = Modifier.testTag("compose.builder.offline"),
                )
            }
            OmniButton(
                label = if (deploying) "Deploying…" else if (isExisting) "Validate & Deploy" else "Deploy Stack",
                color = OmniColors.amber,
                modifier = Modifier.fillMaxWidth(),
                enabled = !deploying && hostOnline,
                    onClick = {
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
                    val dropsServices = isExisting && composeDeployDropsServices(yaml, parsedBaseline)
                    confirm.ask(
                        if (isExisting) confirm.str(R.string.deploy_changes) else confirm.str(R.string.deploy_stack),
                            confirm.str(R.string.target_file_it_s_validated_first, composeFilePath) +
                                if (dropsServices) "\n\n" + confirm.str(R.string.deploy_removes_dropped_services) else "",
                        confirmLabel = confirm.str(R.string.deploy),
                    ) {
                        dismissKeyboard()
                        deploying = true
                        result = null
                            viewModel.deployComposeStack(
                                composeFilePath = composeFilePath,
                                project = project,
                                yaml = yaml,
                                workingDir = draft.workingDir,
                                configFiles = draft.composeConfigFiles,
                                runtime = draft.runtime,
                                expectedServerId = draftServerId,
                                removeOrphans = dropsServices,
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

    }
}

/**
 * Whether deploying [yaml] drops a service the file running as [baseline] has: deleted, renamed or
 * commented out. Compose leaves such a service's container running as an orphan unless told to
 * remove it.
 */
internal fun composeDeployDropsServices(yaml: String, baseline: ComposeStackDraft?): Boolean {
    if (baseline?.originalText == null) return false
    fun ComposeStackDraft.activeNames() = services.filterNot { it.isCommentedOut }.map { it.serviceName.trim() }.toSet()
    return (baseline.activeNames() - parseDockerComposeYaml(yaml, baseline.projectName).activeNames()).isNotEmpty()
}

private val WINDOWS_DRIVE_PATH = Regex("""^[A-Za-z]:[\\/]""")

/** Extract the named-volume name from a service volumes entry, or null for bind-mounts. */
private fun namedVolumeFrom(entry: String): String? {
    val raw = entry.trim()
    if (raw.isBlank() || raw.startsWith(".") || raw.startsWith("/")) return null
    // A Windows drive path ("C:\data:/data") is a bind mount too; its drive letter is no volume.
    if (WINDOWS_DRIVE_PATH.containsMatchIn(raw)) return null
    val name = if (raw.contains(":")) raw.substringBefore(":").trim() else raw
    // Only something that could actually BE a volume name earns a top-level declaration. A host
    // path Compose interpolates at deploy time ("${UPLOAD_LOCATION}:/data", "~/data:/data") is a
    // bind-mount, not a named volume: declaring it wrote "${UPLOAD_LOCATION}:" under `volumes:` and
    // then failed validation with an invalid-name error for a volume the user never typed.
    return name.takeIf { isValidComposeName(it) }
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
internal fun reconcileTopLevelVolumes(draft: ComposeStackDraft): ComposeStackDraft {
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
fun VisualEditor(draft: ComposeStackDraft, onChange: (ComposeStackDraft) -> Unit) {
    fun updateSvc(index: Int, transform: (ComposeServiceDraft) -> ComposeServiceDraft) {
        val list = draft.services.toMutableList()
        list[index] = transform(list[index])
        onChange(reconcileTopLevelVolumes(draft.copy(services = list)))
    }
    fun removeSvc(index: Int) {
        val list = draft.services.toMutableList()
        list.removeAt(index)
        onChange(reconcileTopLevelVolumes(draft.copy(services = list)))
    }
    fun addSvc() {
        val list = draft.services.toMutableList()
        list.add(ComposeServiceDraft(serviceName = "", isExpanded = true))
        onChange(draft.copy(services = list))
    }

    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        if (draft.runtime == "podman") {
            PodmanModifiersEditor(draft = draft, onChange = onChange)
        }
        if (draft.services.size > LARGE_VISUAL_SERVICE_THRESHOLD) {
            Text(
                stringResource(R.string.services_list_is_virtualized_for_responsive, draft.services.size),
                fontSize = 11.sp,
                color = OmniColors.textMuted,
            )
            OverflowLazyColumn(
                modifier = Modifier.fillMaxWidth().height(560.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                itemsIndexed(draft.services, key = { _, service -> service.id }) { index, svc ->
                    ComposeServiceEditorCard(
                        index = index,
                        svc = svc,
                        onUpdate = { transform -> updateSvc(index, transform) },
                        onRemove = { removeSvc(index) },
                    )
                }
                item(key = "add-service") {
                    OmniButton(
                        label = stringResource(R.string.add_service),
                        color = OmniColors.green,
                        modifier = Modifier.fillMaxWidth(),
                        onClick = ::addSvc,
                    )
                }
            }
        } else {
            draft.services.forEachIndexed { index, svc ->
                ComposeServiceEditorCard(
                    index = index,
                    svc = svc,
                    onUpdate = { transform -> updateSvc(index, transform) },
                    onRemove = { removeSvc(index) },
                )
            }
            OmniButton(
                label = stringResource(R.string.add_service),
                color = OmniColors.green,
                modifier = Modifier.fillMaxWidth(),
                onClick = ::addSvc,
            )
        }
        TopLevelSectionsEditor(draft, onChange)
    }
}

/**
 * Podman-only composition controls backed by real Compose/provider settings:
 * `userns_mode: keep-id` for rootless identity mapping and `x-podman.in_pod` for pod grouping.
 */
@Composable
fun PodmanModifiersEditor(
    draft: ComposeStackDraft,
    onChange: (ComposeStackDraft) -> Unit,
) {
    val activeServices = draft.services.filterNot { it.isCommentedOut }
    val keepIdEnabled = activeServices.isNotEmpty() &&
        activeServices.all { it.usernsMode == "keep-id" }

    OmniCard(
        modifier = Modifier.fillMaxWidth().testTag("podman-modifiers"),
        leftAccent = OmniColors.purple,
    ) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Text(stringResource(R.string.podman_modifiers), fontWeight = FontWeight.Bold, fontFamily = OmniFonts.mono)
            Text(stringResource(R.string.podman_runs_as_the_ssh_user),
                fontSize = 11.sp,
                color = OmniColors.textMuted,
            )
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Text(stringResource(R.string.rootless_keep_id_mapping), fontSize = 12.sp)
                Switch(
                    checked = keepIdEnabled,
                    onCheckedChange = { enabled ->
                        val services = draft.services.map { service ->
                            when {
                                enabled -> service.copy(usernsMode = "keep-id")
                                service.usernsMode == "keep-id" -> service.copy(usernsMode = "")
                                else -> service
                            }
                        }.toMutableList()
                        onChange(draft.copy(services = services))
                    },
                    modifier = Modifier
                        .testTag("podman-rootless-toggle")
                        .semantics { contentDescription = "Rootless keep-ID mapping" },
                )
            }
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Column(Modifier.weight(1f)) {
                    Text(stringResource(R.string.group_services_in_a_pod), fontSize = 12.sp)
                    Text(stringResource(R.string.services_share_podman_pod_namespaces_using),
                        fontSize = 10.sp,
                        color = OmniColors.textMuted,
                    )
                }
                Switch(
                    checked = draft.podmanPodEnabled,
                    onCheckedChange = { enabled ->
                        onChange(
                            draft.copy(
                                podmanPodEnabled = enabled,
                                podmanPodName = if (enabled) draft.podmanPodName else "",
                            ),
                        )
                    },
                    modifier = Modifier
                        .testTag("podman-pod-toggle")
                        .semantics { contentDescription = "Group services in a Podman pod" },
                )
            }
            if (draft.podmanPodEnabled) {
                OutlinedTextField(
                    value = draft.podmanPodName,
                    onValueChange = { onChange(draft.copy(podmanPodName = it.trim())) },
                    label = { Text(stringResource(R.string.pod_name_optional)) },
                    placeholder = { Text(stringResource(R.string.pod_project)) },
                    supportingText = { Text(stringResource(R.string.blank_uses_podman_compose_s_default)) },
                    singleLine = true,
                    colors = omniTextFieldColors(),
                    modifier = Modifier.fillMaxWidth().testTag("podman-pod-name"),
                )
            }
        }
    }
}

@Composable
private fun ComposeServiceEditorCard(
    index: Int,
    svc: ComposeServiceDraft,
    onUpdate: ((ComposeServiceDraft) -> ComposeServiceDraft) -> Unit,
    onRemove: () -> Unit,
    modifier: Modifier = Modifier,
) {
    OmniCard(
        modifier = modifier.fillMaxWidth(),
        leftAccent = if (svc.isCommentedOut) OmniColors.textMuted else OmniColors.purple,
    ) {
        Column(Modifier.fillMaxWidth().padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(
                Modifier.fillMaxWidth().clickable { onUpdate { it.copy(isExpanded = !it.isExpanded) } },
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
                        Text(stringResource(R.string.comment_out), fontSize = 12.sp, color = OmniColors.textMuted)
                        Switch(checked = svc.isCommentedOut, onCheckedChange = { v -> onUpdate { it.copy(isCommentedOut = v) } })
                    }
                    IconButton(onClick = onRemove) {
                        Icon(Icons.Filled.Delete, "Delete service", tint = OmniColors.red)
                    }
                }
                Field("Service name", svc.serviceName, "web, db, api") { v -> onUpdate { it.copy(serviceName = v) } }
                Field("Image", svc.image, "nginx:latest") { v -> onUpdate { it.copy(image = v) } }
                Field("Container name", svc.containerName, "my-nginx") { v -> onUpdate { it.copy(containerName = v) } }
                Field("Restart policy", svc.restart, "unless-stopped / always / no") { v -> onUpdate { it.copy(restart = v) } }
                Field("Command", svc.command, "optional override") { v -> onUpdate { it.copy(command = v) } }
                ListEditor("Ports (host:container)", svc.ports, "8080:80") { n -> onUpdate { it.copy(ports = n) } }
                ListEditor("Environment (KEY=VALUE)", svc.environment, "NODE_ENV=production") { n -> onUpdate { it.copy(environment = n) } }
                ListEditor("Volumes (host:container)", svc.volumes, "./data:/var/lib/data") { n -> onUpdate { it.copy(volumes = n) } }
                ListEditor("Networks", svc.networks, "frontend") { n -> onUpdate { it.copy(networks = n) } }
                ListEditor("Depends on", svc.dependsOn, "db") { n -> onUpdate { it.copy(dependsOn = n) } }
            }
        }
    }
}

private const val LARGE_VISUAL_SERVICE_THRESHOLD = 40

@Composable
private fun TopLevelSectionsEditor(draft: ComposeStackDraft, onChange: (ComposeStackDraft) -> Unit) {
    fun volumes(change: MutableList<TopLevelVolumeDraft>.() -> Unit) =
        onChange(draft.copy(topVolumes = draft.topVolumes.toMutableList().apply(change)))
    fun networks(change: MutableList<TopLevelNetworkDraft>.() -> Unit) =
        onChange(draft.copy(topNetworks = draft.topNetworks.toMutableList().apply(change)))

    TopLevelSectionCard(
        accent = OmniColors.amber,
        title = stringResource(R.string.top_level_volumes),
        count = draft.topVolumes.size,
        hint = stringResource(R.string.named_volumes_referenced_by_services_must),
        addLabel = stringResource(R.string.add_volume),
        onAdd = { volumes { add(TopLevelVolumeDraft()) } },
    ) {
        draft.topVolumes.forEachIndexed { i, vol ->
            TopLevelEntryRow(
                name = vol.name,
                onName = { v -> volumes { this[i] = vol.copy(name = v.trim()) } },
                nameLabel = stringResource(R.string.volume_name),
                namePlaceholder = stringResource(R.string.mydata),
                external = vol.external,
                onExternal = { v -> volumes { this[i] = vol.copy(external = v) } },
                commentedOut = vol.isCommentedOut,
                removeDescription = "Remove volume",
                onRemove = { volumes { removeAt(i) } },
            )
        }
    }

    TopLevelSectionCard(
        accent = OmniColors.cyan,
        title = stringResource(R.string.top_level_networks),
        count = draft.topNetworks.size,
        hint = stringResource(R.string.custom_networks_referenced_by_services_must),
        addLabel = stringResource(R.string.add_network),
        onAdd = { networks { add(TopLevelNetworkDraft()) } },
    ) {
        draft.topNetworks.forEachIndexed { i, net ->
            Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                TopLevelEntryRow(
                    name = net.name,
                    onName = { v -> networks { this[i] = net.copy(name = v.trim()) } },
                    nameLabel = stringResource(R.string.network_name),
                    namePlaceholder = stringResource(R.string.frontend),
                    external = net.external,
                    onExternal = { v -> networks { this[i] = net.copy(external = v) } },
                    commentedOut = net.isCommentedOut,
                    removeDescription = "Remove network",
                    onRemove = { networks { removeAt(i) } },
                )
                OutlinedTextField(
                    value = net.driver,
                    onValueChange = { v -> networks { this[i] = net.copy(driver = v.trim()) } },
                    label = { Text(stringResource(R.string.driver_optional)) },
                    placeholder = { Text(stringResource(R.string.bridge_overlay_macvlan)) },
                    singleLine = true,
                    colors = omniTextFieldColors(),
                    modifier = Modifier.fillMaxWidth().then(if (net.isCommentedOut) Modifier.alpha(0.45f) else Modifier),
                )
            }
        }
    }
}

/** A collapsible card for the top-level volumes: or networks: section; open when it has entries. */
@Composable
private fun TopLevelSectionCard(
    accent: Color,
    title: String,
    count: Int,
    hint: String,
    addLabel: String,
    onAdd: () -> Unit,
    entries: @Composable () -> Unit,
) {
    OmniCard(modifier = Modifier.fillMaxWidth(), leftAccent = accent) {
        var expanded by remember { mutableStateOf(count > 0) }
        Column(Modifier.fillMaxWidth().padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(
                Modifier.fillMaxWidth().clickable { expanded = !expanded },
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(
                        if (expanded) Icons.Filled.ExpandLess else Icons.Filled.ExpandMore,
                        contentDescription = null, tint = accent,
                    )
                    Spacer(Modifier.width(6.dp))
                    Text(title, fontWeight = FontWeight.Bold, fontFamily = OmniFonts.mono)
                }
                if (count > 0) {
                    OmniTag("$count", color = accent)
                }
            }
            if (expanded) {
                Text(hint, fontSize = 11.sp, color = OmniColors.textMuted)
                entries()
                TextButton(onClick = onAdd) {
                    Icon(Icons.Filled.Add, null, modifier = Modifier.size(16.dp))
                    Spacer(Modifier.width(4.dp))
                    Text(addLabel, fontSize = 12.sp)
                }
            }
        }
    }
}

/** One top-level volume or network: its name, whether it is external, and remove. Dimmed while commented out. */
@Composable
private fun TopLevelEntryRow(
    name: String,
    onName: (String) -> Unit,
    nameLabel: String,
    namePlaceholder: String,
    external: Boolean,
    onExternal: (Boolean) -> Unit,
    commentedOut: Boolean,
    removeDescription: String,
    onRemove: () -> Unit,
) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        OutlinedTextField(
            value = name,
            onValueChange = onName,
            label = { Text(nameLabel) },
            placeholder = { Text(namePlaceholder) },
            singleLine = true,
            colors = omniTextFieldColors(),
            modifier = Modifier.weight(1f).then(if (commentedOut) Modifier.alpha(0.45f) else Modifier),
        )
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text(stringResource(R.string.ext), fontSize = 10.sp, color = OmniColors.textMuted)
            Switch(checked = external, onCheckedChange = onExternal)
        }
        if (commentedOut) {
            Text(stringResource(R.string.commented), fontSize = 9.sp, color = OmniColors.textMuted, fontFamily = OmniFonts.mono)
        }
        IconButton(onClick = onRemove) { Icon(Icons.Filled.Delete, removeDescription, tint = OmniColors.red, modifier = Modifier.size(20.dp)) }
    }
}

@Composable
private fun Field(label: String, value: String, placeholder: String, modifier: Modifier = Modifier, onChange: (String) -> Unit) {
    OutlinedTextField(
        value = value,
        onValueChange = onChange,
        label = { Text(label) },
        placeholder = { Text(placeholder) },
        singleLine = true,
        colors = omniTextFieldColors(),
        modifier = modifier.fillMaxWidth(),
    )
}

@Composable
fun ListEditor(title: String, items: List<String>, placeholderText: String, modifier: Modifier = Modifier, onChange: (MutableList<String>) -> Unit) {
    Column(modifier.fillMaxWidth().padding(top = 12.dp).testTag("compose-list-$title")) {
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
                        modifier = Modifier.weight(1f).testTag("compose-list-$title-item-$i"),
                    )
                    IconButton(onClick = {
                        val n = items.toMutableList(); n.removeAt(i); onChange(n)
                    }) { Icon(Icons.Filled.Delete, "Remove", tint = OmniColors.red, modifier = Modifier.size(20.dp)) }
                }
            }
            TextButton(
                onClick = { val n = items.toMutableList(); n.add(""); onChange(n) },
                modifier = Modifier.semantics { contentDescription = "Add $title" },
            ) {
                Icon(Icons.Filled.Add, null, modifier = Modifier.size(16.dp))
                Spacer(Modifier.width(4.dp))
                Text(stringResource(R.string.add), fontSize = 12.sp)
            }
        }
    }
}
