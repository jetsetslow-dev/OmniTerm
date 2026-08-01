package com.jetsetslow.omniterm.shared.network

import io.ktor.client.HttpClient
import io.ktor.client.engine.android.Android

internal actual fun createPlatformHttpClient(): HttpClient = HttpClient(Android) {
    expectSuccess = false
    followRedirects = true
}
