package com.nebula.karing

import android.app.Activity
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.Collections

// yousj-plus (v1.0.7): bridge for the bundled frpc reverse tunnel.
//
// frpc (fatedier/frp v0.62.1, official linux/arm64 build) ships inside
// the APK as a JNI library, lib/arm64-v8a/libfrpc.so — NOT as an asset
// extracted to the app's data directory: since Android 10, apps
// targeting API 29+ are not allowed to execute binaries stored in their
// (writable) data directory (W^X), while the native library directory
// stays executable. CI downloads the pinned tarball, verifies its
// SHA-256 against frp's official checksums file, and drops the frpc
// binary at android/app/src/main/jniLibs/arm64-v8a/libfrpc.so (kept out
// of git, stripped of debug symbols off — see build.gradle.kts).
// extractNativeLibs=true in the manifest makes it a real file under
// applicationInfo.nativeLibraryDir at install time.
//
// The bridge writes frpc.toml into the app's private files dir and
// runs the process as a child of the app process: when Android kills
// the app, the tunnel dies with it. frpc's own stdout/stderr is
// captured into a small ring buffer; the connection state reported to
// Dart is derived from frpc's actual log lines ("login to server
// success" / "start proxy success" — the literal strings in frp
// v0.62.1), never assumed.
//
// v1.0.8: the tunnel self-heals. The generated config sets
// loginFailExit = false so a failed login never makes frpc give up,
// and this bridge supervises the process: an unexpected exit (network
// drop, frps restart, ...) is restarted with a 5s -> 15s -> 30s -> 60s
// capped backoff until the tunnel is up again. Supervision only runs
// while the Dart side wants the tunnel (API on + tunnel on + a server
// address configured); stop() cancels any pending restart for good.
//
// The frp token only ever lands in the private config file. It is not
// written to any log (ours or, per frp's own logging, frpc's).
object FrpcBridge {
    private const val TAG = "YousjFrpc"
    private const val CHANNEL = "cc.yousj.enhanced/frpc"
    private const val FRPC_LIB_NAME = "libfrpc.so"
    private const val PROXY_NAME = "yousj-external-ai"
    private const val MAX_LOG_LINES = 120
    private const val LOG_TAIL_FOR_UI = 30

    // Restart backoff ladder in seconds; the last value is the cap.
    private val RESTART_BACKOFF_SEC = longArrayOf(5, 15, 30, 60)

    private var channel: MethodChannel? = null
    private var appContext: Context? = null

    @Volatile private var process: Process? = null
    @Volatile private var readerThread: Thread? = null
    @Volatile private var currentFingerprint: String? = null
    @Volatile private var stoppedByUser = false
    @Volatile private var loginOk = false
    @Volatile private var proxyOk = false
    @Volatile private var lastError: String? = null
    @Volatile private var exitCode: Int? = null

    // --- supervision state (v1.0.8) ---
    // wantRunning mirrors the Dart side's intent: true after a start()
    // with a non-blank server address, false after stop() or a blank
    // address. lastConfig is what the supervisor restarts with.
    @Volatile private var wantRunning = false
    @Volatile private var lastConfig: Config? = null
    @Volatile private var retryCount = 0
    @Volatile private var restartPending = false
    @Volatile private var nextRetryDelaySec = 0L
    private val mainHandler = Handler(Looper.getMainLooper())
    @Volatile private var pendingRestart: Runnable? = null

    private data class Config(
        val serverAddr: String,
        val serverPort: Int,
        val remotePort: Int,
        val localPort: Int,
        val token: String,
    )

    private val logLines: MutableList<String> =
        Collections.synchronizedList(mutableListOf())

