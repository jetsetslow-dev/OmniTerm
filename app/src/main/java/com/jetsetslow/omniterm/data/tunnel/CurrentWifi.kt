package com.jetsetslow.omniterm.data.tunnel

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.location.LocationManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.wifi.WifiInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.provider.Settings
import androidx.core.content.ContextCompat
import androidx.core.location.LocationManagerCompat
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

/**
 * The Wi-Fi the phone's connections go over, for the tunnels that are not needed on some networks
 * ([TunnelNetworks]). It follows the network Android routes the app's connections over, so a
 * phone on mobile data, or behind another app's VPN, is not "on Wi-Fi" here even with Wi-Fi joined.
 *
 * Android gives a Wi-Fi's name only to an app with the precise location permission, with Location
 * on, and while the app is on screen. [WifiMemory] keeps the name for as long as the phone stays
 * on that connection, so background checks know it too; nothing asks for location all the time.
 * The name never leaves the phone.
 */
object CurrentWifi {
    /** [onWifi] with a null [name]: Android did not say which Wi-Fi. */
    data class State(val onWifi: Boolean = false, val name: String? = null)

    private val _state = MutableStateFlow(State())
    val state: StateFlow<State> = _state.asStateFlow()

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private var app: Context? = null
    private var callback: ConnectivityManager.NetworkCallback? = null
    private var memory = WifiMemory()
    private var boot = NO_BOOT_COUNT
    private var current: Long? = null

    // Done once the network Android routes over has been reported after (re)starting to watch, or
    // after FIRST_REPORT_MS with none: a connection made as the app starts waits that long at most.
    @Volatile private var reported: CompletableDeferred<Unit> = CompletableDeferred(Unit)

    /** Starts following the phone's network. Safe to call from every way into the app. */
    @Synchronized
    fun start(context: Context) {
        if (app != null) return
        val appContext = context.applicationContext
        app = appContext
        boot = runCatching { Settings.Global.getInt(appContext.contentResolver, Settings.Global.BOOT_COUNT, NO_BOOT_COUNT) }
            .getOrDefault(NO_BOOT_COUNT)
        memory = WifiMemory(loadSeen(appContext))
        watch(appContext)
    }

    /**
     * Asks Android again: when the app comes on screen or the permission was just given, the name
     * it withheld is given with the next report, and only a new watch gets one at once.
     */
    @Synchronized
    fun refresh() {
        val appContext = app ?: return
        watch(appContext)
    }

    /**
     * [refresh], when the phone is on a Wi-Fi whose name Android withheld: called as the app comes
     * on screen, which is when Android gives it.
     */
    @Synchronized
    fun refreshIfWithheld() {
        if (_state.value.onWifi && _state.value.name == null) refresh()
    }

    /** The Wi-Fi's name, or null when the phone is not on Wi-Fi or Android has not said which. */
    suspend fun name(): String? {
        withTimeoutOrNull(FIRST_REPORT_MS) { reported.await() }
        return _state.value.name
    }

    /** Puts the phone on [state], for the tests: what a report from Android does. */
    internal fun set(state: State) {
        _state.value = state
    }

    /** Whether Android lets the app read a Wi-Fi's name at all. */
    fun mayReadName(context: Context): Boolean =
        ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED

    /** Whether Location is on: with it off, Android withholds the name even with the permission. */
    fun locationOn(context: Context): Boolean =
        context.getSystemService(LocationManager::class.java)?.let(LocationManagerCompat::isLocationEnabled) ?: false

    private fun watch(appContext: Context) {
        val connectivity = appContext.getSystemService(ConnectivityManager::class.java) ?: return
        callback?.let { old -> runCatching { connectivity.unregisterNetworkCallback(old) } }
        val waiting = CompletableDeferred<Unit>()
        reported = waiting
        scope.launch {
            delay(FIRST_REPORT_MS)
            waiting.complete(Unit)
        }
        val fresh = newCallback(appContext)
        callback = fresh
        runCatching { connectivity.registerDefaultNetworkCallback(fresh) }.onFailure {
            callback = null
            waiting.complete(Unit)
        }
    }

    private fun newCallback(appContext: Context): ConnectivityManager.NetworkCallback =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            // From Android 12 the name comes with the network, and only to a callback that asks for it.
            object : ConnectivityManager.NetworkCallback(FLAG_INCLUDE_LOCATION_INFO) {
                override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) =
                    seen(appContext, this, network, capabilities)
                override fun onLost(network: Network) = lost(this, network)
            }
        } else {
            object : ConnectivityManager.NetworkCallback() {
                override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) =
                    seen(appContext, this, network, capabilities)
                override fun onLost(network: Network) = lost(this, network)
            }
        }

    @Synchronized
    private fun seen(appContext: Context, from: ConnectivityManager.NetworkCallback, network: Network, capabilities: NetworkCapabilities) {
        if (from !== callback) return
        val onWifi = capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) &&
            !capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
        val name = if (onWifi) {
            val before = memory.seen
            memory.name(boot, network.networkHandle, reportedName(appContext, capabilities))
                .also { if (memory.seen != before) saveSeen(appContext, memory.seen) }
        } else {
            null
        }
        current = network.networkHandle
        _state.value = State(onWifi, name)
        reported.complete(Unit)
    }

    @Synchronized
    private fun lost(from: ConnectivityManager.NetworkCallback, network: Network) {
        if (from !== callback || current != network.networkHandle) return
        current = null
        _state.value = State()
    }

    private fun reportedName(appContext: Context, capabilities: NetworkCapabilities): String? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            (capabilities.transportInfo as? WifiInfo)?.ssid
        } else {
            @Suppress("DEPRECATION")
            runCatching { appContext.getSystemService(WifiManager::class.java)?.connectionInfo?.ssid }.getOrNull()
        }

    private fun loadSeen(appContext: Context): WifiMemory.Seen? {
        if (boot == NO_BOOT_COUNT) return null
        val prefs = appContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val name = prefs.getString(KEY_NAME, null) ?: return null
        return WifiMemory.Seen(prefs.getInt(KEY_BOOT, NO_BOOT_COUNT), prefs.getLong(KEY_CONNECTION, 0), name)
            .takeIf { it.boot == boot }
    }

    private fun saveSeen(appContext: Context, seen: WifiMemory.Seen?) {
        // Without a count of the phone's starts, a kept connection could be mistaken for a later one.
        if (boot == NO_BOOT_COUNT || seen == null) return
        appContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putInt(KEY_BOOT, seen.boot).putLong(KEY_CONNECTION, seen.connection).putString(KEY_NAME, seen.name)
            .apply()
    }

    private const val FIRST_REPORT_MS = 400L
    private const val NO_BOOT_COUNT = -1
    private const val PREFS = "current_wifi"
    private const val KEY_BOOT = "boot"
    private const val KEY_CONNECTION = "connection"
    private const val KEY_NAME = "name"
}
