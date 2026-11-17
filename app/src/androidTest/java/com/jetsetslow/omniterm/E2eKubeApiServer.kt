package com.jetsetslow.omniterm

import org.bouncycastle.asn1.ASN1Integer
import org.bouncycastle.asn1.DERBitString
import org.bouncycastle.asn1.DEROctetString
import org.bouncycastle.asn1.DERSequence
import org.bouncycastle.asn1.x500.X500Name
import org.bouncycastle.asn1.x509.AlgorithmIdentifier
import org.bouncycastle.asn1.x509.BasicConstraints
import org.bouncycastle.asn1.x509.Extension
import org.bouncycastle.asn1.x509.Extensions
import org.bouncycastle.asn1.x509.GeneralName
import org.bouncycastle.asn1.x509.GeneralNames
import org.bouncycastle.asn1.x509.SubjectPublicKeyInfo
import org.bouncycastle.asn1.x509.Time
import org.bouncycastle.asn1.x509.V3TBSCertificateGenerator
import org.bouncycastle.asn1.x9.X9ObjectIdentifiers
import org.bouncycastle.util.encoders.Base64
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.Signature
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.security.spec.ECGenParameterSpec
import java.util.Collections
import java.util.Date
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.SSLContext
import kotlin.concurrent.thread

/**
 * Answers on the phone's own loopback as a Kubernetes API server answers the lists the Kubernetes
 * tab reads: list objects of [items] by resource ("pods", "deployments", "services", "nodes",
 * "namespaces"), across namespaces or in one, [pageSize] at a time with a `continue` token. Over
 * HTTPS with a certificate it makes for itself, which its kubeconfig names as the cluster's CA, and
 * only for its bearer token: anything else gets the API's 401 Status. Nothing leaves the phone.
 */
