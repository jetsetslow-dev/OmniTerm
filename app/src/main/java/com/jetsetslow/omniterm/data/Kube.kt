package com.jetsetslow.omniterm.data

import com.jetsetslow.omniterm.data.RemoteCommands.shellQuote
import java.util.Calendar
import java.util.TimeZone

/** What a pod, deployment or node's state means at a glance, for its colour. */
enum class KubeHealth { Ok, Progressing, Failed, Idle }

/** The Kubernetes tab's lists. */
enum class KubeView { Pods, Deployments, Services, Nodes }

data class KubePod(
    val namespace: String,
    val name: String,
    /** As kubectl's STATUS column says it: Running, Pending, CrashLoopBackOff, Completed, Init:Error… */
    val status: String,
    val ready: Int,
    val total: Int,
    val restarts: Int,
    val node: String,
    val ip: String,
    val startedAt: Long?,
    val containers: List<String>,
) {
    val health: KubeHealth get() = Kube.podHealth(status, ready, total)
}

data class KubeDeployment(
    val namespace: String,
    val name: String,
    val desired: Int,
    val ready: Int,
    val upToDate: Int,
    val available: Int,
    val images: List<String>,
    val createdAt: Long?,
) {
    val health: KubeHealth
        get() = when {
            desired == 0 -> KubeHealth.Idle
            ready >= desired && available >= desired -> KubeHealth.Ok
            ready == 0 -> KubeHealth.Failed
            else -> KubeHealth.Progressing
        }
}

data class KubeService(
    val namespace: String,
    val name: String,
    val type: String,
    val clusterIp: String,
    /** "80/TCP", or "80:30080/TCP" when the port is also open on every node. */
    val ports: List<String>,
    /** Load balancer addresses, external IPs, or an ExternalName's target. */
    val external: List<String>,
    val createdAt: Long?,
)

data class KubeNode(
    val name: String,
    val ready: Boolean,
    val schedulable: Boolean,
    val roles: List<String>,
    val version: String,
    val internalIp: String,
    val os: String,
    val cpu: String,
    val memory: String,
    val createdAt: Long?,
) {
    val health: KubeHealth
        get() = when {
            !ready -> KubeHealth.Failed
            !schedulable -> KubeHealth.Progressing
            else -> KubeHealth.Ok
        }
}

/**
 * How kubectl runs on a host: the command ("kubectl", "k3s kubectl", "microk8s kubectl"), the
 * config it was pointed at when OmniTerm had to choose one, its contexts, and the namespace the
 * current context names.
 */
data class KubeSetup(
    val kubectl: String,
    val kubeconfig: String?,
    val contexts: List<String>,
    val currentContext: String?,
    val defaultNamespace: String?,
)

/** One host's cluster as last loaded; a list that could not be read has its error in [errors]. */
data class KubeSnapshot(
    val setup: KubeSetup,
    val context: String?,
    val namespaces: List<String> = emptyList(),
    val pods: List<KubePod> = emptyList(),
    val deployments: List<KubeDeployment> = emptyList(),
    val services: List<KubeService> = emptyList(),
    val nodes: List<KubeNode> = emptyList(),
    val errors: Map<KubeView, String> = emptyMap(),
)

/**
 * Kubernetes through the kubectl on a host, over SSH. Each list is one `kubectl get` with a
 * jsonpath template that prints one tab-separated row per object, so a large cluster sends rows
 * rather than its full JSON.
 */
object Kube {
    const val NO_KUBECTL = "kubectl is not installed on this host."
    private const val TIMEOUT_SECONDS = 20

