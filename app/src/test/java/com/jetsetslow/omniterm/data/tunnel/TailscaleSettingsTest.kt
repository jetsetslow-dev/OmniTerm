package com.jetsetslow.omniterm.data.tunnel

import com.google.common.truth.Truth.assertThat
import com.google.common.truth.Truth.assertWithMessage
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** A Tailscale tunnel's settings, and the phone's interfaces as the Go library reads them. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class TailscaleSettingsTest {
    @Test
    fun settingsRoundTripAndTellTheirControlServerApart() {
        // A made-up key, split so the line never has the shape of a real Tailscale key.
        val s = TailscaleSettings(" https://headscale.example.com/ ", " tskey-" + "auth-1 ", " pixel ")
        val back = TailscaleSettings.parse(s.toConfig())!!
        assertThat(back).isEqualTo(TailscaleSettings("https://headscale.example.com/", "tskey-" + "auth-1", "pixel"))
        assertThat(back.sameServerAs(TailscaleSettings("HTTPS://headscale.example.com"))).isTrue()
        assertThat(back.sameServerAs(TailscaleSettings(""))).isFalse()
        assertThat(TailscaleSettings.parse("not json")).isNull()
        assertThat(TailscaleSettings.deviceName("Pixel 8 Pro")).isEqualTo("omniterm-pixel-8-pro")
        assertThat(TailscaleSettings.deviceName("  ")).isEqualTo("omniterm")
    }

    @Test
    fun plainHttpIsFlaggedUnlessTheServerIsOnThisPhone() {
        for (url in listOf("http://headscale.lan:8080", "http://10.0.2.2:8085", "HTTP://[fd00::1]:8080")) {
            assertWithMessage(url).that(TailscaleSettings(url).plainHttp()).isTrue()
        }
        for (url in listOf("", "https://headscale.example.com", "http://127.0.0.1:8085", "http://localhost:8080", "http://[::1]:8080")) {
            assertWithMessage(url).that(TailscaleSettings(url).plainHttp()).isFalse()
        }
    }

    @Test
    fun interfacesAreWrittenOnePerLineWithTheirFlags() {
        val text = TailscaleNetwork.describe(
            listOf(
                TailscaleNetwork.Iface("wlan0", 30, 1500, up = true, loopback = false, pointToPoint = false, multicast = true, addresses = listOf("192.168.1.20/24", "fe80::1/64")),
                TailscaleNetwork.Iface("lo", 1, 65536, up = true, loopback = true, pointToPoint = false, multicast = false, addresses = listOf("127.0.0.1/8")),
                TailscaleNetwork.Iface("rmnet0", 12, 1400, up = false, loopback = false, pointToPoint = false, multicast = false, addresses = emptyList()),
                TailscaleNetwork.Iface("bad name", 2, 1500, up = true, loopback = false, pointToPoint = false, multicast = false, addresses = emptyList()),
            ),
        )
        assertThat(text.lines()).containsExactly(
            "wlan0 30 1500 um 192.168.1.20/24,fe80::1/64",
            "lo 1 65536 ul 127.0.0.1/8",
            "rmnet0 12 1400 - -",
        ).inOrder()
    }
}
