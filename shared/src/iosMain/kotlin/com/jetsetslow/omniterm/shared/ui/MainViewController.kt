package com.jetsetslow.omniterm.shared.ui

import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.window.ComposeUIViewController
import com.jetsetslow.omniterm.shared.facade.OmniTermFacade

/** UIKit entry point used by the thin Swift shell. */
fun MainViewController(facade: OmniTermFacade) = ComposeUIViewController {
    val snapshot = remember { mutableStateOf(facade.currentSnapshot()) }
    DisposableEffect(facade) {
        val observation = facade.observe { snapshot.value = it }
        onDispose { observation.cancel() }
    }
    OmniTermApp(
        state = SharedShellState(
            initializing = snapshot.value.initializing,
            blockingError = snapshot.value.errorMessage,
        ),
        onAction = { if (it == SharedShellAction.Retry) facade.retry() },
    ) {
        androidx.compose.material3.Text(snapshot.value.title)
    }
}
