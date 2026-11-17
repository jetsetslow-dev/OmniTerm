package com.jetsetslow.omniterm.data

import com.squareup.moshi.Moshi
import java.util.Locale

/**
 * Whether the images a host's containers run have a newer build in their registry: the digest the
 * registry gives for the image's tag, asked with a manifest HEAD request on the host itself (so a
 * private registry on the host's network works, and the phone talks to no registry), compared with
 * the digests the host recorded when it pulled the image. A HEAD request does not count towards
 * Docker Hub's pull limit. Nothing is pulled or changed.
 *
 * Read by the [HostChecks.IMAGE_UPDATES] alert rule at most every 6 hours per host, and on demand
 * under Containers → Images at most every 10 minutes.
 *
 * Credit: the HEAD-request digest comparison is how Watchtower (containrrr/watchtower) and Cup
 * (sergi0g/cup) check for updates without pulling; no code is taken from either.
 */
object ImageUpdates {
    const val RULE_INTERVAL_MS = 6 * 3_600_000L
    const val MANUAL_INTERVAL_MS = 10 * 60_000L
    /** Each registry request gives up after this long. */
    const val REQUEST_TIMEOUT_SEC = 20
    /** At most this many images are asked about per check, to be gentle with registries. */
    const val MAX_IMAGES = 40

    /** An image reference as a registry knows it: `docker.io`, `library/nginx`, `1.27`. */
    data class Ref(val registry: String, val repository: String, val tag: String) {
        /** Docker Hub's API is not on docker.io itself. */
        val apiHost: String get() = if (registry == DOCKER_HUB) "registry-1.docker.io" else registry
        /** As people write it: `nginx:1.27`, `ghcr.io/owner/app:latest`. */
        val display: String get() = (if (registry == DOCKER_HUB) repository.removePrefix("library/") else "$registry/$repository") + ":$tag"
        val key: String get() = "$registry/$repository:$tag"
        val manifestUrl: String get() = "https://$apiHost/v2/$repository/manifests/$tag"
    }

    private const val DOCKER_HUB = "docker.io"
    private val COMPONENT = Regex("""^[a-z0-9]+(?:(?:[._]|__|-+)[a-z0-9]+)*$""")
    private val TAG = Regex("""^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$""")
    private val HOST = Regex("""^[A-Za-z0-9.-]+(?::[0-9]{1,5})?$""")
    private val IMAGE_ID = Regex("""^(?:sha256:)?[0-9a-f]{12,64}$""")

    /** Why a reference is not asked about, or null when it can be. */
    fun skipReason(reference: String): String? {
        val text = reference.trim()
        return when {
            text.isEmpty() || IMAGE_ID.matches(text) -> "the container names no image tag"
            '@' in text -> "pinned to a digest"
            text.startsWith("localhost/") -> "built on this host"
            parse(text) == null -> "not a registry image name"
            else -> null
        }
    }

    /**
     * [reference] as Docker reads it: the first part is a registry when it has a dot or a port or
     * is `localhost`; otherwise the image is on Docker Hub, where a bare name is under `library/`.
     * Null for an image ID, a digest reference or a name that is not valid.
     */
    fun parse(reference: String): Ref? {
        val text = reference.trim()
        if (text.isEmpty() || '@' in text || IMAGE_ID.matches(text)) return null
        val lastSlash = text.lastIndexOf('/')
        val colon = text.lastIndexOf(':')
        val (name, tag) = if (colon > lastSlash) text.substring(0, colon) to text.substring(colon + 1) else text to "latest"
        if (!TAG.matches(tag)) return null
        val parts = name.split('/')
        val first = parts.first()
        val hasRegistry = parts.size > 1 && ('.' in first || ':' in first || first == "localhost")
        val registry = if (hasRegistry) first.lowercase(Locale.ROOT) else DOCKER_HUB
        if (hasRegistry && !HOST.matches(registry)) return null
        var path = (if (hasRegistry) parts.drop(1) else parts)
        if (path.isEmpty() || path.any { !COMPONENT.matches(it) }) return null
        val normalizedRegistry = if (registry == "index.docker.io" || registry == "registry-1.docker.io") DOCKER_HUB else registry
        if (normalizedRegistry == DOCKER_HUB && path.size == 1) path = listOf("library") + path
        return Ref(normalizedRegistry, path.joinToString("/"), tag)
    }

