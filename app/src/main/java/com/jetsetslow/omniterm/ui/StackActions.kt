package com.jetsetslow.omniterm.ui

/**
 * Which compose-stack actions the Infra screen offers, and what each one must warn before running.
 *
 * This lives apart from `InfraScreen` so the rule is a value rather than a shape buried in a
 * `when` inside a composable. The rule is: anything that changes the host asks first; read-only
 * actions stay one tap. Keeping the button lists and the warnings in one place is what makes that
 * checkable — the audit found `up` (UP -D) and `pull` had drifted out of it, dispatched straight to
 * the daemon with no warning, while every sibling in the same row confirmed and while the
 * *identical* UP -D on a downed stack did confirm.
 */

/** Actions that only read from the host. No confirmation — see [stackActionConfirm]. */
val STACK_READ_ONLY_ACTIONS: List<Pair<String, String>> = listOf(
    "ps" to "PS",
    "logs" to "Logs",
    "followLogs" to "FOLLOW",
    "config" to "CONFIG",
)

/** Actions that change the host. Every one of these must warn first. */
val STACK_MUTATING_ACTIONS: List<Pair<String, String>> = listOf(
    "update" to "Update",
    "build" to "Build",
    "pull" to "Pull",
    "up" to "UP -D",
    "forceRecreate" to "Force Recreate",
    "restart" to "Restart",
    "down" to "DOWN",
    "removeOrphans" to "Remove Orphans",
)

/**
 * `down` is the one mutating action with no entry here, because its dialog is not just copy: it
 * carries a "remove orphans too" choice, so the screen routes it to a dedicated dialog instead.
 * It is deliberately the *only* exemption, and `StackActionConfirmTest` holds it to that, so a new
 * action cannot quietly join it.
 */
const val STACK_ACTION_WITH_ITS_OWN_DIALOG = "down"

/** Title, body and button for the warning an action shows before it runs. */
data class StackActionConfirm(val title: String, val message: String, val confirmLabel: String)

/**
 * The warning [action] must show for [stackName], or null when it needs none.
 *
 * Returns null for read-only actions and for [STACK_ACTION_WITH_ITS_OWN_DIALOG].
 */
fun stackActionConfirm(action: String, stackName: String, workingDir: String): StackActionConfirm? =
    when (action) {
        "update" -> StackActionConfirm(
            "Update $stackName?",
            "Pull updated registry images, (re)build any Dockerfile-based images, then recreate this stack's containers?",
            "Update",
        )
        "build" -> StackActionConfirm(
            "Build $stackName?",
            "Build this stack's Dockerfile-based images (refreshing their base images). Containers are not recreated — run Update or UP -D afterwards to apply.",
            "Build",
        )
        // Same warning as the downed-stack UP -D, which already confirmed. This path is the more
        // disruptive of the two, because containers that are already running get recreated.
        "up" -> StackActionConfirm(
            "Bring $stackName up?",
            "Run compose up -d from $workingDir? Containers and networks are recreated from the compose file where it has changed.",
            "UP -D",
        )
        // Build confirms for the same reason: it fetches rather than recreates, but it still spends
        // the host's disk and bandwidth.
        "pull" -> StackActionConfirm(
            "Pull images for $stackName?",
            "Download updated images for this stack's services. Containers are not recreated — run Update or UP -D afterwards to apply.",
            "Pull",
        )
        "forceRecreate" -> StackActionConfirm(
            "Force Recreate $stackName?",
            "Recreate all containers even if nothing changed? Running containers will briefly restart.",
            "Recreate",
        )
        "restart" -> StackActionConfirm(
            "Restart $stackName?",
            "Restart all services in this stack? They will briefly go down.",
            "Restart",
        )
        // Named the stack like every other warning here. It was the one that did not, which matters
        // most on this screen: the list shows many stacks and the buttons repeat down the page.
        "removeOrphans" -> StackActionConfirm(
            "Remove orphans from $stackName?",
            "Remove containers for services no longer defined in the compose file for $stackName.",
            "Remove Orphans",
        )
        else -> null
    }