    fun register(flutterEngine: FlutterEngine, activity: Activity) {
        appContext = activity.applicationContext
        if (channel != null) {
            return
        }
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    val serverAddr = call.argument<String>("serverAddr") ?: ""
                    val serverPort = call.argument<Int>("serverPort") ?: 0
                    val remotePort = call.argument<Int>("remotePort") ?: 0
                    val localPort = call.argument<Int>("localPort") ?: 18777
                    val token = call.argument<String>("token") ?: ""
                    start(serverAddr, serverPort, remotePort, localPort, token)
                    result.success(status())
                }
                "stop" -> {
                    stop()
                    result.success(status())
                }
                "status" -> result.success(status())
                else -> result.notImplemented()
            }
        }
        channel = ch
    }

    // --- lifecycle -----------------------------------------------------------

    private fun frpcBinary(ctx: Context): File =
        File(ctx.applicationInfo.nativeLibraryDir, FRPC_LIB_NAME)

    private fun fingerprint(cfg: Config): String =
        // The token contributes only its hash, so the fingerprint can be
        // kept/compared without holding another copy of the secret.
        "${cfg.serverAddr}|${cfg.serverPort}|${cfg.remotePort}|${cfg.localPort}|${cfg.token.hashCode()}"

    @Synchronized
    private fun start(
        serverAddr: String,
        serverPort: Int,
        remotePort: Int,
        localPort: Int,
        token: String,
    ) {
        if (serverAddr.isBlank()) {
            // Not configured: never start, never supervise. (The Dart
            // side checks this first and calls stop(); this is the
            // defensive twin of that check.)
            wantRunning = false
            lastError = "服务器地址为空"
            return
        }
        val cfg = Config(serverAddr, serverPort, remotePort, localPort, token)
        lastConfig = cfg
        wantRunning = true
        retryCount = 0
        nextRetryDelaySec = 0
        cancelPendingRestartLocked()
        startLocked(cfg)
    }

    // Start (or restart) the frpc process for [cfg]. Caller holds the
    // object lock. A same-fingerprint process that is already alive is
    // left alone, so repeated applyFromConfig() calls are cheap no-ops.
    @Synchronized
    private fun startLocked(cfg: Config) {
        val ctx = appContext ?: return
        val fp = fingerprint(cfg)
        val alive = process?.isAlive == true
        if (alive && currentFingerprint == fp) {
            return
        }
        stopLocked()
        loginOk = false
        proxyOk = false
        lastError = null
        exitCode = null
        stoppedByUser = false

        val binary = frpcBinary(ctx)
        if (!binary.exists()) {
            lastError = "安装包内未找到 frpc（此架构未内置）"
            Log.w(TAG, "frpc binary missing at ${binary.path}")
            return
        }

        val configFile: File = try {
            val dir = File(ctx.filesDir, "frpc")
            if (!dir.exists()) {
                dir.mkdirs()
            }
            val file = File(dir, "frpc.toml")
            file.writeText(buildConfig(cfg))
            file
        } catch (e: Exception) {
            lastError = "写通道配置失败：${e.message}"
            Log.w(TAG, "write frpc.toml failed: ${e.message}")
            return
        }

        val proc: Process = try {
            ProcessBuilder(binary.absolutePath, "-c", configFile.absolutePath)
                .directory(ctx.filesDir)
                .redirectErrorStream(true)
                .start()
        } catch (e: Exception) {
            lastError = "启动 frpc 失败：${e.message}"
            Log.w(TAG, "start frpc failed: ${e.message}")
            return
        }
        process = proc
        currentFingerprint = fp
        Log.i(
            TAG,
            "frpc started (server=${cfg.serverAddr}:${cfg.serverPort} remotePort=${cfg.remotePort})",
        )
        val thread = Thread {
            try {
                proc.inputStream.bufferedReader().forEachLine { line -> addLogLine(line) }
            } catch (e: Exception) {
                // Stream closed because the process was destroyed — fine.
            }
            val code: Int? = try {
                proc.waitFor()
            } catch (e: Exception) {
                null
            }
            synchronized(this@FrpcBridge) {
                if (process === proc) {
                    exitCode = code
                    process = null
                    if (!stoppedByUser && loginOk.not() && lastError == null) {
                        lastError = "frpc 已退出（代码 ${code ?: "?"}）"
                    }
                    if (!stoppedByUser) {
                        Log.w(TAG, "frpc exited: code=$code")
                    }
                    // Self-heal: an unexpected exit while the tunnel is
                    // wanted schedules a backoff restart. stop() and a
                    // blank-config start() both clear wantRunning first,
                    // so intentional stops never land here.
                    if (!stoppedByUser && wantRunning) {
                        scheduleRestartLocked()
                    }
                }
            }
        }
        thread.isDaemon = true
        thread.name = "yousj-frpc-log"
        thread.start()
        readerThread = thread
    }

    // Schedule the next supervised restart. Caller holds the lock and
    // has already established that the tunnel is wanted and the process
    // is gone. Backoff: 5s, 15s, 30s, then 60s forever until the proxy
    // is up (a successful proxy start resets the counter — see
    // addLogLine).
    private fun scheduleRestartLocked() {
        val cfg = lastConfig ?: return
        cancelPendingRestartLocked()
        retryCount += 1
        val idx = minOf(retryCount - 1, RESTART_BACKOFF_SEC.size - 1)
        val delaySec = RESTART_BACKOFF_SEC[idx]
        nextRetryDelaySec = delaySec
        restartPending = true
        val runnable = Runnable {
            synchronized(this@FrpcBridge) {
                restartPending = false
                nextRetryDelaySec = 0
                if (wantRunning && !stoppedByUser && process == null) {
                    Log.i(TAG, "supervisor restarting frpc (attempt $retryCount)")
                    startLocked(cfg)
                    // If that start failed synchronously (e.g. config
                    // write error) no reader thread exists to schedule
                    // the next round — do it here.
                    if (process == null && wantRunning && !stoppedByUser) {
                        scheduleRestartLocked()
                    }
                }
            }
        }
        pendingRestart = runnable
        mainHandler.postDelayed(runnable, delaySec * 1000)
    }

    private fun cancelPendingRestartLocked() {
        pendingRestart?.let { mainHandler.removeCallbacks(it) }
        pendingRestart = null
        restartPending = false
        nextRetryDelaySec = 0
    }

    @Synchronized
    private fun stop() {
        wantRunning = false
        cancelPendingRestartLocked()
        stopLocked()
        stoppedByUser = true
    }

    private fun stopLocked() {
        val proc = process
        process = null
        currentFingerprint = null
        if (proc != null) {
            try {
                proc.destroy()
            } catch (e: Exception) {
                // Already gone.
            }
        }
        loginOk = false
        proxyOk = false
    }

    // --- frpc output interpretation -------------------------------------------

    private fun addLogLine(raw: String) {
        val line = raw.trim()
        if (line.isEmpty()) {
            return
        }
        synchronized(logLines) {
            logLines.add(line)
            while (logLines.size > MAX_LOG_LINES) {
                logLines.removeAt(0)
            }
        }
        // Literal log strings of frp v0.62.1's client (verified against
        // the shipped binary), so the reported state is what frpc itself
        // said, never a guess.
        if (line.contains("login to server success")) {
            loginOk = true
        }
        if (line.contains("start proxy success")) {
            proxyOk = true
            // The tunnel is fully up: the backoff ladder starts over if
            // it ever drops again.
            retryCount = 0
            nextRetryDelaySec = 0
        }
        val looksLikeError =
            line.contains("[E]") ||
                line.contains("login to the server failed") ||
                line.contains("start error") ||
                line.contains("connect to server error") ||
                line.contains("start new connection to server error")
        if (looksLikeError) {
            // Keep only the tail of the line (drop the timestamp /
            // source-file prefix) and cap the length for the UI.
            val msg = line.substringAfter("] ", line)
            lastError = if (msg.length > 160) msg.substring(0, 160) + "…" else msg
        }
    }

    // --- status -----------------------------------------------------------------

    private fun status(): Map<String, Any> {
        val ctx = appContext
        val bundled = ctx != null && frpcBinary(ctx).exists()
        val tail: List<String> = synchronized(logLines) {
            logLines.takeLast(LOG_TAIL_FOR_UI)
        }
        return mapOf(
            "bundled" to bundled,
            "running" to (process?.isAlive == true),
            "login_ok" to loginOk,
            "proxy_ok" to proxyOk,
            "last_error" to (lastError ?: ""),
            "exit_code" to (exitCode ?: -1),
            "log_tail" to tail,
            // Supervision (v1.0.8): whether the bridge is trying to keep
            // the tunnel up, how many restarts it has done in the
            // current outage, and whether a restart is counting down.
            "supervisor_active" to wantRunning,
            "retry_count" to retryCount,
            "restart_pending" to restartPending,
            "next_retry_sec" to nextRetryDelaySec.toInt(),
        )
    }

    // --- config -------------------------------------------------------------------

    private fun tomlString(value: String): String =
        "\"" + value.replace("\\", "\\\\").replace("\"", "\\\"") + "\""

    private fun buildConfig(cfg: Config): String {
        val sb = StringBuilder()
        sb.append("serverAddr = ").append(tomlString(cfg.serverAddr)).append('\n')
        sb.append("serverPort = ").append(cfg.serverPort).append('\n')
        // Never exit on a failed login: frpc keeps retrying in-process,
        // and the bridge supervisor restarts the process itself if it
        // ever dies anyway (v1.0.8).
        sb.append("loginFailExit = false\n")
        if (cfg.token.isNotEmpty()) {
            sb.append("auth.method = \"token\"\n")
            sb.append("auth.token = ").append(tomlString(cfg.token)).append('\n')
        }
        sb.append('\n')
        sb.append("[[proxies]]\n")
        sb.append("name = ").append(tomlString(PROXY_NAME)).append('\n')
        sb.append("type = \"tcp\"\n")
        sb.append("localIP = \"127.0.0.1\"\n")
        sb.append("localPort = ").append(cfg.localPort).append('\n')
        sb.append("remotePort = ").append(cfg.remotePort).append('\n')
        return sb.toString()
    }
}
