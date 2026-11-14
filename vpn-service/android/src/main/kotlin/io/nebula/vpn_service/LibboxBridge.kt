package io.nebula.vpn_service

/**
 * LibboxBridge — the SOLE touchpoint between this plugin and the sing-box
 * Go core (KaringX/sing-box, package `experimental/libbox`).
 *
 * Everything else in the plugin (VpnServicePlugin, BoxVpnService,
 * PlatformInterfaceImpl) talks to the core only through this object and
 * through plain Kotlin types, so the plugin compiles and its channel /
 * service plumbing can be exercised before the core exists.
 *
 * Current state: every body is a TODO(R4-CORE) stub. The real calls are
 * written out in the comments — they are the verified gomobile-generated
 * Java API of `io.nekohasekai.libbox` (see the design doc,
 * goals/karing-fork/hidden_files/r4-native-design.md §1.2). To go live:
 *   1. build libbox.aar (design doc §1.3) and drop it in android/libs/,
 *   2. uncomment the dependency in android/build.gradle,
 *   3. replace each stub body with the commented call and make
 *      [PlatformInterfaceImpl] implement
 *      `io.nekohasekai.libbox.PlatformInterface` and [CoreCommandHandler]
 *      implement `io.nekohasekai.libbox.CommandServerHandler`.
 * No other file needs to change.
 */
object LibboxBridge {

    /** Callbacks the core (via CommandServerHandler) sends to the host. */
    interface CoreCommandHandler {
        /** Core asks the host to stop the VPN service entirely. */
        fun onServiceStopRequested()

        /** Core asks the host to reload (wrapper re-reads config + startOrReload). */
        fun onServiceReloadRequested()

        /** Debug log line from the core. */
        fun onWriteDebugMessage(message: String)
    }

    @Volatile
    var isSetup: Boolean = false
        private set

    @Volatile
    private var commandHandler: CoreCommandHandler? = null

    @Volatile
    private var systemProxyEnabled: Boolean = false

    /**
     * One-time core initialisation (design doc §1.2, libbox `Setup`).
     *
     * Real implementation:
     * ```
     * val options = io.nekohasekai.libbox.SetupOptions()
     * options.basePath = basePath
     * options.workingPath = workingPath
     * options.tempPath = tempPath
     * options.fixAndroidStack = true
     * options.commandServerListenPort = commandServerPort
     * options.commandServerSecret = commandServerSecret
     * options.logMaxLines = logMaxLines
     * options.debug = debug
     * io.nekohasekai.libbox.Libbox.setup(options)
     * io.nekohasekai.libbox.Libbox.setLocale(localeId)
     * ```
     */
    fun setup(
        basePath: String,
        workingPath: String,
        tempPath: String,
        commandServerPort: Int,
        commandServerSecret: String,
        logMaxLines: Int,
        debug: Boolean,
        localeId: String,
        handler: CoreCommandHandler,
        platform: PlatformInterfaceImpl,
    ) {
        // TODO(R4-CORE): Libbox.setup(...) as above, then create the command
        // server (kept in a field):
        //   commandServer = Libbox.newCommandServer(handlerAdapter, platform)
        //   commandServer.start()
        // handlerAdapter wraps [handler] as a CommandServerHandler:
        //   ServiceStop()        -> handler.onServiceStopRequested()
        //   ServiceReload()      -> handler.onServiceReloadRequested()
        //   GetSystemProxyStatus -> Android: always disabled (no system proxy)
        //   SetSystemProxyEnabled-> Android: no-op success
        //   WriteDebugMessage(m) -> handler.onWriteDebugMessage(m)
        commandHandler = handler
        isSetup = true
    }

    /** Core version string (`libbox.Version()`), "" until the .aar lands. */
    fun version(): String {
        // TODO(R4-CORE): return Libbox.version()
        return ""
    }

    /**
     * Start the core with [configContent], or hot-swap the running instance
     * (libbox `CommandServer.StartOrReloadService` — one call does both).
     *
     * @return null on success, the core's error message on failure.
     */
    fun startOrReloadService(configContent: String): String? {
        // TODO(R4-CORE):
        //   try {
        //       commandServer.startOrReloadService(configContent,
        //           io.nekohasekai.libbox.OverrideOptions())
        //       null
        //   } catch (e: Exception) { e.message ?: e.toString() }
        return "libbox core not built yet (R4-CORE)"
    }

    /**
     * Stop the running core instance (libbox `CommandServer.CloseService`).
     * The command server itself keeps listening so a later
     * [startOrReloadService] works without re-setup.
     *
     * @return null on success, an error message on failure.
     */
    fun closeService(): String? {
        // TODO(R4-CORE): commandServer.closeService() with the same
        // try/catch -> error-message mapping as startOrReloadService.
        return null
    }

    /** Full teardown: close the instance and the command server. */
    fun shutdown() {
        // TODO(R4-CORE): commandServer.closeService(); commandServer.close()
        commandHandler = null
        isSetup = false
    }

    /** Android has no app-controllable system proxy; kept for the handler contract. */
    fun getSystemProxyEnabled(): Boolean = systemProxyEnabled

    fun setSystemProxyEnabled(enabled: Boolean): String? {
        systemProxyEnabled = enabled
        return null
    }
}
