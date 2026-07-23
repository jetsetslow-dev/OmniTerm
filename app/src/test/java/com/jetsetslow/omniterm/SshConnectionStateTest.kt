package com.jetsetslow.omniterm

import com.google.common.truth.Truth.assertThat
import com.jetsetslow.omniterm.ui.SshConnectionFailure
import com.jetsetslow.omniterm.ui.SshConnectionPhase
import com.jetsetslow.omniterm.ui.TerminalConnectionState
import com.jetsetslow.omniterm.ui.classifySshConnectionFailure
import com.jetsetslow.omniterm.ui.classifySshConnectionPhase
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.take
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.yield
import org.junit.Test

class SshConnectionStateTest {
    @Test
    fun bastionHandshakeProgressesThroughTypedStateFlow() = runTest {
        val state = MutableStateFlow<TerminalConnectionState>(TerminalConnectionState.Idle)
        val observed = mutableListOf<TerminalConnectionState>()
        val collector = backgroundScope.launch {
            state.drop(1).take(5).toList(observed)
        }
        yield()

        state.value = TerminalConnectionState.Connecting(SshConnectionPhase.Connecting)
        yield()
        listOf(
            "Resolving target…",
            "Authenticating bastion…",
            "Authenticating target…",
            "Opening channel…",
        ).forEach { raw ->
            state.value = TerminalConnectionState.Connecting(
                classifySshConnectionPhase(raw, viaJumpHost = true),
            )
            yield()
        }
        collector.join()

        assertThat(observed).containsExactly(
            TerminalConnectionState.Connecting(SshConnectionPhase.Connecting),
            TerminalConnectionState.Connecting(SshConnectionPhase.Resolving),
            TerminalConnectionState.Connecting(SshConnectionPhase.AuthenticatingBastion),
            TerminalConnectionState.Connecting(SshConnectionPhase.AuthenticatingTarget),
            TerminalConnectionState.Connecting(SshConnectionPhase.OpeningChannel),
        ).inOrder()
    }

    @Test
    fun intermediateProxyFailuresMapToStableUiStates() {
        assertThat(classifySshConnectionFailure("Auth fail at proxy"))
            .isEqualTo(SshConnectionFailure.Authentication)
        assertThat(classifySshConnectionFailure("java.net.SocketTimeoutException: timeout"))
            .isEqualTo(SshConnectionFailure.Timeout)
        assertThat(classifySshConnectionFailure("No route to host"))
            .isEqualTo(SshConnectionFailure.NetworkUnreachable)
        assertThat(classifySshConnectionFailure("Broken pipe"))
            .isEqualTo(SshConnectionFailure.Dropped)
    }
}
