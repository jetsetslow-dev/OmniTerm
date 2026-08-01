package com.jetsetslow.omniterm.shared.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

/**
 * Compose Multiplatform application root.
 *
 * Feature content is intentionally injected: Android can migrate one screen at a time, while iOS
 * can host the same root without importing Android navigation, lifecycle, or platform objects.
 */
@Composable
fun OmniTermApp(
    state: SharedShellState,
    onAction: (SharedShellAction) -> Unit,
    featureContent: @Composable () -> Unit,
) {
    MaterialTheme {
        Surface(modifier = Modifier.fillMaxSize()) {
            if (state.initializing) {
                Column(
                    modifier = Modifier.fillMaxSize().padding(24.dp),
                    verticalArrangement = Arrangement.Center,
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    Text("Preparing OmniTerm…")
                }
            } else if (state.blockingError != null) {
                Column(
                    modifier = Modifier.fillMaxSize().padding(24.dp),
                    verticalArrangement = Arrangement.Center,
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    Text(state.blockingError)
                    Button(onClick = { onAction(SharedShellAction.Retry) }) {
                        Text("Retry")
                    }
                }
            } else {
                featureContent()
            }
        }
    }
}

data class SharedShellState(
    val initializing: Boolean = true,
    val blockingError: String? = null,
)

sealed interface SharedShellAction {
    data object Retry : SharedShellAction
}
