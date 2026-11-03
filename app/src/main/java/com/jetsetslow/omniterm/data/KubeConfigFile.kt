package com.jetsetslow.omniterm.data

import com.squareup.moshi.Moshi
import org.bouncycastle.util.encoders.Base64

/**
 * One context of a kubeconfig, with what OmniTerm needs to reach its cluster from the phone.
 * [unsupported] says why it cannot, when it cannot; the other fields are then incomplete.
 */
data class KubeContextConfig(
    val name: String,
    val server: String,
    /** PEM certificates the API server's certificate must chain to; null trusts the phone's usual CAs. */
    val caPem: String?,
    val clientCertPem: String?,
    val clientKeyPem: String?,
    val token: String?,
    val namespace: String?,
    val unsupported: String?,
)

/**
 * Reads a kubeconfig: the YAML kubectl writes (block maps and lists, plain and quoted scalars,
 * comments, `{}`/`[]`, literal blocks) or the same document as JSON.
 */
object KubeConfigFile {
    class Invalid(message: String) : IllegalArgumentException(message)

    /** Every context in [text], in file order. Throws [Invalid] when [text] is no kubeconfig. */
    fun parse(text: String): List<KubeContextConfig> {
        val root = (if (text.trimStart().startsWith("{")) parseJson(text) else Yaml(text).document()) as? Map<*, *>
            ?: throw Invalid("This file is not a kubeconfig.")
        val clusters = named(root["clusters"], "cluster")
        val users = named(root["users"], "user")
        val contexts = named(root["contexts"], "context")
        if (contexts.isEmpty()) throw Invalid("This kubeconfig has no contexts.")
        return contexts.map { (name, context) -> resolve(name, context, clusters, users) }
    }

    private fun parseJson(text: String): Any? = try {
        Moshi.Builder().build().adapter(Any::class.java).fromJson(text)
    } catch (e: Exception) {
        throw Invalid("This file is not valid JSON: ${e.message}")
    }

    /** A kubeconfig list (`- name: x` with its [field] map) as name to map. */
    private fun named(list: Any?, field: String): List<Pair<String, Map<*, *>>> =
        (list as? List<*>).orEmpty().mapNotNull { entry ->
            val map = entry as? Map<*, *> ?: return@mapNotNull null
            val name = map["name"]?.toString() ?: return@mapNotNull null
            name to (map[field] as? Map<*, *> ?: emptyMap<String, Any?>())
        }

    private fun resolve(
        name: String,
        context: Map<*, *>,
        clusters: List<Pair<String, Map<*, *>>>,
        users: List<Pair<String, Map<*, *>>>,
    ): KubeContextConfig {
        val clusterName = context["cluster"]?.toString()
        val userName = context["user"]?.toString()
        val cluster = clusters.firstOrNull { it.first == clusterName }?.second
        val user = userName?.let { u -> users.firstOrNull { it.first == u }?.second } ?: emptyMap<String, Any?>()
        fun text(map: Map<*, *>?, key: String) = map?.get(key)?.toString()?.takeIf { it.isNotBlank() }
        val server = text(cluster, "server").orEmpty()
        val problems = mutableListOf<String>()
        fun pem(map: Map<*, *>?, dataKey: String, fileKey: String): String? {
            text(map, dataKey)?.let { data ->
                return runCatching { String(Base64.decode(data.filterNot(Char::isWhitespace)), Charsets.UTF_8) }
                    .getOrElse { problems += "its $dataKey is not valid base64"; null }
            }
            if (text(map, fileKey) != null) problems += FILE_REFERENCE
            return null
        }
        if (cluster == null) problems += "it names a cluster the file does not define"
        val caPem = pem(cluster, "certificate-authority-data", "certificate-authority")
        val clientCertPem = pem(user, "client-certificate-data", "client-certificate")
        val clientKeyPem = pem(user, "client-key-data", "client-key")
        val token = text(user, "token")
        when {
            cluster == null -> Unit
            !server.startsWith("https://") -> problems += "OmniTerm reaches clusters over HTTPS only"
            cluster["insecure-skip-tls-verify"]?.toString() == "true" ->
                problems += "it skips checking the cluster's certificate, which OmniTerm never does. Add the cluster's CA as certificate-authority-data instead"
        }
        if (token == null && clientCertPem == null) {
            when {
                user["exec"] != null || user["auth-provider"] != null ->
                    problems += "it gets its credentials from a program (such as aws or gke-gcloud-auth-plugin) that cannot run on a phone. Create a service account token for OmniTerm instead"
                text(user, "tokenFile") != null -> problems += FILE_REFERENCE
                text(user, "username") != null -> problems += "Kubernetes no longer accepts a user name and password"
            }
        }
        if ((clientCertPem == null) != (clientKeyPem == null) && FILE_REFERENCE !in problems) {
            problems += "it has a client certificate without its key, or a key without its certificate"
        }
        return KubeContextConfig(
            name = name,
            server = server,
            caPem = caPem,
            clientCertPem = clientCertPem,
            clientKeyPem = clientKeyPem,
            token = token,
            namespace = text(context, "namespace"),
            unsupported = problems.distinct().takeIf { it.isNotEmpty() }?.joinToString("; ", prefix = "OmniTerm cannot use this context: ", postfix = "."),
        )
    }

