package com.jetsetslow.omniterm.ui

import org.json.JSONObject

/** Normalize the earlier Flutter document into the published Kotlin schema before validation. */
internal fun normalizeBackupDocument(root: JSONObject) {
    if (root.has("format") || root.has("schema")) return
    val version = root.optInt("v", -1)
    require(version in 1..2) {
        if (version > 2) "Backup schema is newer than this app supports."
        else "Not an OmniTerm backup file."
    }
    require(listOf("servers", "sshKeys", "credentialProfiles", "scripts", "settings", "alertRules",
        "activeAlerts", "alertHistory", "wolTargets", "networkShares", "portForwards", "crashLogs",
    ).any(root::has)) { "Backup contains no data OmniTerm can restore." }
    if (root.has("scripts")) root.put("quickScripts", root.remove("scripts"))
    if (root.has("settings")) {
        val rows = root.getJSONArray("settings")
        val settings = JSONObject()
        for (i in 0 until rows.length()) {
            val row = rows.getJSONObject(i)
            val key = row.getString("key")
            require(!settings.has(key)) { "Backup contains a duplicate setting." }
            settings.put(key, row.getString("value"))
        }
        root.put("settings", settings)
    }
    root.remove("v")
    root.put("format", "omniterm-backup")
    root.put("schema", 5)
}