internal class E2eKubeApiServer(
    private val token: String,
    private val items: Map<String, List<Item>>,
    private val pageSize: Int,
) : AutoCloseable {
    /** One object as the API returns it, with the namespace it lives in ("" for nodes, namespaces). */
    class Item(val namespace: String, val json: String)

    /** Each request's path and query, as the server saw them. */
    val requests: MutableList<String> = Collections.synchronizedList(mutableListOf<String>())

    private val certificate: X509Certificate
    private val server: ServerSocket

    init {
        val keys = KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec("secp256r1")) }.generateKeyPair()
        val name = X500Name("CN=omniterm-e2e-kube")
        val now = System.currentTimeMillis()
        val signedWith = AlgorithmIdentifier(X9ObjectIdentifiers.ecdsa_with_SHA256)
        val tbs = V3TBSCertificateGenerator().apply {
            setSerialNumber(ASN1Integer(now))
            setIssuer(name)
            setSubject(name)
            setStartDate(Time(Date(now - 3_600_000)))
            setEndDate(Time(Date(now + 86_400_000)))
            setSubjectPublicKeyInfo(SubjectPublicKeyInfo.getInstance(keys.public.encoded))
            setSignature(signedWith)
            setExtensions(
                Extensions(
                    arrayOf(
                        Extension(Extension.basicConstraints, true, DEROctetString(BasicConstraints(true))),
                        Extension(Extension.subjectAlternativeName, false, DEROctetString(GeneralNames(GeneralName(GeneralName.iPAddress, HOST)))),
                    ),
                ),
            )
        }.generateTBSCertificate()
        val signature = Signature.getInstance("SHA256withECDSA").run {
            initSign(keys.private)
            update(tbs.encoded)
            sign()
        }
        val der = DERSequence(arrayOf(tbs, signedWith, DERBitString(signature))).encoded
        certificate = CertificateFactory.getInstance("X.509").generateCertificate(der.inputStream()) as X509Certificate
        val password = "e2e".toCharArray()
        val store = KeyStore.getInstance(KeyStore.getDefaultType()).apply {
            load(null, null)
            setKeyEntry("server", keys.private, password, arrayOf(certificate))
        }
        val managers = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm()).apply { init(store, password) }.keyManagers
        val tls = SSLContext.getInstance("TLS").apply { init(managers, null, null) }
        server = tls.serverSocketFactory.createServerSocket(0, 16, InetAddress.getByName(HOST))
        thread(isDaemon = true, name = "e2e-kube-api") {
            while (!server.isClosed) {
                val socket = runCatching { server.accept() }.getOrNull() ?: break
                thread(isDaemon = true) { socket.use(::answer) }
            }
        }
    }

    /** The cluster's address, as its kubeconfig names it. */
    val address: String get() = "https://$HOST:${server.localPort}"

    /** A kubeconfig for this server with one context, [context], reading as [token]. */
    fun kubeconfig(context: String): String {
        val pem = "-----BEGIN CERTIFICATE-----\n" + Base64.toBase64String(certificate.encoded).chunked(64).joinToString("\n") +
            "\n-----END CERTIFICATE-----\n"
        return """
            apiVersion: v1
            kind: Config
            clusters:
            - name: e2e
              cluster:
                server: $address
                certificate-authority-data: ${Base64.toBase64String(pem.toByteArray())}
            contexts:
            - name: $context
              context:
                cluster: e2e
                user: e2e-viewer
            current-context: $context
            users:
            - name: e2e-viewer
              user:
                token: $token
        """.trimIndent()
    }

    private fun answer(socket: Socket) {
        socket.soTimeout = 10_000
        val reader = BufferedReader(InputStreamReader(socket.getInputStream(), Charsets.ISO_8859_1))
        val target = reader.readLine()?.split(' ')?.getOrNull(1) ?: return
        val headers = generateSequence { reader.readLine()?.takeIf { it.isNotEmpty() } }
            .associate { it.substringBefore(':').trim().lowercase() to it.substringAfter(':').trim() }
        requests += target
        val (code, body) = when {
            headers["authorization"] != "Bearer $token" -> 401 to status(401, "Unauthorized", "Unauthorized")
            else -> list(target) ?: (404 to status(404, "NotFound", "the server could not find the requested resource"))
        }
        val bytes = body.toByteArray()
        val head = "HTTP/1.1 $code ${if (code == 200) "OK" else "Error"}\r\nContent-Type: application/json\r\n" +
            "Content-Length: ${bytes.size}\r\nConnection: close\r\n\r\n"
        socket.getOutputStream().run {
            write(head.toByteArray(Charsets.ISO_8859_1))
            write(bytes)
            flush()
        }
    }

    /** `/api/v1/<resource>`, `/apis/apps/v1/<resource>` or either `.../namespaces/<ns>/<resource>`. */
    private fun list(target: String): Pair<Int, String>? {
        val path = target.substringBefore('?').trim('/').split('/')
        val query = target.substringAfter('?', "").split('&').filter { '=' in it }.associate { it.substringBefore('=') to it.substringAfter('=') }
        val rest = path.drop(if (path.firstOrNull() == "api") 2 else 3)
        val (namespace, resource) = when {
            rest.size == 1 -> null to rest[0]
            rest.size == 3 && rest[0] == "namespaces" -> rest[1] to rest[2]
            else -> return null
        }
        val all = items[resource] ?: return null
        val matching = if (namespace == null) all else all.filter { it.namespace == namespace }
        val start = query["continue"]?.removePrefix("page-")?.toIntOrNull() ?: 0
        val limit = query["limit"]?.toIntOrNull()?.coerceAtMost(pageSize) ?: pageSize
        val page = matching.drop(start).take(limit)
        val next = (start + limit).takeIf { it < matching.size }?.let { ",\"continue\":\"page-$it\"" }.orEmpty()
        val kind = resource.replaceFirstChar(Char::uppercase).removeSuffix("s") + "List"
        return 200 to "{\"kind\":\"$kind\",\"apiVersion\":\"v1\",\"metadata\":{\"resourceVersion\":\"4711\"$next}," +
            "\"items\":[${page.joinToString(",") { it.json }}]}"
    }

    private fun status(code: Int, reason: String, message: String) =
        "{\"kind\":\"Status\",\"apiVersion\":\"v1\",\"metadata\":{},\"status\":\"Failure\",\"message\":\"$message\",\"reason\":\"$reason\",\"code\":$code}"

    override fun close() = server.close()

    private companion object { const val HOST = "127.0.0.1" }
}
