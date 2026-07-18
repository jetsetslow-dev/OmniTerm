package com.jetsetslow.omniterm

import android.app.Instrumentation
import android.view.accessibility.AccessibilityNodeInfo

/** Tiny dependency-free accessibility driver for physical tests and classic/Compose views alike. */
internal class E2eAccessibility(private val instrumentation: Instrumentation) {
    fun hasText(text: String, contains: Boolean = false): Boolean =
        find { node ->
            val actual = node.text?.toString().orEmpty()
            if (contains) actual.contains(text, ignoreCase = true) else actual.equals(text, ignoreCase = true)
        } != null

    fun hasDescription(description: String): Boolean =
        find { it.contentDescription?.toString() == description } != null

    fun clickText(text: String) = click(
        find { it.text?.toString()?.equals(text, ignoreCase = true) == true },
        "text '$text'",
    )
    fun clickDescription(description: String) =
        click(find { it.contentDescription?.toString() == description }, "description '$description'")

    fun scrollToText(text: String, attempts: Int = 30): Boolean {
        repeat(attempts) {
            if (hasText(text)) return true
            val scrollable = find { node ->
                node.isScrollable || node.actionList.any { it.id == AccessibilityNodeInfo.ACTION_SCROLL_FORWARD }
            } ?: return false
            if (!scrollable.performAction(AccessibilityNodeInfo.ACTION_SCROLL_FORWARD)) return false
            instrumentation.waitForIdleSync()
        }
        return hasText(text)
    }

    private fun click(node: AccessibilityNodeInfo?, label: String) {
        var target = requireNotNull(node) { "No accessibility node with $label" }
        while (!target.isClickable && target.parent != null) target = target.parent
        check(target.performAction(AccessibilityNodeInfo.ACTION_CLICK)) { "Could not click $label" }
        instrumentation.waitForIdleSync()
    }

    private fun find(predicate: (AccessibilityNodeInfo) -> Boolean): AccessibilityNodeInfo? {
        val root = instrumentation.uiAutomation.rootInActiveWindow ?: return null
        val queue = ArrayDeque<AccessibilityNodeInfo>()
        queue.add(root)
        while (queue.isNotEmpty()) {
            val node = queue.removeFirst()
            if (predicate(node)) return node
            for (index in 0 until node.childCount) node.getChild(index)?.let(queue::addLast)
        }
        return null
    }
}
