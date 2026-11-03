package com.jetsetslow.omniterm.data

import com.jetsetslow.omniterm.data.KubeApi.Companion.list
import com.jetsetslow.omniterm.data.KubeApi.Companion.text
import com.jetsetslow.omniterm.data.term.ByteStreamTerminalSession
import com.squareup.moshi.Moshi
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import okio.ByteString.Companion.toByteString
import org.bouncycastle.asn1.DERNull
import org.bouncycastle.asn1.ASN1ObjectIdentifier
import org.bouncycastle.asn1.pkcs.PKCSObjectIdentifiers
import org.bouncycastle.asn1.pkcs.PrivateKeyInfo
import org.bouncycastle.asn1.pkcs.RSAPrivateKey
import org.bouncycastle.asn1.sec.ECPrivateKey
import org.bouncycastle.asn1.x509.AlgorithmIdentifier
import org.bouncycastle.asn1.x9.X9ObjectIdentifiers
import org.bouncycastle.util.encoders.Base64
import java.io.ByteArrayInputStream
import java.io.IOException
import java.security.KeyFactory
import java.security.KeyStore
import java.security.PrivateKey
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.security.spec.PKCS8EncodedKeySpec
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManagerFactory
import javax.net.ssl.X509TrustManager

/** PEM certificates and private keys as kubeconfigs carry them. */
object KubePem {
    private val BLOCK = Regex("-----BEGIN ([A-Z0-9 ]+)-----([\\s\\S]*?)-----END \\1-----")
    private val ED25519 = ASN1ObjectIdentifier("1.3.101.112")

    fun certificates(pem: String): List<X509Certificate> {
        val certificates = try {
            CertificateFactory.getInstance("X.509")
                .generateCertificates(ByteArrayInputStream(pem.toByteArray(Charsets.US_ASCII)))
                .filterIsInstance<X509Certificate>()
        } catch (e: java.security.cert.CertificateException) {
            throw IllegalArgumentException("A certificate in this cluster's config could not be read: ${e.message}", e)
        }
        if (certificates.isEmpty()) throw IllegalArgumentException("No certificate found in this cluster's config.")
        return certificates
    }

    /** A PKCS#8 ("PRIVATE KEY"), PKCS#1 ("RSA PRIVATE KEY") or SEC 1 ("EC PRIVATE KEY") key. */
    fun privateKey(pem: String): PrivateKey {
        val block = BLOCK.findAll(pem).firstOrNull { it.groupValues[1].endsWith("PRIVATE KEY") }
            ?: throw IllegalArgumentException("The client key is not a PEM private key.")
        val type = block.groupValues[1]
        val der = Base64.decode(block.groupValues[2].filterNot(Char::isWhitespace))
        val info = when (type) {
            "PRIVATE KEY" -> PrivateKeyInfo.getInstance(der)
            "RSA PRIVATE KEY" -> PrivateKeyInfo(AlgorithmIdentifier(PKCSObjectIdentifiers.rsaEncryption, DERNull.INSTANCE), RSAPrivateKey.getInstance(der))
            "EC PRIVATE KEY" -> {
                val key = ECPrivateKey.getInstance(der)
                PrivateKeyInfo(AlgorithmIdentifier(X9ObjectIdentifiers.id_ecPublicKey, key.parametersObject), key)
            }
            "ENCRYPTED PRIVATE KEY" -> throw IllegalArgumentException("The client key is protected by a passphrase, which kubeconfigs cannot carry.")
            else -> throw IllegalArgumentException("Client keys of type $type are not supported.")
        }
        val algorithm = when (info.privateKeyAlgorithm.algorithm) {
            PKCSObjectIdentifiers.rsaEncryption -> "RSA"
            X9ObjectIdentifiers.id_ecPublicKey -> "EC"
            ED25519 -> "Ed25519"
            else -> throw IllegalArgumentException("The client key's algorithm is not supported.")
        }
        return KeyFactory.getInstance(algorithm).generatePrivate(PKCS8EncodedKeySpec(info.encoded))
    }
}

/**
 * A Kubernetes API server reached from the phone, as one saved kubeconfig context describes it.
 * Lists come back in the rows [Kube] reads kubectl's output in, so both paths make the same objects.
 */
class KubeApi(private val cluster: KubeClusterEntity, baseClient: OkHttpClient = OkHttpClient()) {
    private val base: HttpUrl = cluster.server.trimEnd('/').toHttpUrl()

