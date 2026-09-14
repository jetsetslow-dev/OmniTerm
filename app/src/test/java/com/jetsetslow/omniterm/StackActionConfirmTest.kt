package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.ui.STACK_ACTION_WITH_ITS_OWN_DIALOG
import com.jetsetslow.omniterm.ui.STACK_MUTATING_ACTIONS
import com.jetsetslow.omniterm.ui.STACK_READ_ONLY_ACTIONS
import com.jetsetslow.omniterm.ui.stackActionConfirm
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The Infra screen's stack buttons either change the host or they don't, and the ones that do must
 * say so first.
 *
 * Written because the rule had already drifted: `up` (UP -D) and `pull` sat in the mutating row
 * with every sibling confirming around them, and went straight to the daemon unwarned — while the
 * *same* UP -D offered on a downed stack did confirm. That drift was invisible because the decision
 * was a `when` inside a composable, where nothing could check it. Driving these off the same lists
 * the screen renders means a new button cannot be added without either giving it a warning or
 * deliberately exempting it here.
 */
class StackActionConfirmTest {
    private val stack = "fixture-stack"
    private val dir = "/srv/fixture-stack"

    @Test
    fun everyActionThatChangesTheHostWarnsFirst() {
        for ((action, label) in STACK_MUTATING_ACTIONS) {
            if (action == STACK_ACTION_WITH_ITS_OWN_DIALOG) continue
            val warning = stackActionConfirm(action, stack, dir)
            assertNotNull("\"$label\" changes the host and must warn before it runs", warning)
            assertTrue("\"$label\" must name the stack it will act on", warning!!.title.contains(stack))
            assertTrue("\"$label\" needs a reason, not just a title", warning.message.isNotBlank())
            assertTrue("\"$label\" needs a button label", warning.confirmLabel.isNotBlank())
        }
    }

    @Test
    fun readOnlyActionsStayOneTap() {
        for ((action, label) in STACK_READ_ONLY_ACTIONS) {
            assertNull("\"$label\" only reads; a confirmation would be noise", stackActionConfirm(action, stack, dir))
        }
    }

    /**
     * DOWN is exempt because its dialog also carries the remove-orphans choice, so it cannot be
     * expressed as plain copy. Pinning it as the *only* exemption is the point: without this, a new
     * destructive action could be added with no warning and no test would notice.
     */
    @Test
    fun downIsTheOnlyActionAllowedToSkipTheSharedWarning() {
        val exempt = STACK_MUTATING_ACTIONS.filter { stackActionConfirm(it.first, stack, dir) == null }
        assertEquals(listOf(STACK_ACTION_WITH_ITS_OWN_DIALOG), exempt.map { it.first })
    }

    @Test
    fun theTwoRowsDoNotOverlap() {
        val readOnly = STACK_READ_ONLY_ACTIONS.map { it.first }.toSet()
        val mutating = STACK_MUTATING_ACTIONS.map { it.first }.toSet()
        assertEquals("an action cannot be both read-only and mutating", emptySet<String>(), readOnly intersect mutating)
    }

    /** UP -D is offered in two places; the warning must not depend on which one the user found. */
    @Test
    fun upWarnsAboutRecreatingContainersJustLikeTheDownedStackButton() {
        val warning = stackActionConfirm("up", stack, dir)
        assertNotNull(warning)
        assertTrue("the warning must name the directory it runs from", warning!!.message.contains(dir))
        assertTrue("and must say containers get recreated", warning.message.contains("recreated"))
    }
}