    /**
     * `!RUNTIME name` for each runtime that answers, then one line per image a container uses:
     * `runtime \t reference \t RepoDigests as JSON`, or `!MISSING` when the image is gone. Then
     * `!NOCURL` when the host has no curl to ask registries with.
     */
    val LIST: String = buildString {
        append(RemoteCommands.OT_HELPER)
        append("for r in docker podman; do command -v \"\$r\" >/dev/null 2>&1 && ot 10 \"\$r\" ps >/dev/null 2>&1 || continue; echo \"!RUNTIME \$r\"; ")
        append("ot 15 \"\$r\" ps -a --format '{{.Image}}' 2>/dev/null | sort -u | while IFS= read -r i; do [ -n \"\$i\" ] || continue; ")
        append("d=\$(ot 10 \"\$r\" image inspect --format '{{json .RepoDigests}}' \"\$i\" 2>/dev/null) || d='!MISSING'; ")
        append("printf '%s\\t%s\\t%s\\n' \"\$r\" \"\$i\" \"\$d\"; done; done; ")
        append("command -v curl >/dev/null 2>&1 || echo '!NOCURL'; true")
    }

    /** An image a container uses, with the digests the host recorded for it. */
    data class Local(val runtime: String, val reference: String, val digests: Set<String>?, val missing: Boolean = false)

    data class Listing(val images: List<Local>, val curl: Boolean, val runtimes: Set<String> = setOf("docker"))

    private val json = Moshi.Builder().build().adapter(Any::class.java).lenient()

    fun parseListing(raw: String): Listing {
        val images = raw.lineSequence().mapNotNull { line ->
            val cells = line.trimEnd('\r').split('\t')
            if (cells.size < 3 || cells[0] !in setOf("docker", "podman")) return@mapNotNull null
            val missing = cells[2].trim() == "!MISSING"
            val digests = if (missing) null else runCatching { json.fromJson(cells[2].trim()) as? List<*> }.getOrNull()
                ?.mapNotNull { (it as? String)?.substringAfter('@', "")?.takeIf { d -> d.startsWith("sha256:") } }?.toSet()
            Local(cells[0], cells[1].trim(), digests, missing)
        }.toList()
        val runtimes = raw.lineSequence().mapNotNull { it.trim().removePrefix("!RUNTIME ").takeIf { r -> it.trim().startsWith("!RUNTIME ") } }.toSet()
        return Listing(images, curl = raw.lineSequence().none { it.trim() == "!NOCURL" }, runtimes = runtimes)
    }

    private const val ACCEPT = "application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json," +
        "application/vnd.docker.distribution.manifest.v2+json,application/vnd.oci.image.manifest.v1+json"

