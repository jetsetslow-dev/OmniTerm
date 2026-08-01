@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package com.jetsetslow.omniterm.shared.platform

import platform.UIKit.UIPasteboard

class IosClipboardAdapter : ClipboardAdapter {
    override suspend fun readText(): CapabilityResult<String?> =
        CapabilityResult.Available(UIPasteboard.generalPasteboard.string)

    override suspend fun writeText(value: String): CapabilityResult<Unit> {
        UIPasteboard.generalPasteboard.string = value
        return CapabilityResult.Available(Unit)
    }
}
