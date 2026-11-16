package com.jetsetslow.omniterm

import androidx.test.platform.app.InstrumentationRegistry
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
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
        vm: AppViewModel,
        name: String,
        host: String,
        port: Int,
        user: String,
        pass: String,
        keepExisting: Boolean = false,
    ): ServerEntity {
        vm.servers.value.firstOrNull { it.name == name }?.let { if (keepExisting) return it }
        remove(vm, name)
        var added: String? = "pending"
        onMain { vm.addServer(name, host, port, user, null, "password", "", 0, false, "", password = pass) { added = it } }
        // The form's answer first: a refusal, such as another saved host at this address, then
        // says why instead of surfacing as a host that never appears.
        await("$name answered") { added != "pending" }
        check(added == null) { "addServer reported: $added" }
        await("$name added") { vm.servers.value.any { it.name == name } }
        return vm.servers.value.single { it.name == name }
    }

    /**
     * Saves [server] as it is, its proxy or jump route included, replacing an earlier host of its
     * name. Unlike [add] it skips the form's one-host-per-address rule, as a restored backup can, so
     * several routes to one machine can be saved side by side.
     */
    suspend fun save(vm: AppViewModel, server: ServerEntity): ServerEntity {
        remove(vm, server.name)
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        AppRepository(AppDatabase.getDatabase(context)).insertServer(server)
        await("${server.name} added") { vm.servers.value.any { it.name == server.name } }
        return vm.servers.value.single { it.name == server.name }
    }

    /**
     * Runs one command on [host], approving its host key if this is the first connection to it (and
     * its proxy's or jump host's, for a host behind one), so no later connection waits on that
     * question. Returns what the command printed.
     */
    suspend fun connectOnce(vm: AppViewModel, host: ServerEntity): String =
        approvingHostKeys(vm, listOf(host.host, host.proxyHost)) {
            vm.executeSshCommand(host, "printf 'OT-READY\\n'").also {
                check("OT-READY" in it) { "${host.name} did not answer: ${it.take(200)}" }
            }
        }

    /**
     * Runs [block], answering yes, as the user would, to every first-use host key question about one
     * of [hosts] it raises: the lab's own hosts, whose keys a fresh device has never seen.
     */
    suspend fun <T> approvingHostKeys(vm: AppViewModel, hosts: Collection<String>, block: suspend () -> T): T = coroutineScope {
        val names = hosts.filter { it.isNotBlank() }
        val approve = launch(Dispatchers.Main) {
            while (true) {
                vm.pendingHostKeyApproval?.let { request -> if (names.any { it in request.host }) vm.approveHostKey(true) }
                delay(100)
            }
        }
        try {
            block()
        } finally {
            approve.cancel()
        }
    }

    /** Removes every host named [name]. */
    suspend fun remove(vm: AppViewModel, name: String) {
        onMain { if (vm.servers.value.any { it.id == vm.selectedServerId && it.name == name }) vm.selectedServerId = null }
        vm.servers.value.filter { it.name == name }.forEach { vm.deleteServer(it) }
        await("$name removed") { vm.servers.value.none { it.name == name } }
    }

    private fun onMain(block: () -> Unit) = InstrumentationRegistry.getInstrumentation().runOnMainSync(block)

    private suspend fun await(what: String, predicate: () -> Boolean) {
        try {
            withTimeout(10_000) { while (!predicate()) delay(100) }
        } catch (e: kotlinx.coroutines.TimeoutCancellationException) {
            throw AssertionError("$what: not within 10 s", e)
        }
    }
}