    private const val FILE_REFERENCE =
        "it points at files on another computer. Export it with `kubectl config view --raw --flatten` and import that"

    /** The YAML kubeconfigs use; anchors, tags and multi-document streams are not among it. */
    private class Yaml(text: String) {
        private class Line(val indent: Int, val text: String, val number: Int)

        private val lines: MutableList<Line> = text.lines().mapIndexedNotNull { i, raw ->
            if ('\t' in raw.takeWhile { it == ' ' || it == '\t' }) throw Invalid("Line ${i + 1} is indented with a tab.")
            val trimmed = raw.trimEnd()
            val body = trimmed.trimStart()
            when {
                body.isEmpty() || body.startsWith("#") || body == "---" || body == "..." -> null
                else -> Line(trimmed.length - body.length, raw.trimEnd(), i + 1)
            }
        }.toMutableList()
        private var at = 0

        fun document(): Any? = if (lines.isEmpty()) null else node(lines[0].indent).also {
            if (at < lines.size) throw Invalid("Line ${lines[at].number} is not where the file's indentation expects it.")
        }

        private fun peek(): Line? = lines.getOrNull(at)

        private fun isItem(line: Line) = line.body() == "-" || line.body().startsWith("- ")

        private fun Line.body() = text.substring(indent)

        private fun node(indent: Int): Any? {
            val line = peek() ?: return null
            return if (isItem(line)) sequence(line.indent) else map(line.indent)
        }

        private fun sequence(indent: Int): List<Any?> {
            val items = mutableListOf<Any?>()
            while (true) {
                val line = peek() ?: break
                if (line.indent != indent || !isItem(line)) break
                val rest = line.body().removePrefix("-")
                val content = rest.trimStart()
                if (content.isEmpty()) {
                    at++
                    items += peek()?.takeIf { it.indent > indent }?.let { node(it.indent) }
                } else if (keyOf(content) != null) {
                    // "- key: value" opens a map whose keys line up with "key".
                    val column = indent + 1 + (rest.length - content.length)
                    lines[at] = Line(column, " ".repeat(column) + content, line.number)
                    items += map(column)
                } else {
                    at++
                    items += scalar(content, indent)
                }
            }
            return items
        }

        private fun map(indent: Int): Map<String, Any?> {
            val map = LinkedHashMap<String, Any?>()
            while (true) {
                val line = peek() ?: break
                if (line.indent != indent || isItem(line)) break
                val body = line.body()
                val key = keyOf(body) ?: throw Invalid("Line ${line.number} is neither a key nor a list item.")
                val rest = body.substring(key.second).trim()
                at++
                map[key.first] = if (rest.isEmpty() || rest.startsWith("#")) {
                    val next = peek()
                    when {
                        next == null -> null
                        next.indent > indent -> node(next.indent)
                        // A list may sit at its key's own indentation, as kubectl writes it.
                        next.indent == indent && isItem(next) -> sequence(indent)
                        else -> null
                    }
                } else {
                    scalar(rest, indent)
                }
            }
            return map
        }

        /** The key at the start of [body] and where its value starts, or null when [body] has none. */
        private fun keyOf(body: String): Pair<String, Int>? {
            if (body.startsWith("\"") || body.startsWith("'")) {
                val quote = body[0]
                val end = body.indexOf(quote, 1)
                if (end < 0 || body.getOrNull(end + 1) != ':') return null
                return body.substring(1, end) to end + 2
            }
            var i = body.indexOf(':')
            while (i >= 0) {
                if (i == body.length - 1 || body[i + 1] == ' ') return body.substring(0, i).trim() to i + 1
                i = body.indexOf(':', i + 1)
            }
            return null
        }

        private fun scalar(raw: String, indent: Int): Any? {
            val value = raw.trim()
            return when {
                value == "{}" -> emptyMap<String, Any?>()
                value == "[]" -> emptyList<Any?>()
                value == "|" || value == "|-" || value == ">" || value == ">-" -> block(indent, folded = value[0] == '>', keepNewline = value.length == 1)
                value.startsWith("\"") -> doubleQuoted(value)
                value.startsWith("'") -> value.removeSurrounding("'").replace("''", "'")
                else -> value.substringBefore(" #").takeUnless { it == "null" || it == "~" }
            }
        }

        private fun block(indent: Int, folded: Boolean, keepNewline: Boolean): String {
            val parts = mutableListOf<String>()
            val first = peek()?.takeIf { it.indent > indent } ?: return ""
            while (true) {
                val line = peek() ?: break
                if (line.indent < first.indent) break
                parts += line.text.substring(first.indent)
                at++
            }
            return parts.joinToString(if (folded) " " else "\n") + if (keepNewline) "\n" else ""
        }

        private fun doubleQuoted(value: String): String {
            val out = StringBuilder()
            var i = 1
            while (i < value.length) {
                val c = value[i]
                when {
                    c == '"' -> break
                    c == '\\' && i + 1 < value.length -> {
                        out.append(
                            when (val e = value[i + 1]) {
                                'n' -> '\n'
                                't' -> '\t'
                                'r' -> '\r'
                                '0' -> '\u0000'
                                else -> e
                            },
                        )
                        i++
                    }
                    else -> out.append(c)
                }
                i++
            }
            return out.toString()
        }
    }
}