    /**
     * Finds kubectl, or the copy k3s and MicroK8s carry. k3s's own kubectl reads
     * /etc/rancher/k3s/k3s.yaml, which only root can read, even when ~/.kube/config exists; so
     * ~/.kube/config is named outright when the user has one, which is also the file plain kubectl
     * reads by default.
     */
    private const val RESOLVE =
        "if command -v kubectl >/dev/null 2>&1; then K=kubectl; " +
            "elif command -v k3s >/dev/null 2>&1; then K='k3s kubectl'; " +
            "elif command -v microk8s >/dev/null 2>&1; then K='microk8s kubectl'; " +
            "else echo '$NO_KUBECTL' >&2; exit 127; fi; " +
            "if [ -z \"\${KUBECONFIG:-}\" ] && [ -f \"\$HOME/.kube/config\" ]; then KUBECONFIG=\"\$HOME/.kube/config\"; export KUBECONFIG; fi; "

    private fun script(body: String) = RemoteCommands.OT_HELPER + RESOLVE + body

    private fun kubectl(context: String?) =
        "\$K" + (context?.let { " --context=" + shellQuote(it) } ?: "") + " --request-timeout=15s"

    private fun scope(namespace: String) =
        if (namespace.isBlank()) " --all-namespaces" else " --namespace=" + shellQuote(namespace)

    /** Prints the kubectl in use, the config chosen for it, the contexts, the current one and its namespace. */
    val SETUP: String = script(
        "echo \"@@kubectl \$K\"; echo \"@@kubeconfig \${KUBECONFIG:-}\"; " +
            "ot 10 \$K config get-contexts -o name || exit \$?; " +
            "echo @@current; ot 10 \$K config current-context 2>/dev/null; " +
            "echo @@namespace; ot 10 \$K config view --minify -o jsonpath='{..namespace}' 2>/dev/null; echo",
    )

    private fun rows(vararg fields: String) = "{range .items[*]}" + fields.joinToString("{\"\\t\"}") + "{\"\\n\"}{end}"

    private val POD_ROW = rows(
        "{.metadata.namespace}", "{.metadata.name}", "{.status.phase}", "{.status.reason}",
        "{.metadata.deletionTimestamp}", "{.spec.nodeName}", "{.status.podIP}", "{.status.startTime}",
        "{.metadata.creationTimestamp}", "{.spec.containers[*].name}", "{.status.containerStatuses[*].ready}",
        "{.status.containerStatuses[*].restartCount}", "{.status.containerStatuses[*].state.waiting.reason}",
        "{.status.containerStatuses[*].state.terminated.reason}", "{.status.initContainerStatuses[*].state.waiting.reason}",
    )
    private val DEPLOYMENT_ROW = rows(
        "{.metadata.namespace}", "{.metadata.name}", "{.spec.replicas}", "{.status.readyReplicas}",
        "{.status.updatedReplicas}", "{.status.availableReplicas}", "{.metadata.creationTimestamp}",
        "{.spec.template.spec.containers[*].image}",
    )
    private val SERVICE_ROW = rows(
        "{.metadata.namespace}", "{.metadata.name}", "{.spec.type}", "{.spec.clusterIP}",
        "{range .spec.ports[*]}{.port}:{.nodePort}/{.protocol},{end}", "{.status.loadBalancer.ingress[*].ip}",
        "{.status.loadBalancer.ingress[*].hostname}", "{.spec.externalIPs[*]}", "{.spec.externalName}",
        "{.metadata.creationTimestamp}",
    )
    private val NODE_ROW = rows(
        "{.metadata.name}", "{.status.conditions[?(@.type==\"Ready\")].status}", "{.spec.unschedulable}",
        "{.status.nodeInfo.kubeletVersion}", "{.status.addresses[?(@.type==\"InternalIP\")].address}",
        "{.status.nodeInfo.osImage}", "{.status.allocatable.cpu}", "{.status.allocatable.memory}",
        "{.metadata.creationTimestamp}", "{.metadata.labels}",
    )
    private val NAMESPACE_ROW = rows("{.metadata.name}")

    private fun get(context: String?, resource: String, namespace: String?, row: String) = script(
        "ot $TIMEOUT_SECONDS ${kubectl(context)} get $resource" + (namespace?.let(::scope) ?: "") +
            " -o jsonpath=" + shellQuote(row),
    )