    /**
     * Asks each registry for [refs]' digests: a HEAD request for the manifest, and when the registry
     * answers 401 with a Bearer challenge, an anonymous pull token from the realm it names, sent on
     * curl's standard input so it never appears in a command line. A registry CA the host trusts
     * for Docker or Podman (`/etc/docker/certs.d`, `/etc/containers/certs.d`) is trusted here too.
     * Prints `!OK \t key \t digest` or `!ERR \t key \t reason [\t detail]` per image.
     */
    fun checkCommand(refs: List<Ref>): String = buildString {
        append(RemoteCommands.OT_HELPER)
        append("A='$ACCEPT'; ")
        // A header's value from a header block (names are case-insensitive), and the status code.
        append("hd(){ tr -d '\\r' | awk -v k=\"\$1\" 'tolower(substr(\$0,1,length(k)+1))==tolower(k\":\"){sub(/^[^:]*:[ \\t]*/,\"\"); print; exit}'; }; ")
        append("st(){ tr -d '\\r' | awk 'NR==1{print \$2; exit}'; }; ")
        append("ca(){ for f in \"/etc/docker/certs.d/\$1/ca.crt\" \"/etc/containers/certs.d/\$1/ca.crt\"; do [ -r \"\$f\" ] && { printf '%s' \"\$f\"; return; }; done; }; ")
        // q HOST CURL-ARGS…: a HEAD request, trusting HOST's own CA when the host has one.
        append("q(){ c=\$(ca \"\$1\"); shift; if [ -n \"\$c\" ]; then ot $REQUEST_TIMEOUT_SEC curl -sSI --cacert \"\$c\" -H \"Accept: \$A\" \"\$@\"; ")
        append("else ot $REQUEST_TIMEOUT_SEC curl -sSI -H \"Accept: \$A\" \"\$@\"; fi; }; ")
        append("ck(){ k=\$1; h=\$2; u=\$3; o=\$(q \"\$h\" \"\$u\" 2>&1) || { printf '!ERR\\t%s\\tunreachable\\t%s\\n' \"\$k\" \"\$(printf '%s' \"\$o\" | tail -n 1)\"; return; }; ")
        append("s=\$(printf '%s\\n' \"\$o\" | st); ")
        append("if [ \"\$s\" = 401 ]; then w=\$(printf '%s\\n' \"\$o\" | hd www-authenticate); ")
        append("case \"\$w\" in [Bb]earer*) ;; *) printf '!ERR\\t%s\\tsignin\\n' \"\$k\"; return;; esac; ")
        append("realm=\$(printf '%s' \"\$w\" | sed -n 's/.*realm=\"\\([^\"]*\\)\".*/\\1/p'); ")
        append("svc=\$(printf '%s' \"\$w\" | sed -n 's/.*service=\"\\([^\"]*\\)\".*/\\1/p'); ")
        append("scope=\$(printf '%s' \"\$w\" | sed -n 's/.*scope=\"\\([^\"]*\\)\".*/\\1/p'); ")
        append("case \"\$realm\" in https://*) ;; *) printf '!ERR\\t%s\\tsignin\\n' \"\$k\"; return;; esac; ")
        append("t=\$(ot $REQUEST_TIMEOUT_SEC curl -sS -G --data-urlencode \"service=\$svc\" --data-urlencode \"scope=\$scope\" \"\$realm\" 2>/dev/null ")
        append("| sed -n 's/.*\"token\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p' | head -n 1); ")
        append("[ -n \"\$t\" ] || { printf '!ERR\\t%s\\tsignin\\n' \"\$k\"; return; }; ")
        append("o=\$(printf 'Authorization: Bearer %s\\n' \"\$t\" | q \"\$h\" -H @- \"\$u\" 2>&1) || { printf '!ERR\\t%s\\tunreachable\\t%s\\n' \"\$k\" \"\$(printf '%s' \"\$o\" | tail -n 1)\"; return; }; ")
        append("s=\$(printf '%s\\n' \"\$o\" | st); fi; ")
        append("case \"\$s\" in 200) d=\$(printf '%s\\n' \"\$o\" | hd docker-content-digest); ")
        append("if [ -n \"\$d\" ]; then printf '!OK\\t%s\\t%s\\n' \"\$k\" \"\$d\"; else printf '!ERR\\t%s\\tnodigest\\n' \"\$k\"; fi;; ")
        append("401|403) printf '!ERR\\t%s\\tsignin\\n' \"\$k\";; 404) printf '!ERR\\t%s\\tnotfound\\n' \"\$k\";; ")
        append("429) printf '!ERR\\t%s\\tlimited\\n' \"\$k\";; *) printf '!ERR\\t%s\\tstatus\\t%s\\n' \"\$k\" \"\$s\";; esac; }; ")
        // All at once, so one slow registry does not hold up the rest; each prints one line.
        for (ref in refs) {
            append("ck ${RemoteCommands.shellQuote(ref.key)} ${RemoteCommands.shellQuote(ref.apiHost)} ${RemoteCommands.shellQuote(ref.manifestUrl)} & ")
        }
        append("wait; true")
    }

