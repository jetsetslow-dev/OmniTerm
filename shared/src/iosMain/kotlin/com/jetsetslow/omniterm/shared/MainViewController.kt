package com.jetsetslow.omniterm.shared

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.ComposeUIViewController
import platform.UIKit.UIViewController

/**
 * The iOS app's root view controller, a Compose screen. It says the app is in development: the
 * Android screens move here as they become shared code, and nothing pretends to work before then.
 */
@Suppress("FunctionName") // Swift calls it as MainViewControllerKt.MainViewController().
fun MainViewController(): UIViewController = ComposeUIViewController { InDevelopmentScreen() }

@Composable
internal fun InDevelopmentScreen() {
    Column(
        modifier = Modifier.fillMaxSize().background(Color(0xFF0B1220)).safeDrawingPadding().padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        BasicText("OmniTerm", style = TextStyle(color = Color.White, fontSize = 28.sp, fontWeight = FontWeight.Bold))
        BasicText(
            "The iOS app is in development. Hosts, terminals and monitoring arrive here as they become shared with the Android app.",
            style = TextStyle(color = Color(0xFFB8C4D6), fontSize = 16.sp),
        )
    }
}