    /** The command listing [view] in [namespace] (blank: every namespace). */
    fun list(view: KubeView, context: String?, namespace: String): String = when (view) {
        KubeView.Pods -> get(context, "pods", namespace, POD_ROW)
        KubeView.Deployments -> get(context, "deployments", namespace, DEPLOYMENT_ROW)
        KubeView.Services -> get(context, "services", namespace, SERVICE_ROW)
        KubeView.Nodes -> get(context, "nodes", null, NODE_ROW)
    }

    fun namespaces(context: String?): String = get(context, "namespaces", null, NAMESPACE_ROW)

    /** kubectl in one [namespace]; every command given it names an object there. */
    private fun inNamespace(context: String?, namespace: String): String {
        require(namespace.isNotBlank()) { "An object's namespace is never blank" }
        return kubectl(context) + scope(namespace)
    }

    /** A pod's last 200 log lines, every container's when it has several; [follow] keeps streaming. */
    fun podLogs(context: String?, pod: KubePod, follow: Boolean, previous: Boolean): String = script(
        inNamespace(context, pod.namespace) + " logs " + shellQuote(pod.name) +
            (if (pod.containers.size > 1) " --all-containers=true --prefix=true" else "") +
            " --tail=200" + (if (follow) " --follow" else "") + (if (previous) " --previous" else ""),
    )

    fun deploymentLogs(context: String?, deployment: KubeDeployment): String = script(
        inNamespace(context, deployment.namespace) + " logs " + shellQuote("deployment/${deployment.name}") +
            " --all-containers=true --prefix=true --tail=200",
    )

    /** `kubectl describe`; [namespace] is null for cluster-wide kinds (nodes). */
    fun describe(context: String?, kind: String, namespace: String?, name: String): String = script(
        (if (namespace == null) kubectl(context) else inNamespace(context, namespace)) +
            " describe " + kind + " " + shellQuote(name),
    )

    /** Deletes a pod without waiting for it to go; its controller starts a fresh one. */
    fun deletePod(context: String?, pod: KubePod): String = script(
        inNamespace(context, pod.namespace) + " delete pod " + shellQuote(pod.name) + " --wait=false",
    )

    fun scale(context: String?, deployment: KubeDeployment, replicas: Int): String {
        require(replicas in 0..MAX_REPLICAS) { "Replicas must be 0 to $MAX_REPLICAS" }
        return script(
            inNamespace(context, deployment.namespace) + " scale " + shellQuote("deployment/${deployment.name}") +
                " --replicas=$replicas",
        )
    }

    /** Replaces a deployment's pods one by one, as after a config change. */
    fun restart(context: String?, deployment: KubeDeployment): String = script(
        inNamespace(context, deployment.namespace) + " rollout restart " + shellQuote("deployment/${deployment.name}"),
    )

    /** Stops new pods landing on [node] ([cordon]), or lets them again. */
    fun cordon(context: String?, node: KubeNode, cordon: Boolean): String = script(
        kubectl(context) + (if (cordon) " cordon " else " uncordon ") + shellQuote(node.name),
    )

    /**
     * Events in [namespace] (blank: every namespace), oldest first so the newest end the output.
     * The scope follows `get`: kubectl takes a namespace before the command but not
     * --all-namespaces, which there turned the command into `kubectl events` and failed.
     */
    fun events(context: String?, namespace: String): String = script(
        kubectl(context) + " get events" + scope(namespace) + " --sort-by=.metadata.creationTimestamp",
    )

    /**
     * What to type into a terminal to open a shell in [pod]. It runs in the user's own login shell,
     * which may be fish or csh, so it names kubectl outright rather than through a variable.
     */
    fun execShell(setup: KubeSetup, context: String?, pod: KubePod, container: String?): String =
        (setup.kubeconfig?.let { "env KUBECONFIG=" + shellQuote(it) + " " } ?: "") +
            setup.kubectl + (context?.let { " --context=" + shellQuote(it) } ?: "") +
            " --namespace=" + shellQuote(pod.namespace) + " exec -it " + shellQuote(pod.name) +
            (container?.let { " --container=" + shellQuote(it) } ?: "") + " -- " + RemoteCommands.CONTAINER_SHELL

