package com.jetsetslow.omniterm

import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Text
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.unit.dp
import com.jetsetslow.omniterm.ui.rememberTopAnchoredLazyListState
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assume.assumeFalse
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * Choosing a host sort left the Hosts list wherever the old top host had moved to, and on app open
 * the online hosts sorted to the top above a list still showing the first offline one. A new order
 * returns to the top; new data keeps the list at the top only if the user was there.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35])
class TopAnchoredListRobolectricTest {

    @get:Rule val composeTestRule = createComposeRule()

    private var order by mutableStateOf("name")
    private var rows by mutableStateOf((0 until 40).toList())
    private lateinit var state: LazyListState

    private fun showList() {
        composeTestRule.setContent {
            // Read in composition, as the Hosts screen sorts its list there.
            val shown = rows
            state = rememberTopAnchoredLazyListState(order, shown)
            LazyColumn(state = state, modifier = Modifier.height(300.dp)) {
                items(shown, key = { it }) { Text("host $it", Modifier.fillMaxWidth().height(60.dp)) }
            }
        }
        composeTestRule.waitForIdle()
    }

    private fun firstShown(): Int = state.layoutInfo.visibleItemsInfo.first().key as Int

    @Test
    fun hostsMovingUpKeepAListAtTheTopAtTheTop() {
        assumeFalse("Robolectric native runtime is not available on Linux aarch64 hosts.", isLinuxAarch64())
        showList()
        // A refresh brings hosts 30..39 online, and Status sort lists them first.
        rows = (30 until 40).toList() + (0 until 30).toList()
        composeTestRule.waitForIdle()
        assertEquals(0, state.firstVisibleItemIndex)
        assertEquals(30, firstShown())
    }

    @Test
    fun aNewSortShowsTheTopEvenWhenScrolledDown() {
        assumeFalse("Robolectric native runtime is not available on Linux aarch64 hosts.", isLinuxAarch64())
        showList()
        composeTestRule.runOnUiThread { runBlocking { state.scrollToItem(12) } }
        composeTestRule.waitForIdle()
        order = "status"
        rows = rows.reversed()
        composeTestRule.waitForIdle()
        assertEquals(0, state.firstVisibleItemIndex)
        assertEquals(39, firstShown())
    }

    @Test
    fun newDataLeavesSomeoneReadingFurtherDownOnTheirHost() {
        assumeFalse("Robolectric native runtime is not available on Linux aarch64 hosts.", isLinuxAarch64())
        showList()
        composeTestRule.runOnUiThread { runBlocking { state.scrollToItem(12) } }
        composeTestRule.waitForIdle()
        rows = (30 until 40).toList() + (0 until 30).toList()
        composeTestRule.waitForIdle()
        assertEquals(12, firstShown())
    }

    private fun isLinuxAarch64(): Boolean =
        System.getProperty("os.name").equals("Linux", ignoreCase = true) &&
            System.getProperty("os.arch").equals("aarch64", ignoreCase = true)
}