    private val client: OkHttpClient = run {
        val trust = trustManager()
        val context = SSLContext.getInstance("TLS")
        context.init(keyManagers(), arrayOf(trust), null)
        baseClient.newBuilder()
            .sslSocketFactory(context.socketFactory, trust)
            .connectTimeout(10, TimeUnit.SECONDS)
            .readTimeout(30, TimeUnit.SECONDS)
            .build()
    }

    /** The cluster's own CA when the config names one; the phone's trusted CAs otherwise. Never neither. */
    private fun trustManager(): X509TrustManager {
        val store = cluster.caPem.takeIf { it.isNotBlank() }?.let { pem ->
            KeyStore.getInstance(KeyStore.getDefaultType()).apply {
                load(null, null)
                KubePem.certificates(pem).forEachIndexed { i, certificate -> setCertificateEntry("ca$i", certificate) }
            }
        }
        val factory = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm())
        factory.init(store)
        return factory.trustManagers.filterIsInstance<X509TrustManager>().first()
    }

    private fun keyManagers() = if (cluster.clientCertPem.isBlank() || cluster.clientKeyPem.isBlank()) {
        null
    } else {
        val password = KEY_STORE_PASSWORD.toCharArray()
        val store = KeyStore.getInstance(KeyStore.getDefaultType()).apply {
            load(null, null)
            setKeyEntry(
                "client",
                KubePem.privateKey(cluster.clientKeyPem),
                password,
                KubePem.certificates(cluster.clientCertPem).toTypedArray(),
            )
        }
        KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm()).apply { init(store, password) }.keyManagers
    }

    private fun url(path: String, query: Map<String, String?> = emptyMap()): HttpUrl {
        val builder = base.newBuilder()
        path.trim('/').split('/').forEach { builder.addPathSegment(it) }
        query.forEach { (name, value) -> if (value != null) builder.addQueryParameter(name, value) }
        return builder.build()
    }

    /** A request to [url] with the cluster's token; [accept] is left out where the API refuses one. */
    private fun request(url: HttpUrl, accept: String? = "application/json"): Request.Builder = Request.Builder().url(url).apply {
        if (accept != null) header("Accept", accept)
        if (cluster.token.isNotBlank()) header("Authorization", "Bearer ${cluster.token}")
    }

    /** Runs [request] off the main thread; the API's own message when it refuses. */
    private suspend fun call(request: Request, http: OkHttpClient = client): String = withContext(Dispatchers.IO) {
        http.newCall(request).execute().use { response ->
            val body = response.body?.string().orEmpty()
            if (!response.isSuccessful) throw IOException(statusMessage(response, body))
            body
        }
    }

    private suspend fun get(path: String, query: Map<String, String?> = emptyMap()): Any? =
        json.fromJson(call(request(url(path, query)).build()))

    /** Every object of a list, a page of [PAGE_SIZE] at a time. */
    private suspend fun items(path: String, query: Map<String, String?> = emptyMap()): List<Any?> {
        val all = mutableListOf<Any?>()
        var next: String? = null
        do {
            val page = get(path, query + mapOf("limit" to PAGE_SIZE.toString(), "continue" to next))
            all.addAll(page.list("items"))
            next = page.text("metadata", "continue").ifEmpty { null }
        } while (next != null)
        return all
    }

    private fun scoped(group: String, resource: String, namespace: String) =
        if (namespace.isBlank()) "$group/$resource" else "$group/namespaces/$namespace/$resource"

    suspend fun namespaces(): List<String> =
        items("api/v1/namespaces").map { it.text("metadata", "name") }.filter(Kube::isValidName).sorted()

    suspend fun pods(namespace: String): List<KubePod> = items(scoped("api/v1", "pods", namespace)).mapNotNull { Kube.podFromRow(podRow(it)) }

    suspend fun deployments(namespace: String): List<KubeDeployment> =
        items(scoped("apis/apps/v1", "deployments", namespace)).mapNotNull { Kube.deploymentFromRow(deploymentRow(it)) }

    suspend fun services(namespace: String): List<KubeService> =
        items(scoped("api/v1", "services", namespace)).mapNotNull { Kube.serviceFromRow(serviceRow(it)) }

    suspend fun nodes(): List<KubeNode> = items("api/v1/nodes").mapNotNull { Kube.nodeFromRow(nodeRow(it)) }

    /**
     * A pod's last 200 log lines, or its [container]'s; every container's, each line prefixed with
     * its name, when it has several and none is named, as `kubectl logs --all-containers --prefix`.
     * [follow] keeps reading until cancelled.
     */
    suspend fun logs(pod: KubePod, follow: Boolean, previous: Boolean, emit: suspend (String) -> Unit) {
        val containers = if (pod.containers.size > 1) pod.containers else listOf(null)
        coroutineScope {
            containers.forEach { container ->
                val prefix = if (container != null) "[pod/${pod.name}/$container] " else ""
                val read = suspend {
                    streamLines(
                        url(
                            "api/v1/namespaces/${pod.namespace}/pods/${pod.name}/log",
                            mapOf(
                                "tailLines" to "200",
                                "container" to container,
                                "follow" to if (follow) "true" else null,
                                "previous" to if (previous) "true" else null,
                            ),
                        ),
                    ) { emit(prefix + it + "\n") }
                }
                // Following, every container streams at once; otherwise one after another, in order.
                if (follow) launch { read() } else read()
            }
        }
    }

    /** The logs of one running pod of [deployment], as `kubectl logs deployment/…` picks it. */
    suspend fun deploymentLogs(deployment: KubeDeployment, emit: suspend (String) -> Unit) {
        val spec = get("apis/apps/v1/namespaces/${deployment.namespace}/deployments/${deployment.name}")
        val selector = (spec.at("spec", "selector", "matchLabels") as? Map<*, *>).orEmpty()
            .entries.joinToString(",") { "${it.key}=${it.value}" }
        val pods = items(scoped("api/v1", "pods", deployment.namespace), mapOf("labelSelector" to selector))
            .mapNotNull { Kube.podFromRow(podRow(it)) }
        val pod = pods.firstOrNull { it.status == "Running" } ?: pods.firstOrNull()
            ?: throw IOException("${deployment.name} has no pods.")
        logs(pod, follow = false, previous = false, emit = emit)
    }

    private suspend fun streamLines(url: HttpUrl, onLine: suspend (String) -> Unit) {
        val streaming = client.newBuilder().readTimeout(0, TimeUnit.MILLISECONDS).build()
        // As kubectl asks: the log endpoint answers in plain text but refuses a plain-text Accept.
        val call = streaming.newCall(request(url, accept = "application/json, */*").build())
        coroutineScope {
            // A blocking read ignores cancellation; cancelling the call ends it.
            val canceller = launch { try { awaitCancellation() } finally { call.cancel() } }
            try {
                withContext(Dispatchers.IO) {
                    call.execute().use { response ->
                        if (!response.isSuccessful) throw IOException(statusMessage(response, response.body?.string().orEmpty()))
                        val source = response.body!!.source()
                        while (true) {
                            val line = source.readUtf8Line() ?: break
                            onLine(line)
                        }
                    }
                }
            } finally {
                canceller.cancel()
            }
        }
    }

    /**
     * What `kubectl describe` is for: the object as the API holds it, without the field-ownership
     * bookkeeping, then its events. The phone has no kubectl to write kubectl's summary.
     */
    suspend fun describe(kind: String, namespace: String?, name: String): String {
        val (group, resource) = KINDS[kind] ?: throw IllegalArgumentException("Cannot describe a $kind.")
        val path = if (namespace == null) "$group/$resource/$name" else "$group/namespaces/$namespace/$resource/$name"
        val obj = get(path)
        @Suppress("UNCHECKED_CAST")
        (obj.at("metadata") as? MutableMap<String, Any?>)?.remove("managedFields")
        val events = items(
            scoped("api/v1", "events", namespace.orEmpty()),
            mapOf("fieldSelector" to "involvedObject.name=$name,involvedObject.kind=${kind.replaceFirstChar(Char::uppercase)}"),
        )
        return pretty.toJson(obj) + "\n\nEvents:\n" + formatEvents(events, withNamespace = false).ifBlank { "  <none>" }
    }

    /** Recent events in [namespace] (blank: every namespace), oldest first, as `kubectl get events` lists them. */
    suspend fun events(namespace: String): String =
        formatEvents(items(scoped("api/v1", "events", namespace)), withNamespace = namespace.isBlank()).ifBlank { "No events." }

    suspend fun deletePod(pod: KubePod): String {
        call(request(url("api/v1/namespaces/${pod.namespace}/pods/${pod.name}")).delete().build())
        return "pod \"${pod.name}\" deleted\n"
    }

    suspend fun scale(deployment: KubeDeployment, replicas: Int): String {
        require(replicas in 0..Kube.MAX_REPLICAS) { "Replicas must be 0 to ${Kube.MAX_REPLICAS}" }
        patch("apis/apps/v1/namespaces/${deployment.namespace}/deployments/${deployment.name}/scale", "{\"spec\":{\"replicas\":$replicas}}")
        return "deployment.apps/${deployment.name} scaled\n"
    }

    /** What `kubectl rollout restart` does: a new pod template annotation, so every pod is replaced. */
    suspend fun restart(deployment: KubeDeployment): String {
        val now = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US).apply { timeZone = TimeZone.getTimeZone("UTC") }.format(Date())
        patch(
            "apis/apps/v1/namespaces/${deployment.namespace}/deployments/${deployment.name}",
            "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"kubectl.kubernetes.io/restartedAt\":\"$now\"}}}}}",
        )
        return "deployment.apps/${deployment.name} restarted\n"
    }

    suspend fun cordon(node: KubeNode, cordon: Boolean): String {
        patch("api/v1/nodes/${node.name}", "{\"spec\":{\"unschedulable\":$cordon}}")
        return "node/${node.name} ${if (cordon) "cordoned" else "uncordoned"}\n"
    }

    private suspend fun patch(path: String, body: String) {
        call(request(url(path)).patch(body.toRequestBody(MERGE_PATCH)).build())
    }

    /** A shell in [pod] ([container], or its default one): bash where it has it, sh otherwise. */
    suspend fun exec(pod: KubePod, container: String?, cols: Int, rows: Int): KubeExecSession {
        val http = url(
            "api/v1/namespaces/${pod.namespace}/pods/${pod.name}/exec",
            mapOf("container" to container, "stdin" to "true", "stdout" to "true", "stderr" to "true", "tty" to "true"),
        ).newBuilder().apply {
            listOf("sh", "-c", RemoteCommands.CONTAINER_SHELL_SCRIPT).forEach { addQueryParameter("command", it) }
        }.build()
        val socketUrl = http.toString().replaceFirst("https://", "wss://")
        // An Accept header makes the API refuse the upgrade (406).
        val request = request(base, accept = null).url(socketUrl).header("Sec-WebSocket-Protocol", "v4.channel.k8s.io").build()
        return KubeExecSession.open(client, request, cols, rows)
    }

    private fun formatEvents(events: List<Any?>, withNamespace: Boolean): String {
        val now = System.currentTimeMillis()
        val rows = events.map { event ->
            val time = Kube.parseTime(event.text("lastTimestamp"))
                ?: Kube.parseTime(event.text("eventTime"))
                ?: Kube.parseTime(event.text("metadata", "creationTimestamp"))
            val obj = event.text("involvedObject", "kind").lowercase() + "/" + event.text("involvedObject", "name")
            time to listOfNotNull(
                if (withNamespace) event.text("metadata", "namespace") else null,
                Kube.age(time, now),
                event.text("type"),
                event.text("reason"),
                obj,
                event.text("message").replace('\n', ' '),
            )
        }.sortedBy { it.first ?: 0L }.map { it.second }
        if (rows.isEmpty()) return ""
        val header = listOfNotNull(if (withNamespace) "NAMESPACE" else null, "AGE", "TYPE", "REASON", "OBJECT", "MESSAGE")
        val table = listOf(header) + rows
        val widths = header.indices.map { column -> table.maxOf { it[column].length } }
        return table.joinToString("\n") { row ->
            row.mapIndexed { i, cell -> if (i == row.lastIndex) cell else cell.padEnd(widths[i]) }.joinToString("   ")
        } + "\n"
    }

    companion object {
        private const val PAGE_SIZE = 500
        private const val KEY_STORE_PASSWORD = "omniterm"
        private val MERGE_PATCH = "application/merge-patch+json".toMediaType()
        private val moshi = Moshi.Builder().build()
        private val json = moshi.adapter(Any::class.java)
        private val pretty = json.indent("  ")

        private val KINDS = mapOf(
            "pod" to ("api/v1" to "pods"),
            "service" to ("api/v1" to "services"),
            "node" to ("api/v1" to "nodes"),
            "deployment" to ("apis/apps/v1" to "deployments"),
        )

        /** The API's reason for refusing, from the Status object it sends, or the HTTP status. */
        internal fun statusMessage(response: Response, body: String): String {
            val message = runCatching { json.fromJson(body).text("message") }.getOrNull().orEmpty()
            return message.ifBlank { "The cluster answered HTTP ${response.code}" }
        }

        internal fun Any?.at(vararg path: String): Any? = path.fold(this) { node, key -> (node as? Map<*, *>)?.get(key) }

        /** The value at [path] as kubectl's jsonpath prints it: whole numbers without ".0", missing as "". */
        internal fun Any?.text(vararg path: String): String = when (val value = at(*path)) {
            null -> ""
            is Double -> if (value % 1.0 == 0.0) value.toLong().toString() else value.toString()
            else -> value.toString()
        }

        internal fun Any?.list(vararg path: String): List<Any?> = at(*path) as? List<*> ?: emptyList()

        private fun List<Any?>.words(vararg path: String) = map { it.text(*path) }.filter { it.isNotEmpty() }.joinToString(" ")

        /** The row Kube's pod jsonpath prints, from one pod's JSON. */
        internal fun podRow(pod: Any?): List<String> {
            val statuses = pod.list("status", "containerStatuses")
            return listOf(
                pod.text("metadata", "namespace"), pod.text("metadata", "name"), pod.text("status", "phase"),
                pod.text("status", "reason"), pod.text("metadata", "deletionTimestamp"), pod.text("spec", "nodeName"),
                pod.text("status", "podIP"), pod.text("status", "startTime"), pod.text("metadata", "creationTimestamp"),
                pod.list("spec", "containers").words("name"), statuses.words("ready"), statuses.words("restartCount"),
                statuses.words("state", "waiting", "reason"), statuses.words("state", "terminated", "reason"),
                pod.list("status", "initContainerStatuses").words("state", "waiting", "reason"),
            )
        }

        internal fun deploymentRow(deployment: Any?): List<String> = listOf(
            deployment.text("metadata", "namespace"), deployment.text("metadata", "name"), deployment.text("spec", "replicas"),
            deployment.text("status", "readyReplicas"), deployment.text("status", "updatedReplicas"),
            deployment.text("status", "availableReplicas"), deployment.text("metadata", "creationTimestamp"),
            deployment.list("spec", "template", "spec", "containers").words("image"),
        )

        internal fun serviceRow(service: Any?): List<String> {
            val ingress = service.list("status", "loadBalancer", "ingress")
            return listOf(
                service.text("metadata", "namespace"), service.text("metadata", "name"), service.text("spec", "type"),
                service.text("spec", "clusterIP"),
                service.list("spec", "ports").joinToString("") { "${it.text("port")}:${it.text("nodePort")}/${it.text("protocol")}," },
                ingress.words("ip"), ingress.words("hostname"),
                service.list("spec", "externalIPs").joinToString(" ") { it?.toString().orEmpty() }.trim(),
                service.text("spec", "externalName"), service.text("metadata", "creationTimestamp"),
            )
        }

        internal fun nodeRow(node: Any?): List<String> {
            val labels = (node.at("metadata", "labels") as? Map<*, *>).orEmpty()
            return listOf(
                node.text("metadata", "name"),
                node.list("status", "conditions").firstOrNull { it.text("type") == "Ready" }.text("status"),
                node.text("spec", "unschedulable"),
                node.text("status", "nodeInfo", "kubeletVersion"),
                node.list("status", "addresses").filter { it.text("type") == "InternalIP" }.words("address"),
                node.text("status", "nodeInfo", "osImage"), node.text("status", "allocatable", "cpu"),
                node.text("status", "allocatable", "memory"), node.text("metadata", "creationTimestamp"),
                labels.entries.joinToString(",", "{", "}") { "\"${it.key}\":\"${it.value}\"" },
            )
        }
    }
}

