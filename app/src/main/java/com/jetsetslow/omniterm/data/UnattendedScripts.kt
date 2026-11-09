package com.jetsetslow.omniterm.data

/**
 * Saved scripts that run with nobody there to confirm each run: script checks and automation
 * (Tasker and other apps). Both refuse the same scripts, for the same reasons.
 */
object UnattendedScripts {
    /** What runs the script, for the refusal's wording. */
    enum class Runner(val runsWithoutAsking: String, val nobodyToAsk: String) {
        CHECK("A check runs every minute without asking", "a check has nobody to ask"),
        AUTOMATION("Automation runs it without asking", "an automation has nobody to ask"),
    }

    /**
     * Why [script] cannot run unattended, or null when it can: no script or command, anything the
     * danger list flags ([dangerHits], from `commandDangerHits`), or a `{{value}}` with no default.
     */
    fun problem(script: QuickScriptEntity?, dangerHits: List<String>, runner: Runner): String? = when {
        script == null -> "Pick a saved script"
        script.command.isBlank() -> "That script has no command"
        dangerHits.isNotEmpty() ->
            "${runner.runsWithoutAsking}, so it must only read; this script looks destructive (${dangerHits.joinToString(", ")})."
        ScriptParams.parse(script.command).any { it.default.isEmpty() } ->
            "Give every {{value}} in the script a default ({{name=value}}): ${runner.nobodyToAsk}."
        else -> null
    }
}
