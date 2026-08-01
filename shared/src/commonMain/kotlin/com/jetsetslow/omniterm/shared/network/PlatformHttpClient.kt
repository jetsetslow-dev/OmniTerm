package com.jetsetslow.omniterm.shared.network

import io.ktor.client.HttpClient

internal expect fun createPlatformHttpClient(): HttpClient
