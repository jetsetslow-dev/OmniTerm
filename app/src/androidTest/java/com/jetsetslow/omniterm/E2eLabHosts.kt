package com.jetsetslow.omniterm

import androidx.compose.ui.test.junit4.ComposeTestRule
import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.ui.AppViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout

/**
 * A lab host saved the way the user saves one (password login) and connected to once, its host key
 * approved on first use, for the suites that need a host of their own and for the provisioner.
 */
internal object E2eLabHosts {
    /**
     * Saves [name] at [host]:[port] and returns it. An earlier host of that name is removed first,
     * or, with [keepExisting], returned as it is.
     */
    suspend fun add(
        rule: ComposeTestRule,
        vm: AppViewModel,
        name: String,
        host: String,
        port: Int,
        user: String,
        pass: String,
        keepExisting: Boolean = false,
    ): ServerEntity {
        vm.servers.value.firstOrNull { it.name == name }?.let { if (keepExisting) return it }
        remove(rule, vm, name)
        var added: String? = "pending"
        rule.runOnUiThread {
            vm.addServer(name, host, port, user, null, "password", "", 0, false, "", password = pass) { added = it }
        }
        await("$name added") { vm.servers.value.any { it.name == name } }
        check(added == null) { "addServer reported: $added" }
        return vm.servers.value.single { it.name == name }
    }

    /**
     * Runs one command on [host], approving its host key if this is the first connection to it, so
     * no later connection waits on that question. Returns what the command printed.
     */
    suspend fun connectOnce(vm: AppViewModel, host: ServerEntity): String = coroutineScope {
        val approve = launch(Dispatchers.Main) {
            while (true) {
                vm.pendingHostKeyApproval?.let { if (host.host in it.host) vm.approveHostKey(true) }
                delay(100)
            }
        }
        try {
            vm.executeSshCommand(host, "printf 'OT-READY\\n'").also {
                check("OT-READY" in it) { "${host.name} did not answer: ${it.take(200)}" }
            }
        } finally {
            approve.cancel()
        }
    }

    /** Removes every host named [name]. */
    suspend fun remove(rule: ComposeTestRule, vm: AppViewModel, name: String) {
        rule.runOnUiThread { if (vm.servers.value.any { it.id == vm.selectedServerId && it.name == name }) vm.selectedServerId = null }
        vm.servers.value.filter { it.name == name }.forEach { vm.deleteServer(it) }
        await("$name removed") { vm.servers.value.none { it.name == name } }
    }

    private suspend fun await(what: String, predicate: () -> Boolean) {
        try {
            withTimeout(10_000) { while (!predicate()) delay(100) }
        } catch (e: kotlinx.coroutines.TimeoutCancellationException) {
            throw AssertionError("$what: not within 10 s", e)
        }
    }
}
