package com.jetsetslow.omniterm.data.ssh

internal class CappedTextBuffer(private val maxChars: Int) {
    private val builder = StringBuilder()
    var truncated: Boolean = false
        private set

    fun append(value: String) {
        if (value.isEmpty()) return
        builder.append(value)
        if (builder.length > maxChars) {
            builder.delete(0, builder.length - maxChars)
            truncated = true
        }
    }

    fun text(): String {
        val value = builder.toString()
        return if (truncated) "[Output truncated; showing latest $maxChars characters]\n$value" else value
    }

    fun isBlank(): Boolean = builder.isBlank()
}
