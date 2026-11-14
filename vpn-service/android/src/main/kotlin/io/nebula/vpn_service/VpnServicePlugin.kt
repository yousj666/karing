package io.nebula.vpn_service

import android.app.Activity
import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.plugin.common.PluginRegistry
import java.io.File

/**
 * VpnServicePlugin — Android native side of the vpn_service plugin.
 *
 * Channel contract: design doc (goals/karing-fork/hidden_files/
 * r4-native-design.md) §2 — reconstruction v1:
 *   MethodChannel "io.nebula.vpn_service/methods"
 *   EventChannel  "io.nebula.vpn_service/events"  (state events)
 *
 * Implements the Android parts of the nine `FlutterVpnService` statics
 * plus the lifecycle methods the app-side wrapper drives
 * (prepareVpn / startService / reloadService / stopService /
 * getServiceState / system-proxy passthrough).
 *
 * The core itself is reached only through [LibboxBridge]; while the
 * libbox .aar is not built yet, starts surface the bridge's
 * "not built" error as state `invalid` + [ServiceStateBus.lastError].
 */
class VpnServicePlugin :
    FlutterPlugin,
    MethodCallHandler,
    ActivityAware,
    EventChannel.StreamHandler,
    PluginRegistry.ActivityResultListener {

    companion object {
        private const val METHOD_CHANNEL = "io.nebula.vpn_service/methods"
        private const val EVENT_CHANNEL = "io.nebula.vpn_service/events"
        private const val REQUEST_VPN_PERMISSION = 4921
    }

    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel

    private var appContext: Context? = null
    private var activity: Activity? = null
    private var eventSink: EventChannel.EventSink? = null

    private val mainHandler = Handler(Looper.getMainLooper())

    /** A startService call parked while the VPN consent dialog is up. */
    private var pendingStartResult: Result? = null
    private var pendingConfigPath: String? = null

    /** A prepareVpn call parked while the VPN consent dialog is up. */
    private var pendingPrepareResult: Result? = null

    private val stateListener: (String) -> Unit = { state ->
        mainHandler.post {
            eventSink?.success(mapOf("type" to "state", "state" to state))
        }
    }

    // -- FlutterPlugin ----------------------------------------------------

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        methodChannel = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL)
        methodChannel.setMethodCallHandler(this)
        eventChannel = EventChannel(binding.binaryMessenger, EVENT_CHANNEL)
        eventChannel.setStreamHandler(this)
        ServiceStateBus.addListener(stateListener)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        ServiceStateBus.removeListener(stateListener)
    }

    // -- ActivityAware ------------------------------------------------------

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivity() {
        activity = null
    }

    // -- EventChannel.StreamHandler ----------------------------------------

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        // Replay the current state so late subscribers sync immediately.
        events?.success(mapOf("type" to "state", "state" to ServiceStateBus.state))
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    // -- consent flow --------------------------------------------------------

    override fun onActivityResult(
        requestCode: Int,
        resultCode: Int,
        data: Intent?,
    ): Boolean {
        if (requestCode != REQUEST_VPN_PERMISSION) {
            return false
        }
        val granted = resultCode == Activity.RESULT_OK
        pendingPrepareResult?.let { prepareResult ->
            pendingPrepareResult = null
            prepareResult.success(granted)
            return true
        }
        val result = pendingStartResult
        val configPath = pendingConfigPath
        pendingStartResult = null
        pendingConfigPath = null
        if (granted && configPath != null) {
            dispatchStart(configPath)
            result?.success(null)
        } else {
            ServiceStateBus.emit("invalid")
            ServiceStateBus.emit("disconnected")
            result?.success(mapOf("message" to "vpn permission denied"))
        }
        return true
    }

    // -- MethodCallHandler ---------------------------------------------------

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            // The nine FlutterVpnService statics (design doc §2.2).
            "getSystemVersion" ->
                result.success("Android ${Build.VERSION.RELEASE}")

            "setExcludeFromRecents" -> {
                val exclude = call.argument<Boolean>("exclude") ?: false
                try {
                    val am = appContext?.getSystemService(ActivityManager::class.java)
                    am?.appTasks?.forEach { it.setExcludeFromRecents(exclude) }
                    result.success(null)
                } catch (e: Exception) {
                    // Dart returns this string verbatim to an alert dialog.
                    result.success(e.message ?: e.toString())
                }
            }

            // Desktop-only concepts; Android has no privileged helper
            // service, so both report the "authorized" steady state the
            // call sites expect (design doc §2.2).
            "isServiceAuthorized" -> result.success(true)
            "authorizeService" -> result.success(null)

            // Windows-only.
            "firewallAddPorts" -> result.success(null)

            "setAlwaysOn" -> {
                // Apps cannot flip the system always-on flag; send the
                // user to the system VPN settings where our service's
                // SUPPORTS_ALWAYS_ON declaration makes it pinnable
                // (design doc §2.2/§3.3).
                try {
                    activity?.startActivity(Intent(Settings.ACTION_VPN_SETTINGS))
                } catch (e: Exception) {
                    // Settings entry missing on this ROM — nothing to do.
                }
                result.success(null)
            }

            // macOS-only.
            "hideDockIcon" -> result.success(null)

            // Apple-only.
            "getAppGroupDirectory" -> result.success(null)

            "clashiApiConnections" -> {
                // Design doc §2.3: v1 reads the core's Clash API over
                // loopback HTTP. The controller address/secret are pinned
                // by the config builder; until that wiring lands, report
                // "no data" ('') exactly as the Dart stub does.
                // TODO(R4-CORE): GET http://127.0.0.1:<clashPort>/connections
                // (+ /proxies when includeProxies) with the pinned secret.
                result.success("")
            }

            // Lifecycle (design doc §2.4).
            "prepareVpn" -> prepareVpn(result)
            "startService" -> startOrReload(call.argument<String>("configPath"), result)
            "reloadService" -> startOrReload(call.argument<String>("configPath"), result)
            "stopService" -> {
                val context = appContext
                if (context != null && BoxVpnService.instance != null) {
                    val intent = Intent(context, BoxVpnService::class.java)
                        .setAction(BoxVpnService.ACTION_STOP)
                    context.startService(intent)
                } else {
                    ServiceStateBus.emit("disconnected")
                }
                result.success(null)
            }

            "getServiceState" -> result.success(ServiceStateBus.state)

            "getSystemProxyStatus" -> result.success(false)
            "setSystemProxyEnabled" -> result.success(null)

            else -> result.notImplemented()
        }
    }

    // -- start plumbing ------------------------------------------------------

    private fun prepareVpn(result: Result) {
        val context = appContext
        if (context == null) {
            result.success(false)
            return
        }
        val prepareIntent = VpnService.prepare(context)
        if (prepareIntent == null) {
            result.success(true)
            return
        }
        val act = activity
        if (act == null) {
            result.success(false)
            return
        }
        pendingPrepareResult = result
        act.startActivityForResult(prepareIntent, REQUEST_VPN_PERMISSION)
    }

    private fun startOrReload(configPath: String?, result: Result) {
        val context = appContext
        if (context == null || configPath == null) {
            result.success(mapOf("message" to "missing configPath"))
            return
        }
        if (BoxVpnService.instance != null) {
            // Service (and tun) already up: hot-swap the core config
            // in-process — libbox StartOrReloadService does exactly this,
            // and it blocks until the new instance is up, so answer the
            // result synchronously with the real outcome.
            val content = try {
                File(configPath).readText()
            } catch (e: Exception) {
                result.success(mapOf("message" to (e.message ?: e.toString())))
                return
            }
            ServiceStateBus.emit("connecting")
            val error = LibboxBridge.startOrReloadService(content)
            if (error == null) {
                ServiceStateBus.lastError = null
                ServiceStateBus.emit("connected")
                result.success(null)
            } else {
                ServiceStateBus.lastError = error
                ServiceStateBus.emit("invalid")
                result.success(mapOf("message" to error))
            }
            return
        }
        // Cold start: consent first (design doc §3.3).
        val prepareIntent = VpnService.prepare(context)
        if (prepareIntent == null) {
            dispatchStart(configPath)
            result.success(null)
            return
        }
        val act = activity
        if (act == null) {
            result.success(mapOf("message" to "no activity to request vpn permission"))
            return
        }
        pendingConfigPath = configPath
        pendingStartResult = result
        act.startActivityForResult(prepareIntent, REQUEST_VPN_PERMISSION)
    }

    private fun dispatchStart(configPath: String) {
        val context = appContext ?: return
        val intent = Intent(context, BoxVpnService::class.java)
            .setAction(BoxVpnService.ACTION_START)
            .putExtra(BoxVpnService.EXTRA_CONFIG_PATH, configPath)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.startForegroundService(intent)
        } else {
            context.startService(intent)
        }
    }
}
