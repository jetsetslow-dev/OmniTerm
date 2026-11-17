package com.jetsetslow.omniterm.data.tunnel

import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import com.jetsetslow.omniterm.gotunnel.omnitunnel.Omnitunnel
import java.io.File
import java.net.NetworkInterface

/**
 * The phone's network, as Tailscale tunnels need it. Android closes netlink to apps, so Go cannot
 * list the interfaces itself: the list comes from here, the way the Tailscale Android app
 * (tailscale/tailscale-android, BSD-3-Clause) does it, and so does the interface Android's
 * connections go over, which changes as the phone moves between networks.
 */
object TailscaleNetwork {
    /** One interface, as [describe] writes it for the Go library (tunnel/omnitunnel/network.go). */
    data class Iface(
        val name: String,
        val index: Int,
        val mtu: Int,
        val up: Boolean,
        val loopback: Boolean,
        val pointToPoint: Boolean,
        val multicast: Boolean,
        /** Each address with its prefix length, as "address/bits". */
        val addresses: List<String>,
    )

    @Volatile private var app: Context? = null
    @Volatile private var defaultInterface: String = ""
    private var callback: ConnectivityManager.NetworkCallback? = null
    @Volatile private var registered = false
    /** Whether starts have registered the shared Go bridge; both node kinds need it. */
    internal val followingChanges: Boolean get() = registered

    /** Where tunnel [id] keeps what it writes that is no secret; deleted with the tunnel. */
    fun scratch(id: Int): File {
        val root = app?.noBackupFilesDir ?: File(System.getProperty("java.io.tmpdir") ?: ".")
        return File(root, "tunnels/node-$id")
    }

    /** Starts following which interface the phone's connections go over. Safe to call again. */
    @Synchronized
    fun start(context: Context) {
        if (app != null) return
        val appContext = context.applicationContext
        app = appContext
        val connectivity = appContext.getSystemService(ConnectivityManager::class.java) ?: return
        val fresh = object : ConnectivityManager.NetworkCallback() {
            override fun onLinkPropertiesChanged(network: Network, linkProperties: LinkProperties) =
                moved(linkProperties.interfaceName.orEmpty())
            override fun onLost(network: Network) = moved("")
        }
        if (runCatching { connectivity.registerDefaultNetworkCallback(fresh) }.isSuccess) callback = fresh
    }

    private fun moved(name: String) {
        if (name == defaultInterface) return
        defaultInterface = name
        // Only once a node tunnel (Tailscale or Nebula) has registered the shared Go bridge.
        if (registered) runCatching { Omnitunnel.networkChanged(name) }
    }

    /** Hands the interfaces, and the one in use, to the Go library before a Tailscale tunnel starts. */
    @Synchronized
    internal fun tellGo() {
        if (!registered) {
            Omnitunnel.setNetwork { describe(interfaces()) }
            registered = true
        }
        Omnitunnel.networkChanged(defaultInterface)
    }

    /** Deletes tunnel [id]'s folder. */
    fun forget(id: Int) {
        runCatching { scratch(id).deleteRecursively() }
    }

    private fun interfaces(): List<Iface> = runCatching {
        NetworkInterface.getNetworkInterfaces()?.toList().orEmpty().map { nif ->
            Iface(
                name = nif.name,
                index = nif.index,
                mtu = runCatching { nif.mtu }.getOrDefault(0),
                up = runCatching { nif.isUp }.getOrDefault(false),
                loopback = runCatching { nif.isLoopback }.getOrDefault(false),
                pointToPoint = runCatching { nif.isPointToPoint }.getOrDefault(false),
                multicast = runCatching { nif.supportsMulticast() }.getOrDefault(false),
                addresses = nif.interfaceAddresses.mapNotNull { ia ->
                    ia.address?.hostAddress?.substringBefore('%')?.let { "$it/${ia.networkPrefixLength}" }
                },
            )
        }
    }.getOrDefault(emptyList())

    /** [list] in the Go library's form: one line per interface, fields split by spaces. */
    fun describe(list: List<Iface>): String = list
        .filter { it.name.isNotBlank() && it.name.none(Char::isWhitespace) }
        .joinToString("\n") { i ->
            val flags = buildString {
                if (i.up) append('u')
                if (i.loopback) append('l')
                if (i.pointToPoint) append('p')
                if (i.multicast) append('m')
            }.ifEmpty { "-" }
            "${i.name} ${i.index} ${i.mtu} $flags ${i.addresses.joinToString(",").ifEmpty { "-" }}"
        }
}
