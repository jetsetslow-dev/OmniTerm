package com.jetsetslow.omniterm.data

/**
 * The name a file from the device takes on the host. The name comes from whichever app provides
 * the file (a picker, or any app that shares one), so only its last part is kept: never a `/` or
 * `\` that would put it in another folder (a Windows host reads `\` as one), never `.` or `..`,
 * and no control characters.
 */
object UploadName {
    fun from(reported: String?): String? {
        val name = reported?.substringAfterLast('/')?.substringAfterLast('\\')?.filterNot { it.isISOControl() } ?: return null
        return name.takeUnless { it.isBlank() || it == "." || it == ".." }
    }
}
