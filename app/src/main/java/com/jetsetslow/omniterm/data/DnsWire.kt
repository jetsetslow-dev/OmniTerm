package com.jetsetslow.omniterm.data

/**
 * A standard DNS query for [target]'s records of [type], recursion desired, with query [id].
 * Callers pick a random id, so a reply to someone else's query cannot be taken for theirs.
 */
internal fun serializeDnsQuery(target: String, type: Int, id: Int): ByteArray {
    val baos = java.io.ByteArrayOutputStream()
    val dos = java.io.DataOutputStream(baos)
    dos.writeShort(id)
    dos.writeShort(0x0100)
    dos.writeShort(1)
    dos.writeShort(0)
    dos.writeShort(0)
    dos.writeShort(0)
    for (part in target.trim().trimEnd('.').split(".")) {
        require(part.length <= 63) { "DNS label too long" }
        dos.writeByte(part.length)
        dos.write(part.toByteArray(Charsets.US_ASCII))
    }
    dos.writeByte(0)
    dos.writeShort(type)
    dos.writeShort(1)
    return baos.toByteArray()
}
