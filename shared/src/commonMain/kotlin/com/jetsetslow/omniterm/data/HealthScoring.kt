package com.jetsetslow.omniterm.data

import kotlin.math.roundToInt

/**
 * One metric's three escalating (threshold, penalty) tiers used to score host health. A reading
 * at or above a tier's threshold subtracts that tier's penalty (the highest matching tier wins).
 */
data class MetricTiers(
    val warnAt: Float, val highAt: Float, val criticalAt: Float,
    val warnPenalty: Int, val highPenalty: Int, val criticalPenalty: Int,
) {
    fun penaltyFor(value: Float): Int = when {
        value >= criticalAt -> criticalPenalty
        value >= highAt -> highPenalty
        value >= warnAt -> warnPenalty
        else -> 0
    }

    fun tierLabel(value: Float): String? = when {
        value >= criticalAt -> "critical"
        value >= highAt -> "high"
        value >= warnAt -> "elevated"
        else -> null
    }

    fun tierThreshold(value: Float): Float? = when {
        value >= criticalAt -> criticalAt
        value >= highAt -> highAt
        value >= warnAt -> warnAt
        else -> null
    }
}

/** A single contributing line in a host's score breakdown. */
data class HealthFactor(val label: String, val penalty: Int)

/** Full explanation of a host's current score: which metrics deducted points, and how many. */
data class HealthBreakdown(
    val score: Int,
    val offline: Boolean,
    val factors: List<HealthFactor>,
) {
    val healthy: Boolean get() = !offline && factors.isEmpty()
}

/**
 * User-tunable health-scoring configuration. The score starts at 100 and each metric subtracts a
 * penalty based on its tier thresholds; the result is clamped to 0..100. Both the thresholds and
 * the penalty weights are editable in Settings.
 */
data class HealthScoringConfig(
    val cpu: MetricTiers = MetricTiers(50f, 75f, 90f, 5, 15, 30),
    val mem: MetricTiers = MetricTiers(70f, 80f, 90f, 5, 12, 25),
    val disk: MetricTiers = MetricTiers(80f, 90f, 95f, 10, 25, 30),
    val latency: MetricTiers = MetricTiers(50f, 100f, 200f, 3, 7, 15),
) {
    fun score(cpu: Float, ram: Float, disk: Float, rtt: Int): Int =
        (100 - this.cpu.penaltyFor(cpu) - mem.penaltyFor(ram) -
            this.disk.penaltyFor(disk) - latency.penaltyFor(rtt.toFloat())).coerceIn(0, 100)

    /** Build a human-readable breakdown of the score for the given readings. */
    fun breakdown(cpu: Float, ram: Float, disk: Float, rtt: Int, online: Boolean): HealthBreakdown {
        if (!online) {
            return HealthBreakdown(0, offline = true, factors = listOf(
                HealthFactor("Host offline or unreachable — score forced to 0", 100)
            ))
        }
        val factors = mutableListOf<HealthFactor>()
        fun consider(name: String, value: Float, unit: String, tiers: MetricTiers) {
            val pen = tiers.penaltyFor(value)
            if (pen > 0) {
                val lvl = tiers.tierLabel(value) ?: ""
                val thr = tiers.tierThreshold(value)?.roundToInt() ?: 0
                factors += HealthFactor("$name ${value.roundToInt()}$unit — $lvl (≥$thr$unit)", pen)
            }
        }
        consider("CPU", cpu, "%", this.cpu)
        consider("Memory", ram, "%", mem)
        consider("Disk", disk, "%", this.disk)
        consider("Latency", rtt.toFloat(), "ms", latency)
        val score = (100 - factors.sumOf { it.penalty }).coerceIn(0, 100)
        return HealthBreakdown(score, offline = false, factors = factors)
    }

    /** Compact "cpu:50,75,90,5,15,30;mem:...;disk:...;lat:..." encoding for app_settings storage. */
    fun encode(): String = listOf("cpu" to cpu, "mem" to mem, "disk" to disk, "lat" to latency)
        .joinToString(";") { (k, t) ->
            "$k:${t.warnAt},${t.highAt},${t.criticalAt},${t.warnPenalty},${t.highPenalty},${t.criticalPenalty}"
        }

    companion object {
        val DEFAULT = HealthScoringConfig()

        fun decode(s: String?): HealthScoringConfig {
            if (s.isNullOrBlank()) return DEFAULT
            return try {
                val map = s.split(";").mapNotNull { part ->
                    val kv = part.split(":", limit = 2)
                    if (kv.size < 2) return@mapNotNull null
                    val n = kv[1].split(",").map { it.trim() }
                    if (n.size < 6) return@mapNotNull null
                    kv[0] to MetricTiers(
                        n[0].toFloat(), n[1].toFloat(), n[2].toFloat(),
                        n[3].toInt(), n[4].toInt(), n[5].toInt(),
                    )
                }.toMap()
                HealthScoringConfig(
                    cpu = map["cpu"] ?: DEFAULT.cpu,
                    mem = map["mem"] ?: DEFAULT.mem,
                    disk = map["disk"] ?: DEFAULT.disk,
                    latency = map["lat"] ?: DEFAULT.latency,
                )
            } catch (e: Exception) {
                DEFAULT
            }
        }
    }
}
