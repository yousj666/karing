package io.nebula.vpn_service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import java.io.File
import java.util.concurrent.CopyOnWriteArrayList

/**
 * ServiceStateBus — the plugin-wide source of truth for the VPN lifecycle
 * state. Values are the Dart `FlutterVpnServiceState` names verbatim
 * (design doc §2.1/§2.5): disconnected, connecting, connected,
 * disconnecting, reasserting (Apple only), invalid.
 *
 * [BoxVpnService] emits; [VpnServicePlugin] forwards to the event channel.
 */
object ServiceStateBus {
    @Volatile
    var state: String = "disconnected"
        private set

    /** Last core start error, for the wrapper's error display. */
    @Volatile
    var lastError: String? = null

    private val listeners = CopyOnWriteArrayList<(String) -> Unit>()

    fun addListener(listener: (String) -> Unit) {
        listeners.add(listener)
    }

    fun removeListener(listener: (String) -> Unit) {
        listeners.remove(listener)
    }

    fun emit(newState: String) {
        state = newState
        for (listener in listeners) {
            listener(newState)
        }
    }
}

/**
 * BoxVpnService — the Android VpnService that owns the tun and hosts the
 * sing-box core (via [LibboxBridge]) in-process (design doc §3.1).
 *
 * Lifecycle:
 *  - ACTION_START (+ EXTRA_CONFIG_PATH): foreground immediately, then
 *    read the config file the app wrote and start/reload the core.
 *  - ACTION_STOP: close the core, drop the tun, stop self.
 *  - onRevoke (system/user revoked VPN consent): same as ACTION_STOP.
 *
 * The instance registers itself in [instance] so
 * [PlatformInterfaceImpl.openTun] / `autoDetectInterfaceControl` can
 * reach the OS-managed object.
 */
class BoxVpnService : VpnService() {

    companion object {
        const val ACTION_START = "io.nebula.vpn_service.action.START"
        const val ACTION_STOP = "io.nebula.vpn_service.action.STOP"
        const val EXTRA_CONFIG_PATH = "configPath"

        private const val NOTIFICATION_ID = 1
        private const val NOTIFICATION_CHANNEL_ID = "vpn_service"

        @Volatile
        var instance: BoxVpnService? = null
            private set
    }

    private val platformInterface = PlatformInterfaceImpl()

    private var tunFd: ParcelFileDescriptor? = null

    private val commandHandler = object : LibboxBridge.CoreCommandHandler {
        override fun onServiceStopRequested() {
            stopCore()
            stopSelf()
        }

        override fun onServiceReloadRequested() {
            // The wrapper drives reloads through the channel (it owns the
            // config file); a core-initiated reload request just re-reads
            // the last started config.
            val path = lastConfigPath
            if (path != null) {
                startCore(path)
            }
        }

        override fun onWriteDebugMessage(message: String) {
            // Phase 2: forward to the event channel's log stream (§2.1).
        }
    }

