package com.jetsetslow.omniterm

import android.content.pm.ActivityInfo
import android.content.res.Configuration
import android.os.SystemClock
import android.util.Log
import android.view.View
import android.widget.EditText
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.lifecycle.ViewModelProvider
import androidx.test.espresso.Espresso.onView
import androidx.test.espresso.ViewAction
import androidx.test.espresso.matcher.ViewMatchers.isAssignableFrom
import androidx.test.espresso.matcher.ViewMatchers.withTagValue
import androidx.test.platform.app.InstrumentationRegistry
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.Screen
import com.jetsetslow.omniterm.ui.parseDockerComposeYaml
import com.jetsetslow.omniterm.ui.renderComposeYaml
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.hamcrest.Matchers.equalTo

/** Opt-in physical UI stress for a 335 KB, 400-service Compose stack and Raw YAML editor. */
class E2eComposeBuilderUiStressTest {
    @get:Rule
    val composeRule = createAndroidComposeRule<MainActivity>()

    @Test
    fun largeVisualAndRawEditorsSurviveRotationWithoutLosingDraft() = runBlocking {
        val startedAt = SystemClock.elapsedRealtime()
        fun checkpoint(label: String) = Log.i("ComposeStress", "$label +${SystemClock.elapsedRealtime() - startedAt}ms")
        val args = InstrumentationRegistry.getArguments()
        assumeTrue(args.getString("omniterm_e2e_compose_ui") == "yes")
        val vm = ViewModelProvider(composeRule.activity)[AppViewModel::class.java]
        composeRule.waitUntil(15_000) { vm.servers.value.any { it.name == HOST_NAME } }
        val host = requireNotNull(vm.servers.value.find { it.name == HOST_NAME })
        checkpoint("host-ready")
        composeRule.runOnUiThread { vm.selectedServerId = host.id }

        val yaml = requireNotNull(vm.readComposeFile(COMPOSE_PATH)) { "Could not read $COMPOSE_PATH" }
        checkpoint("file-read")
        assertTrue("fixture must cross the highlighter cutoff", yaml.length > 300_000)
        val draft = parseDockerComposeYaml(
            yaml = yaml,
            projectName = "omniterm-large-stack",
            workingDir = COMPOSE_PATH.substringBeforeLast('/'),
            fileName = "compose.yml",
            composeFilePath = COMPOSE_PATH,
            composeConfigFiles = COMPOSE_PATH,
            runtime = "docker",
        )
        assertEquals(400, draft.services.size)
        checkpoint("parsed")
        assertEquals(yaml.trimEnd(), renderComposeYaml(draft, draft).trimEnd())
        checkpoint("rendered-unchanged")

        composeRule.runOnUiThread {
            vm.beginComposeDraft(draft)
            vm.activeInfraTab = 1
            vm.navigateTo(Screen.Infra)
        }
        composeRule.waitUntil(30_000) {
            composeRule.onAllNodes(hasText("service-000", substring = false))
                .fetchSemanticsNodes().isNotEmpty()
        }
        composeRule.onNodeWithText("Compose Builder").fetchSemanticsNode()
        composeRule.onNodeWithText("service-000").fetchSemanticsNode()
        checkpoint("visual-ready")

        // At 335 KB the editor must remain responsive while deliberately skipping token spans.
        composeRule.onNodeWithText("Raw YAML").performScrollTo().performClick()
        checkpoint("raw-click-returned")
        composeRule.waitUntil(20_000) {
            composeRule.onAllNodes(hasText("Large file mode", substring = true))
                .fetchSemanticsNodes().isNotEmpty()
        }
        assertTrue(vm.activeComposeRawMode)
        onView(withTagValue(equalTo("code-editor-native"))).perform(object : ViewAction {
            override fun getConstraints(): org.hamcrest.Matcher<View> = isAssignableFrom(EditText::class.java)
            override fun getDescription() = "insert unsaved rotation marker at the start"
            override fun perform(uiController: androidx.test.espresso.UiController, view: View) {
                (view as EditText).text.insert(0, MARKER)
                uiController.loopMainThreadUntilIdle()
            }
        })
        composeRule.waitUntil(10_000) { vm.activeComposeRawText?.contains(MARKER) == true }

        // Rotation recreates every composable; raw mode and the unsaved 335 KB buffer must come
        // back from the ViewModel, not silently reset to the on-disk YAML.
        composeRule.runOnUiThread {
            composeRule.activity.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
        }
        composeRule.waitUntil(20_000) {
            composeRule.activity.resources.configuration.orientation == Configuration.ORIENTATION_PORTRAIT &&
                vm.activeComposeRawText?.contains(MARKER) == true
        }
        composeRule.onNodeWithText("Raw YAML").assertIsSelected()
        onView(withTagValue(equalTo("code-editor-native"))).check { view, error ->
            if (error != null) throw error
            assertTrue((view as EditText).text.contains(MARKER))
        }

        // Root-level full-screen editor, hardware Back, and dirty Raw->Visual confirmation.
        composeRule.onNodeWithContentDescription("Edit full screen").performClick()
        composeRule.onNodeWithContentDescription("Close editor").fetchSemanticsNode()
        composeRule.runOnUiThread { composeRule.activity.onBackPressedDispatcher.onBackPressed() }
        composeRule.waitUntil(10_000) {
            composeRule.onAllNodes(hasText("Compose Builder", substring = false))
                .fetchSemanticsNodes().isNotEmpty()
        }
        composeRule.onNodeWithText("Visual").performScrollTo().performClick()
        composeRule.onNodeWithText("Leave Raw YAML?").fetchSemanticsNode()
        composeRule.onNodeWithText("Switch").performClick()
        composeRule.waitUntil(30_000) {
            composeRule.onAllNodes(hasText("400 services · list is virtualized for responsive editing", substring = false))
                .fetchSemanticsNodes().isNotEmpty()
        }
        composeRule.onNodeWithText("service-000").fetchSemanticsNode()

        composeRule.runOnUiThread {
            composeRule.activity.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
        }
        composeRule.waitUntil(20_000) {
            composeRule.activity.resources.configuration.orientation == Configuration.ORIENTATION_LANDSCAPE
        }
        assertTrue(vm.activeComposeRawText?.contains(MARKER) == true)
        composeRule.runOnUiThread { vm.clearActiveComposeDraft() }
    }

    private companion object {
        const val HOST_NAME = "E2E Foreground Demo"
        const val COMPOSE_PATH = "/home/tempadmin/omniterm-e2e/corpus/07-large-stack/compose.yml"
        const val MARKER = "# unsaved-rotation-marker\n"
    }
}