    /** What the registry said for one image key. */
    sealed class Remote {
        data class Digest(val digest: String) : Remote()
        data class Failed(val reason: String) : Remote()
    }

    fun parseCheck(raw: String): Map<String, Remote> = raw.lineSequence().mapNotNull { line ->
        val cells = line.trimEnd('\r').split('\t')
        when (cells.firstOrNull()) {
            "!OK" -> cells.getOrNull(1)?.let { it to Remote.Digest(cells.getOrNull(2).orEmpty().trim()) }
            "!ERR" -> cells.getOrNull(1)?.let { it to Remote.Failed(reasonText(cells.getOrNull(2).orEmpty(), cells.getOrNull(3).orEmpty())) }
            else -> null
        }
    }.toMap()

    private fun reasonText(code: String, detail: String): String = when (code) {
        "signin" -> "the registry needs a sign-in"
        "notfound" -> "not found in the registry"
        "limited" -> "the registry's rate limit was reached"
        "nodigest" -> "the registry gave no digest"
        "status" -> "the registry answered $detail"
        else -> "the registry could not be reached" + if (detail.isNotBlank()) " (${detail.trim().take(120)})" else ""
    }

    enum class State { UPDATE, CURRENT, NOT_CHECKED }

    /** One image's verdict, as Containers → Images shows it. */
    data class Status(val runtime: String, val reference: String, val display: String, val state: State, val reason: String = "")

    /** A host's last check: when, each image's verdict, or why nothing could be checked. */
    data class Report(val checkedAt: Long, val images: List<Status>, val problem: String? = null) {
        val updates: List<Status> get() = images.filter { it.state == State.UPDATE }
        /** Whether any image was compared at all; when none was, the check says nothing. */
        val anyCompared: Boolean get() = images.any { it.state != State.NOT_CHECKED }
    }

    /** The images [listing] asks the registries about, at most [MAX_IMAGES], each once. */
    fun refsToCheck(listing: Listing): List<Ref> =
        listing.images.filter { !it.missing && !it.digests.isNullOrEmpty() && skipReason(it.reference) == null }
            .mapNotNull { parse(it.reference) }.distinctBy { it.key }.take(MAX_IMAGES)

    /** Each image of [listing] judged against what the registries said ([remote], by key). */
    fun report(listing: Listing, remote: Map<String, Remote>, now: Long): Report {
        val statuses = listing.images.map { local ->
            val ref = parse(local.reference)
            val display = ref?.display ?: local.reference
            fun notChecked(reason: String) = Status(local.runtime, local.reference, display, State.NOT_CHECKED, reason)
            val skip = skipReason(local.reference)
            when {
                skip != null -> notChecked(skip)
                local.missing -> notChecked("the image is no longer on this host")
                local.digests.isNullOrEmpty() -> notChecked("built on this host")
                else -> when (val answer = remote[ref!!.key]) {
                    is Remote.Digest -> Status(
                        local.runtime, local.reference, display,
                        if (answer.digest in local.digests) State.CURRENT else State.UPDATE,
                    )
                    is Remote.Failed -> notChecked(answer.reason)
                    null -> notChecked("more than $MAX_IMAGES images; not asked")
                }
            }
        }
        return Report(now, statuses)
    }

    /** Whether [status] is about the image shown as [repository]:[tag] on [runtime]. */
    fun matches(status: Status, runtime: String, repository: String, tag: String): Boolean {
        if (status.runtime != runtime) return false
        val shown = parse("$repository:$tag") ?: return false
        return parse(status.reference)?.key == shown.key
    }

    /** The reading for an alert rule: how many images have an update. */
    fun count(report: Report): Float = report.updates.distinctBy { it.display }.size.toFloat()

    fun names(report: Report): List<String> = report.updates.map { it.display }.distinct()
}
