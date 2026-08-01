package com.jetsetslow.omniterm.shared.feature

/**
 * Serializes a widget snapshot for the shared container an extension reads (iOS App Group, Android
 * widget storage).
 *
 * A hand-rolled line format rather than a serialization dependency: the payload is four scalars and
 * a list of five-field rows, it must be readable by a widget extension with the smallest possible
 * binary, and every field is escaped so a host name containing the delimiter cannot forge a row.
 * Anything that does not parse yields null — a widget must show its error state rather than render
 * half a fleet.
 */
object WidgetSnapshotCodec {
    private const val VERSION = 1
    private const val FIELD = '\u001F'
    private const val ROW = '\u001E'

    fun encode(snapshot: WidgetFleetSnapshot): String {
        val header = listOf(
            VERSION.toString(),
            snapshot.generatedAtEpochMillis.toString(),
            snapshot.online.toString(),
            snapshot.total.toString(),
            if (snapshot.stale) "1" else "0",
        ).joinToString(FIELD.toString())
        val rows = snapshot.lines.joinToString(ROW.toString()) { line ->
            listOf(
                line.hostId.toString(),
                line.name.escape(),
                line.status.setting,
                line.healthScore.toString(),
                line.metrics.escape(),
            ).joinToString(FIELD.toString())
        }
        return if (rows.isEmpty()) header else "$header$ROW$rows"
    }

    fun decode(raw: String?): WidgetFleetSnapshot? {
        if (raw.isNullOrEmpty()) return null
        val blocks = raw.split(ROW)
        val header = blocks.first().split(FIELD)
        if (header.size != 5) return null
        if (header[0].toIntOrNull() != VERSION) return null
        val generatedAt = header[1].toLongOrNull() ?: return null
        val online = header[2].toIntOrNull() ?: return null
        val total = header[3].toIntOrNull() ?: return null
        val stale = when (header[4]) {
            "1" -> true
            "0" -> false
            else -> return null
        }
        val lines = blocks.drop(1).map { block ->
            val fields = block.split(FIELD)
            if (fields.size != 5) return null
            WidgetHostLine(
                hostId = fields[0].toIntOrNull() ?: return null,
                name = fields[1].unescape(),
                status = WidgetHostStatus.fromServerStatus(fields[2]),
                healthScore = fields[3].toIntOrNull() ?: return null,
                metrics = fields[4].unescape(),
            )
        }
        // A count that disagrees with the rows means a truncated write; reject rather than mislead.
        if (lines.size != total) return null
        return WidgetFleetSnapshot(generatedAt, lines, online, total, stale)
    }

    private fun String.escape(): String = replace("\\", "\\\\")
        .replace(FIELD.toString(), "\\u001F")
        .replace(ROW.toString(), "\\u001E")

    private fun String.unescape(): String {
        val out = StringBuilder(length)
        var index = 0
        while (index < length) {
            val char = this[index]
            if (char != '\\') {
                out.append(char)
                index++
                continue
            }
            when {
                startsWith("\\\\", index) -> {
                    out.append('\\'); index += 2
                }
                startsWith("\\u001F", index) -> {
                    out.append(FIELD); index += 6
                }
                startsWith("\\u001E", index) -> {
                    out.append(ROW); index += 6
                }
                else -> {
                    out.append(char); index++
                }
            }
        }
        return out.toString()
    }
}
