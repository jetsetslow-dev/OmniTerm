package com.jetsetslow.omniterm.data

// Reading a JSON answer already parsed into plain maps, lists, strings and numbers (as Moshi's
// `Any` adapter gives it), shared by the Kubernetes and Proxmox clients. Plain Kotlin, so a client
// whose HTTP library is swapped keeps reading its answers the same way.

/** The value at [path], one object key per step; null where a step is missing. */
internal fun Any?.at(vararg path: String): Any? = path.fold(this) { node, key -> (node as? Map<*, *>)?.get(key) }

/** The value at [path] as kubectl's jsonpath prints it: whole numbers without ".0", missing as "". */
internal fun Any?.text(vararg path: String): String = when (val value = at(*path)) {
    null -> ""
    is Double -> if (value % 1.0 == 0.0) value.toLong().toString() else value.toString()
    else -> value.toString()
}

/** The list at [path], or an empty one. */
internal fun Any?.list(vararg path: String): List<Any?> = at(*path) as? List<*> ?: emptyList()