    const val MAX_REPLICAS = 1000

    // ── Parsing ──

    /** Null when [output] does not start with the lines [SETUP] prints. */
    fun parseSetup(output: String): KubeSetup? {
        val lines = output.lines()
        val kubectl = lines.firstOrNull { it.startsWith("@@kubectl ") }?.removePrefix("@@kubectl ")?.trim()
            ?.takeIf { it.isNotEmpty() } ?: return null
        val kubeconfig = lines.firstOrNull { it.startsWith("@@kubeconfig") }?.removePrefix("@@kubeconfig")?.trim()
        fun section(name: String): List<String> {
            val start = lines.indexOf(name)
            if (start < 0) return emptyList()
            return lines.drop(start + 1).takeWhile { !it.startsWith("@@") }.map { it.trim() }.filter { it.isNotEmpty() }
        }
        val contextsStart = lines.indexOfFirst { it.startsWith("@@kubeconfig") }
        val contexts = lines.drop(contextsStart + 1).takeWhile { !it.startsWith("@@") }
            .map { it.trim() }.filter { it.isNotEmpty() }
        return KubeSetup(
            kubectl = kubectl,
            kubeconfig = kubeconfig?.takeIf { it.isNotEmpty() },
            contexts = contexts,
            currentContext = section("@@current").firstOrNull(),
            // A context naming several (the jsonpath matches each) uses its own, the first.
            defaultNamespace = section("@@namespace").firstOrNull()?.split(' ')?.firstOrNull()?.takeIf { it.isNotEmpty() },
        )
    }

    private fun fields(output: String, count: Int): List<List<String>> =
        output.lineSequence().map { it.split('\t') }.filter { it.size == count }.toList()

    private fun words(text: String) = text.split(' ').filter { it.isNotEmpty() }

    private val DNS_NAME = Regex("[a-z0-9]([-a-z0-9]*[a-z0-9])?(\\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*")

    /** Whether [name] is a valid Kubernetes object name; rows naming anything else are dropped. */
    fun isValidName(name: String): Boolean = name.length in 1..253 && DNS_NAME.matches(name)

    fun parseNamespaces(output: String): List<String> =
        fields(output, 1).map { it[0].trim() }.filter(::isValidName).sorted()

    // Each list's rows are the fields its jsonpath template prints, in that order; the direct API
    // client builds the same rows from the API's JSON, so both read objects the same way.
    const val POD_FIELDS = 15
    const val DEPLOYMENT_FIELDS = 8
    const val SERVICE_FIELDS = 10
    const val NODE_FIELDS = 10

    fun parsePods(output: String): List<KubePod> = fields(output, POD_FIELDS).mapNotNull(::podFromRow)

    fun podFromRow(f: List<String>): KubePod? {
        val (namespace, name) = f[0] to f[1]
        if (!isValidName(namespace) || !isValidName(name)) return null
        val containers = words(f[9])
        val readiness = words(f[10])
        return KubePod(
            namespace = namespace,
            name = name,
            status = podStatus(
                phase = f[2], reason = f[3], deleting = f[4].isNotBlank(),
                waiting = words(f[12]), terminated = words(f[13]), initWaiting = words(f[14]),
            ),
            ready = readiness.count { it == "true" },
            total = maxOf(containers.size, readiness.size),
            restarts = words(f[11]).sumOf { it.toIntOrNull() ?: 0 },
            node = f[5],
            ip = f[6],
            startedAt = parseTime(f[7]) ?: parseTime(f[8]),
            containers = containers,
        )
    }

