package com.jetsetslow.omniterm

import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.INFRA_TAB_BUILDER
import com.jetsetslow.omniterm.ui.INFRA_TAB_STACKS
import com.jetsetslow.omniterm.ui.Screen
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Rule
import org.junit.Test

/**
 * Back out of the Compose Builder must actually leave it.
 *
 * The builder creates a draft as soon as it composes, so that edits survive a tab switch. A Back
 * handler that only cleared the draft therefore trapped the user: the clear made
 * `activeComposeDraft` null, the mirror effect immediately rebuilt an empty draft, and the tab did
 * not change — every press looked like nothing happened, with no way out of the screen.
 *
 * Deliberately host-free. It seeds a server row so InfraScreen renders its tabs (it short-circuits
 * to an empty state with no server selected, which would make this pass vacuously), but never
 * connects to anything, so it runs in the ordinary connected-test gate rather than opt-in.
 */
class ComposeBuilderBackNavigationTest {
    @get:Rule
    val composeRule = createAndroidComposeRule<MainActivity>()

    @Test
    fun backLeavesTheBuilderInsteadOfSilentlyRecreatingTheDraft() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val repository = AppRepository(AppDatabase.getDatabase(context))
        repository.getAllServers()
            .filter { it.name == HOST_NAME }
            .forEach { repository.deleteServerAndDependents(it.id) }
        val serverId = repository.insertServer(
            ServerEntity(name = HOST_NAME, host = "127.0.0.1", port = 22, username = "nobody"),
        ).toInt()

        try {
            val vm = ViewModelProvider(composeRule.activity)[AppViewModel::class.java]
            composeRule.runOnUiThread { vm.isAppLocked = false }
            composeRule.waitUntil(15_000) { vm.servers.value.any { it.id == serverId } }

            // Via Servers so the back stack has a known depth: commitNavigation() resets history on
            // Screen.Servers, leaving exactly [Servers, Infra] to pop.
            composeRule.runOnUiThread {
                vm.selectedServerId = serverId
                vm.navigateTo(Screen.Servers)
                vm.navigateTo(Screen.Infra)
                vm.activeInfraTab = INFRA_TAB_BUILDER
            }
            composeRule.waitUntil(15_000) { vm.activeComposeDraft != null }
            assertNotNull("builder should hold a draft once composed", vm.activeComposeDraft)

            // First Back: leaves the builder for the stack list and does not resurrect the draft.
            composeRule.runOnUiThread { composeRule.activity.onBackPressedDispatcher.onBackPressed() }
            composeRule.waitUntil(10_000) { vm.activeInfraTab == INFRA_TAB_STACKS }
            composeRule.waitForIdle()
            assertNull("Back must not leave a draft behind to re-enter", vm.activeComposeDraft)

            // Second Back: the builder is no longer composed, so its handler is gone and the
            // app-level handler pops the screen. Before the fix this never happened -- the builder
            // handler swallowed every press.
            composeRule.runOnUiThread { composeRule.activity.onBackPressedDispatcher.onBackPressed() }
            composeRule.waitUntil(10_000) { vm.currentScreen != Screen.Infra }
            assertNotEquals(Screen.Infra, vm.currentScreen)
        } finally {
            repository.deleteServerAndDependents(serverId)
        }
    }

    private companion object {
        const val HOST_NAME = "Back Navigation Fixture"
    }
}