    @Volatile
    private var lastConfigPath: String? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopCore()
                stopSelf()
                return START_NOT_STICKY
            }
            else -> {
                // ACTION_START, or null (system restart / always-on):
                // a VpnService must go foreground promptly after start.
                startForeground(NOTIFICATION_ID, buildNotification())
                val path = intent?.getStringExtra(EXTRA_CONFIG_PATH) ?: lastConfigPath
                if (path != null) {
                    // Core start blocks until the instance is up
                    // (libbox waits for started), so keep it off the
                    // main thread; state flows through ServiceStateBus.
                    Thread { startCore(path) }.start()
                } else {
                    // Always-on restart with no known config: nothing to
                    // run yet; the app will start us properly.
                    ServiceStateBus.emit("disconnected")
                }
                return START_STICKY
            }
        }
    }

    override fun onRevoke() {
        stopCore()
        stopSelf()
        super.onRevoke()
    }

    override fun onDestroy() {
        if (instance === this) {
            instance = null
        }
        closeTun()
        super.onDestroy()
    }

    // -- core lifecycle -------------------------------------------------

    private fun startCore(configPath: String) {
        lastConfigPath = configPath
        ServiceStateBus.emit("connecting")
        val content = try {
            File(configPath).readText()
        } catch (e: Exception) {
            ServiceStateBus.lastError = e.message ?: e.toString()
            ServiceStateBus.emit("invalid")
            return
        }
        if (!LibboxBridge.isSetup) {
            val workingDir = File(filesDir, "sing-box").apply { mkdirs() }
            LibboxBridge.setup(
                basePath = filesDir.absolutePath,
                workingPath = workingDir.absolutePath,
                tempPath = cacheDir.absolutePath,
                // Port 0 -> libbox serves its command channel on a Unix
                // socket under the working path (design doc §1.2); the
                // in-process bridge does not need the TCP listener.
                commandServerPort = 0,
                commandServerSecret = "",
                logMaxLines = 1000,
                debug = false,
                localeId = "",
                handler = commandHandler,
                platform = platformInterface,
            )
        }
        val error = LibboxBridge.startOrReloadService(content)
        if (error == null) {
            ServiceStateBus.lastError = null
            ServiceStateBus.emit("connected")
        } else {
            ServiceStateBus.lastError = error
            ServiceStateBus.emit("invalid")
        }
    }

    private fun stopCore() {
        ServiceStateBus.emit("disconnecting")
        LibboxBridge.closeService()
        closeTun()
        ServiceStateBus.emit("disconnected")
    }

    // -- tun (called back by the core through PlatformInterfaceImpl) ----

    /**
     * Realise [spec] with a [Builder] and hand the detached FD to the
     * core. Returns -1 on failure (see libbox `OpenTun`, design doc §3.2).
     */
    fun establishTun(spec: TunSpec): Int {
        closeTun()
        val builder = Builder()
            .setSession("Yousj Enhanced")
            .setMtu(if (spec.mtu > 0) spec.mtu else 1500)
        for (cidr in spec.inet4Addresses + spec.inet6Addresses) {
            val parsed = parseCidr(cidr) ?: continue
            builder.addAddress(parsed.first, parsed.second)
        }
        if (spec.autoRoute) {
            var hasV4Route = false
            var hasV6Route = false
            for (cidr in spec.inet4RouteAddresses) {
                val parsed = parseCidr(cidr) ?: continue
                builder.addRoute(parsed.first, parsed.second)
                hasV4Route = true
            }
            for (cidr in spec.inet6RouteAddresses) {
                val parsed = parseCidr(cidr) ?: continue
                builder.addRoute(parsed.first, parsed.second)
                hasV6Route = true
            }
            // No explicit routes: capture everything we have addresses for.
            // (Route *excludes* have no Builder API before API 33's
            // excludeRoute; strict-route exclusion refinements land with
            // the .aar, design doc §3.2.)
            if (!hasV4Route && spec.inet4Addresses.isNotEmpty()) {
                builder.addRoute("0.0.0.0", 0)
            }
            if (!hasV6Route && spec.inet6Addresses.isNotEmpty()) {
                builder.addRoute("::", 0)
            }
        }
        if (!spec.dnsServer.isNullOrEmpty()) {
            try {
                builder.addDnsServer(spec.dnsServer)
            } catch (e: IllegalArgumentException) {
                // Not a literal IP — the core falls back to its own DNS.
            }
        }
        for (pkg in spec.includePackages) {
            try {
                builder.addAllowedApplication(pkg)
            } catch (e: Exception) {
                // Unknown package: skip it, don't fail the whole tun.
            }
        }
        for (pkg in spec.excludePackages) {
            try {
                builder.addDisallowedApplication(pkg)
            } catch (e: Exception) {
                // As above.
            }
        }
        val fd = builder.establish() ?: return -1
        tunFd = fd
        return fd.detachFd()
    }

    /** `VpnService.protect` passthrough for the core's outbound sockets. */
    fun protectSocket(fd: Int): Boolean = protect(fd)

    private fun closeTun() {
        try {
            tunFd?.close()
        } catch (e: Exception) {
            // Already closed/detached — nothing to do.
        }
        tunFd = null
    }

    private fun parseCidr(cidr: String): Pair<String, Int>? {
        val parts = cidr.split("/", limit = 2)
        if (parts.isEmpty() || parts[0].isEmpty()) {
            return null
        }
        val prefix = if (parts.size == 2) parts[1].toIntOrNull() ?: return null else {
            if (parts[0].contains(":")) 128 else 32
        }
        return parts[0] to prefix
    }

    // -- foreground notification ----------------------------------------

    private fun buildNotification(): Notification {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(NotificationManager::class.java)
            if (manager.getNotificationChannel(NOTIFICATION_CHANNEL_ID) == null) {
                manager.createNotificationChannel(
                    NotificationChannel(
                        NOTIFICATION_CHANNEL_ID,
                        "VPN",
                        NotificationManager.IMPORTANCE_LOW,
                    )
                )
            }
        }
        @Suppress("DEPRECATION")
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, NOTIFICATION_CHANNEL_ID)
        } else {
            Notification.Builder(this)
        }
        val icon = if (applicationInfo.icon != 0) {
            applicationInfo.icon
        } else {
            android.R.drawable.ic_dialog_info
        }
        return builder
            .setContentTitle("Yousj Enhanced")
            .setContentText("VPN is running")
            .setSmallIcon(icon)
            .build()
    }
}
