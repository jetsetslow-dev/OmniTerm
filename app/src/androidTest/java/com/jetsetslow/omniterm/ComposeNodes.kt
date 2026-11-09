package com.jetsetslow.omniterm

import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.junit4.AndroidComposeTestRule

/**
 * Whether a node matching [matcher] is on screen, for use inside `waitUntil`. While a link or a
 * share is handed over, the forwarding screen is in front and the main screen is paused, so there
 * is briefly no Compose screen to look in. That means "not yet", not a failure. A check that
 * something is absent must not use this: there, no screen is not proof.
 */
internal fun AndroidComposeTestRule<*, *>.showsNode(matcher: SemanticsMatcher): Boolean =
    try {
        onAllNodes(matcher, useUnmergedTree = true).fetchSemanticsNodes().isNotEmpty()
    } catch (e: IllegalStateException) {
        if (e.message?.startsWith("No compose hierarchies found") == true) false else throw e
    }
