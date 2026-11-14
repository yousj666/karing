package io.nebula.vpn_service

import android.util.Base64
import java.net.NetworkInterface
import java.security.KeyStore

/**
 * TunSpec — the tun parameters the core asks the platform to realise,
 * mirrored 1:1 from libbox's `TunOptions` interface
 * (KaringX/sing-box `experimental/libbox/tun.go`; design doc §1.2).
 * Addresses and routes are CIDR strings ("10.0.0.2/28", "2000::/3").
 *
 * When libbox.aar lands, the adapter in LibboxBridge fills this from the
 * generated `io.nekohasekai.libbox.TunOptions` iterators; nothing else
 * changes.
 */
data class TunSpec(
    val inet4Addresses: List<String> = emptyList(),
    val inet6Addresses: List<String> = emptyList(),
    val dnsServer: String? = null,
    val mtu: Int = 1500,
    val autoRoute: Boolean = true,
    val strictRoute: Boolean = false,
    val inet4RouteAddresses: List<String> = emptyList(),
    val inet6RouteAddresses: List<String> = emptyList(),
    val inet4RouteExcludeAddresses: List<String> = emptyList(),
    val inet6RouteExcludeAddresses: List<String> = emptyList(),
    val includePackages: List<String> = emptyList(),
    val excludePackages: List<String> = emptyList(),
)

/** Minimal Wi-Fi snapshot, mirroring libbox's `WIFIState`. */
data class WifiState(val ssid: String?, val bssid: String?)

/** Minimal interface snapshot, mirroring libbox's `NetworkInterface`. */
data class NetworkInterfaceInfo(
    val name: String,
    val index: Int,
    val mtu: Int,
    val addresses: List<String>, // CIDR strings
)

/**
 * Host-side callbacks the core drives — the shape of libbox's
 * `PlatformInterface` (KaringX/sing-box `experimental/libbox/platform.go`;
 * design doc §1.2), expressed with plain Kotlin types.
 *
 * When libbox.aar lands this class additionally implements
 * `io.nekohasekai.libbox.PlatformInterface`; the bodies below stay as-is,
 * only the interface and the TunOptions→TunSpec adapter are added
 * (in LibboxBridge).
 *
 * Tun ownership: the tun is created by [VpnServiceImpl] (the OS-managed
 * VpnService instance, registered in [VpnServiceImpl.instance]); this class
 * delegates to it.
 */
class PlatformInterfaceImpl {

    /**
     * libbox `OpenTun(options) -> fd`. Delegates to the running
     * [VpnServiceImpl]; -1 if the service is not up (core treats it as an
     * open failure).
     */
    fun openTun(spec: TunSpec): Int {
        val service = VpnServiceImpl.instance ?: return -1
        return service.establishTun(spec)
    }

    /**
     * libbox `AutoDetectInterfaceControl(fd)`: on Android this is
     * `VpnService.protect(fd)` — without it the core's own outbound
     * sockets loop back into the tun.
     */
    fun autoDetectInterfaceControl(fd: Int): Boolean {
        val service = VpnServiceImpl.instance ?: return false
        return service.protectSocket(fd)
    }

    fun usePlatformAutoDetectInterfaceControl(): Boolean = true

    /** Android goes through /proc only via libbox's own wrapper; the Java side declines. */
    fun useProcFS(): Boolean = false

    fun underNetworkExtension(): Boolean = false

    fun includeAllNetworks(): Boolean = false

    /** No public Android API to flush the system DNS cache; the core re-resolves instead. */
    fun clearDNSCache() {
        // Intentionally empty (platform limitation, design doc §3).
    }

    /**
     * libbox `SystemCertificates()`: the device CA store as PEM strings —
     * the core uses these as its root pool when the config asks for the
     * platform store.
     */
    fun systemCertificates(): List<String> {
        val certs = mutableListOf<String>()
        try {
            val keyStore = KeyStore.getInstance("AndroidCAStore")
            keyStore.load(null, null)
            val aliases = keyStore.aliases()
            while (aliases.hasMoreElements()) {
                val cert = keyStore.getCertificate(aliases.nextElement()) ?: continue
                val b64 = Base64.encodeToString(cert.encoded, Base64.NO_WRAP)
                val pem = buildString {
                    append("-----BEGIN CERTIFICATE-----\n")
                    append(b64.chunked(64).joinToString("\n"))
                    append("\n-----END CERTIFICATE-----")
                }
                certs.add(pem)
            }
        } catch (e: Exception) {
            // Best effort: an empty pool makes the core fall back to its
            // bundled roots; never crash the tun bring-up over this.
        }
        return certs
    }

    /**
     * libbox `GetInterfaces()`: snapshot from `java.net.NetworkInterface`.
     * Interface *type* (wifi/cellular) is not derivable here — the
     * default-interface monitor (below) is what the core actually keys
     * off; types are refined when that lands.
     */
    fun getInterfaces(): List<NetworkInterfaceInfo> {
        val result = mutableListOf<NetworkInterfaceInfo>()
        val interfaces = NetworkInterface.getNetworkInterfaces() ?: return result
        for (ni in interfaces.toList()) {
            val addresses = ni.interfaceAddresses.mapNotNull { ia ->
                val host = ia.address.hostAddress ?: return@mapNotNull null
                "$host/${ia.networkPrefixLength}"
            }
            result.add(NetworkInterfaceInfo(ni.name, ni.index, ni.mtu, addresses))
        }
        return result
    }

    // TODO(R4-CORE): default interface monitor — implement with
    // ConnectivityManager.registerDefaultNetworkCallback and report
    // (name, index, isExpensive, isConstrained) changes to the core's
    // InterfaceUpdateListener (design doc §1.2). Stubbed until the .aar
    // lands because the listener type comes from the generated bindings.
    fun startDefaultInterfaceMonitor() {}
    fun closeDefaultInterfaceMonitor() {}

    // TODO(R4-CORE): FindConnectionOwner — Android 10+ restricts the
    // procfs/connectivity-diagnostics routes this needs; return null
    // (unknown owner) in v1, matching libbox's "not found" behaviour.
    fun findConnectionOwner(
        ipProtocol: Int,
        sourceAddress: String,
        sourcePort: Int,
        destinationAddress: String,
        destinationPort: Int,
    ): String? = null

    // TODO(R4-CORE): ReadWIFIState — needs ACCESS_FINE_LOCATION /
    // NEARBY_WIFI_DEVICES at runtime; v1 reports unknown.
    fun readWIFIState(): WifiState? = null

    // TODO(R4-CORE): SendNotification — post via VpnServiceImpl's
    // notification channel when the core raises user-facing notices.
    fun sendNotification(title: String, body: String) {}
}