    /** The status kubectl shows for a pod, from its phase and its containers' states. */
    fun podStatus(
        phase: String,
        reason: String,
        deleting: Boolean,
        waiting: List<String>,
        terminated: List<String>,
        initWaiting: List<String>,
    ): String {
        val initReason = initWaiting.firstOrNull { it != "PodInitializing" }
        return when {
            deleting -> "Terminating"
            reason.isNotBlank() -> reason
            initReason != null -> "Init:$initReason"
            waiting.isNotEmpty() -> waiting.first()
            phase == "Running" -> "Running"
            terminated.isNotEmpty() -> terminated.first()
            phase == "Succeeded" -> "Completed"
            else -> phase.ifBlank { "Unknown" }
        }
    }

    private val FAILED_STATES = setOf(
        "CrashLoopBackOff", "Error", "Failed", "ImagePullBackOff", "ErrImagePull", "ErrImageNeverPull",
        "InvalidImageName", "CreateContainerConfigError", "CreateContainerError", "RunContainerError",
        "ContainerCannotRun", "StartError", "OOMKilled", "Evicted", "NodeLost", "Unknown", "DeadlineExceeded",
    )

    fun podHealth(status: String, ready: Int, total: Int): KubeHealth = when {
        status == "Completed" || status == "Succeeded" -> KubeHealth.Idle
        status.removePrefix("Init:") in FAILED_STATES -> KubeHealth.Failed
        status == "Running" && ready >= total -> KubeHealth.Ok
        else -> KubeHealth.Progressing
    }

    fun parseDeployments(output: String): List<KubeDeployment> = fields(output, DEPLOYMENT_FIELDS).mapNotNull(::deploymentFromRow)

    fun deploymentFromRow(f: List<String>): KubeDeployment? {
        if (!isValidName(f[0]) || !isValidName(f[1])) return null
        return KubeDeployment(
            namespace = f[0],
            name = f[1],
            // An unset replica count means one, as the API defaults it.
            desired = f[2].toIntOrNull() ?: 1,
            ready = f[3].toIntOrNull() ?: 0,
            upToDate = f[4].toIntOrNull() ?: 0,
            available = f[5].toIntOrNull() ?: 0,
            images = words(f[7]),
            createdAt = parseTime(f[6]),
        )
    }

    fun parseServices(output: String): List<KubeService> = fields(output, SERVICE_FIELDS).mapNotNull(::serviceFromRow)

    fun serviceFromRow(f: List<String>): KubeService? {
        if (!isValidName(f[0]) || !isValidName(f[1])) return null
        return KubeService(
            namespace = f[0],
            name = f[1],
            type = f[2],
            clusterIp = f[3],
            ports = f[4].split(',').filter { it.isNotBlank() }.map { it.replace(":/", "/") },
            external = (words(f[5]) + words(f[6]) + words(f[7]) + words(f[8])).distinct(),
            createdAt = parseTime(f[9]),
        )
    }

    private val ROLE_LABEL = Regex("\"node-role\\.kubernetes\\.io/([^\"]+)\"")
    private val LEGACY_ROLE_LABEL = Regex("\"kubernetes\\.io/role\":\"([^\"]+)\"")

    fun parseNodes(output: String): List<KubeNode> = fields(output, NODE_FIELDS).mapNotNull(::nodeFromRow)

    fun nodeFromRow(f: List<String>): KubeNode? {
        if (!isValidName(f[0])) return null
        val labels = f[9]
        return KubeNode(
            name = f[0],
            ready = f[1] == "True",
            schedulable = f[2] != "true",
            roles = (ROLE_LABEL.findAll(labels).map { it.groupValues[1] } +
                LEGACY_ROLE_LABEL.findAll(labels).map { it.groupValues[1] }).distinct().sorted().toList(),
            version = f[3],
            internalIp = words(f[4]).firstOrNull().orEmpty(),
            os = f[5],
            cpu = formatCpu(f[6]),
            memory = formatMemory(f[7]),
            createdAt = parseTime(f[8]),
        )
    }

    /** "4" or "3800m" as cores: "4 CPU", "3.8 CPU". */
    fun formatCpu(quantity: String): String {
        val cores = if (quantity.endsWith("m")) quantity.dropLast(1).toDoubleOrNull()?.div(1000) else quantity.toDoubleOrNull()
        return cores?.let { "${trimNumber(it)} CPU" } ?: quantity
    }

