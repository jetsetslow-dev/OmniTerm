package com.jetsetslow.omniterm.ui

/** Pure xterm-compatible encoder shared by hardware and on-screen terminal keys. */
object TerminalKeyEncoder {
    fun controlByte(codePoint: Int): Byte? = when {
        codePoint == ' '.code || codePoint == '@'.code || codePoint == '2'.code -> 0x00
        codePoint in 'a'.code..'z'.code -> (codePoint - 'a'.code + 1).toByte()
        codePoint in 'A'.code..'Z'.code -> (codePoint - 'A'.code + 1).toByte()
        codePoint == '['.code -> 0x1B
        codePoint == '\\'.code -> 0x1C
        codePoint == ']'.code -> 0x1D
        codePoint == '^'.code || codePoint == '6'.code -> 0x1E
        codePoint == '_'.code || codePoint == '/'.code -> 0x1F
        codePoint == '?'.code -> 0x7F
        else -> null
    }

    fun encode(
        key: TermKey,
        applicationCursorKeys: Boolean,
        shift: Boolean,
        alt: Boolean,
        ctrl: Boolean,
    ): ByteArray {
        val mod = 1 + (if (shift) 1 else 0) + (if (alt) 2 else 0) + (if (ctrl) 4 else 0)
        fun csi(value: String) = "\u001B[$value".toByteArray()
        fun ss3(letter: Char) = "\u001BO$letter".toByteArray()
        fun cursor(letter: Char): ByteArray = when {
            mod > 1 -> csi("1;$mod$letter")
            applicationCursorKeys -> ss3(letter)
            else -> csi(letter.toString())
        }
        fun tilde(code: Int): ByteArray =
            csi(if (mod > 1) "$code;$mod~" else "$code~")
        fun f1ToF4(letter: Char): ByteArray =
            if (mod > 1) csi("1;$mod$letter") else ss3(letter)
        fun altPrefix(base: ByteArray): ByteArray = if (alt) byteArrayOf(0x1B) + base else base

        return when (key) {
            TermKey.ENTER -> altPrefix(byteArrayOf(0x0D))
            TermKey.BACKSPACE -> altPrefix(byteArrayOf(0x7F))
            TermKey.TAB -> when {
                shift -> csi("Z")
                alt -> byteArrayOf(0x1B, 0x09)
                else -> byteArrayOf(0x09)
            }
            TermKey.ESC -> if (alt) byteArrayOf(0x1B, 0x1B) else byteArrayOf(0x1B)
            TermKey.UP -> cursor('A')
            TermKey.DOWN -> cursor('B')
            TermKey.RIGHT -> cursor('C')
            TermKey.LEFT -> cursor('D')
            TermKey.HOME -> cursor('H')
            TermKey.END -> cursor('F')
            TermKey.INSERT -> tilde(2)
            TermKey.DELETE -> tilde(3)
            TermKey.PAGE_UP -> tilde(5)
            TermKey.PAGE_DOWN -> tilde(6)
            TermKey.F1 -> f1ToF4('P')
            TermKey.F2 -> f1ToF4('Q')
            TermKey.F3 -> f1ToF4('R')
            TermKey.F4 -> f1ToF4('S')
            TermKey.F5 -> tilde(15)
            TermKey.F6 -> tilde(17)
            TermKey.F7 -> tilde(18)
            TermKey.F8 -> tilde(19)
            TermKey.F9 -> tilde(20)
            TermKey.F10 -> tilde(21)
            TermKey.F11 -> tilde(23)
            TermKey.F12 -> tilde(24)
        }
    }
}