/**
 * A shell in a pod over the API's exec WebSocket. Each message starts with its channel: 0 is what
 * is typed, 1 and 2 what the shell prints, 3 how it ended, 4 the window size.
 */
class KubeExecSession private constructor() : ByteStreamTerminalSession("kube-exec-reader") {
    private val incoming = LinkedBlockingQueue<ByteArray>()
    private var pending: ByteArray? = null
    private var pendingOffset = 0
    @Volatile private var socket: WebSocket? = null
    @Volatile private var failure: String? = null
    @Volatile private var exitMessage: String? = null

    override val endOfStreamReason: String get() = exitMessage ?: "The shell in the pod ended"

    override fun readSome(buffer: ByteArray): Int {
        val chunk = pending ?: incoming.poll(200, TimeUnit.MILLISECONDS) ?: return 0
        if (chunk === END) {
            failure?.let { throw IOException(it) }
            return -1
        }
        val count = minOf(buffer.size, chunk.size - pendingOffset)
        System.arraycopy(chunk, pendingOffset, buffer, 0, count)
        pendingOffset += count
        if (pendingOffset >= chunk.size) {
            pending = null
            pendingOffset = 0
        } else {
            pending = chunk
        }
        return count
    }

    override fun writeRaw(bytes: ByteArray) = send(CHANNEL_STDIN, bytes)