    /** A memory quantity ("16318324Ki", "8Gi", "512M") in GiB or MiB. */
    fun formatMemory(quantity: String): String {
        val match = Regex("([0-9.]+)([KMGTP]i?|[kE]i?)?").matchEntire(quantity) ?: return quantity
        val number = match.groupValues[1].toDoubleOrNull() ?: return quantity
        val unit = match.groupValues[2]
        val multiplier = when (unit) {
            "" -> 1.0
            "Ki" -> 1024.0
            "Mi" -> 1024.0 * 1024
            "Gi" -> 1024.0 * 1024 * 1024
            "Ti" -> 1024.0 * 1024 * 1024 * 1024
            "k", "K" -> 1e3
            "M" -> 1e6
            "G" -> 1e9
            "T" -> 1e12
            else -> return quantity
        }
        val bytes = number * multiplier
        val gib = bytes / (1024.0 * 1024 * 1024)
        return if (gib >= 1) "${trimNumber(gib)} GiB" else "${trimNumber(bytes / (1024.0 * 1024))} MiB"
    }

    private fun trimNumber(value: Double): String {
        val rounded = Math.round(value * 10) / 10.0
        return if (rounded == Math.floor(rounded)) rounded.toLong().toString() else rounded.toString()
    }

    private val TIME = Regex("(\\d{4})-(\\d{2})-(\\d{2})T(\\d{2}):(\\d{2}):(\\d{2})(?:\\.\\d+)?(Z|[+-]\\d{2}:\\d{2})")

    /** An RFC 3339 time, as the API writes them, in epoch milliseconds; null when [text] is none. */
    fun parseTime(text: String): Long? {
        val m = TIME.matchEntire(text.trim()) ?: return null
        val g = m.groupValues
        val calendar = Calendar.getInstance(TimeZone.getTimeZone("UTC")).apply {
            clear()
            set(g[1].toInt(), g[2].toInt() - 1, g[3].toInt(), g[4].toInt(), g[5].toInt(), g[6].toInt())
        }
        val zone = g[7]
        val offsetMinutes = if (zone == "Z") 0 else {
            val sign = if (zone[0] == '-') -1 else 1
            sign * (zone.substring(1, 3).toInt() * 60 + zone.substring(4, 6).toInt())
        }
        return calendar.timeInMillis - offsetMinutes * 60_000L
    }

    /** An age as kubectl prints it: 45s, 12m, 30h, 9d. */
    fun age(since: Long?, now: Long): String {
        since ?: return "?"
        val seconds = ((now - since) / 1000).coerceAtLeast(0)
        return when {
            seconds < 120 -> "${seconds}s"
            seconds < 3600 -> "${seconds / 60}m"
            seconds < 48 * 3600 -> "${seconds / 3600}h"
            else -> "${seconds / 86_400}d"
        }
    }

    /** The message to show for a failed command's output: the transport's prefix removed, timeouts said plainly. */
    fun errorText(output: String): String {
        val detail = output.removePrefix("SSH Error: ").replace(Regex("^command failed \\((\\d+)\\): "), "").trim()
        return when {
            NO_KUBECTL in detail -> NO_KUBECTL
            detail == "Command exited with status 124" -> "kubectl did not answer within $TIMEOUT_SECONDS seconds."
            else -> detail
        }
    }

    /** What to do about [error], when it is a known setup problem rather than the cluster's answer. */
    enum class Hint { K3sRootOnly, NoCluster }

    fun hint(error: String): Hint? = when {
        "k3s.yaml" in error && "permission denied" in error -> Hint.K3sRootOnly
        "localhost:8080" in error -> Hint.NoCluster
        else -> null
    }

    /** Copies k3s's cluster config to where this user's kubectl looks, readable by this user only. */
    const val K3S_COPY_CONFIG =
        "mkdir -p ~/.kube && sudo k3s kubectl config view --raw > ~/.kube/config && chmod 600 ~/.kube/config"
}