    private fun send(channel: Int, bytes: ByteArray) {
        val frame = ByteArray(bytes.size + 1)
        frame[0] = channel.toByte()
        System.arraycopy(bytes, 0, frame, 1, bytes.size)
        if (socket?.send(frame.toByteString()) != true) throw IOException("The connection to the pod closed")
    }

    override fun closeTransport() {
        socket?.close(1000, null)
        incoming.offer(END)
    }

    override suspend fun resize(cols: Int, rows: Int) {
        if (closed.value) return
        withContext(Dispatchers.IO) { runCatching { send(CHANNEL_RESIZE, "{\"Width\":$cols,\"Height\":$rows}".toByteArray()) } }
    }

    private val listener = object : WebSocketListener() {
        override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
            if (bytes.size == 0) return
            val data = bytes.substring(1).toByteArray()
            when (bytes[0].toInt()) {
                CHANNEL_STDOUT, CHANNEL_STDERR -> if (data.isNotEmpty()) incoming.offer(data)
                CHANNEL_STATUS -> exitMessage = exitReason(String(data, Charsets.UTF_8))
            }
        }

        override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
            webSocket.close(1000, null)
            incoming.offer(END)
        }

        override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
            incoming.offer(END)
        }

        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
            failure = t.message ?: t.javaClass.simpleName
            incoming.offer(END)
        }
    }

    companion object {
        private const val CHANNEL_STDIN = 0
        private const val CHANNEL_STDOUT = 1
        private const val CHANNEL_STDERR = 2
        private const val CHANNEL_STATUS = 3
        private const val CHANNEL_RESIZE = 4
        private const val OPEN_TIMEOUT_MS = 15_000L
        private val END = ByteArray(0)
        private val STATUS = Moshi.Builder().build().adapter(Any::class.java)

        /**
         * How the shell ended, from the Status the API sends last: null when it exited cleanly, its
         * exit status when it did not (the API's own message repeats the whole command), else the
         * API's message.
         */
        internal fun exitReason(statusJson: String): String? {
            val status = runCatching { STATUS.fromJson(statusJson) }.getOrNull()
            if (status.text("status") != "Failure") return null
            val code = status.list("details", "causes").firstOrNull { it.text("reason") == "ExitCode" }.text("message")
            return if (status.text("reason") == "NonZeroExitCode" && code.isNotEmpty()) {
                "The shell in the pod exited with status $code"
            } else {
                status.text("message").ifEmpty { null }
            }
        }

        /** Opens the socket; throws with the API's reason when it refuses (no such pod, not allowed). */
        suspend fun open(client: OkHttpClient, request: Request, cols: Int, rows: Int): KubeExecSession {
            val session = KubeExecSession()
            val opened = CompletableDeferred<Unit>()
            val socket = client.newWebSocket(
                request,
                object : WebSocketListener() {
                    override fun onOpen(webSocket: WebSocket, response: Response) {
                        opened.complete(Unit)
                    }

                    override fun onMessage(webSocket: WebSocket, bytes: ByteString) = session.listener.onMessage(webSocket, bytes)

                    override fun onClosing(webSocket: WebSocket, code: Int, reason: String) = session.listener.onClosing(webSocket, code, reason)

                    override fun onClosed(webSocket: WebSocket, code: Int, reason: String) = session.listener.onClosed(webSocket, code, reason)

                    override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                        val refusal = response?.let { KubeApi.statusMessage(it, runCatching { it.body?.string() }.getOrNull().orEmpty()) }
                        if (!opened.isCompleted) opened.completeExceptionally(IOException(refusal ?: t.message ?: "Could not open a shell in the pod"))
                        session.listener.onFailure(webSocket, t, response)
                    }
                },
            )
            session.socket = socket
            try {
                withTimeout(OPEN_TIMEOUT_MS) { opened.await() }
            } catch (e: Exception) {
                socket.cancel()
                throw e
            }
            session.start()
            session.resize(cols, rows)
            return session
        }
    }
}
