package com.nebula.karing

import android.app.Activity
import android.content.Context
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
// The frp token only ever lands in the private config file. It is not
// written to any log (ours or, per frp's own logging, frpc's).
object FrpcBridge {
    private const val TAG = "YousjFrpc"
    private const val CHANNEL = "cc.yousj.enhanced/frpc"
    private const val FRPC_LIB_NAME = "libfrpc.so"
    private const val PROXY_NAME = "yousj-external-ai"
    private const val MAX_LOG_LINES = 120
    private const val LOG_TAIL_FOR_UI = 30

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
                    val serverPort = call.argument<Int>("serverPort") ?: 7000
                    val remotePort = call.argument<Int>("remotePort") ?: 18777
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

    private fun fingerprint(
        serverAddr: String,
        serverPort: Int,
        remotePort: Int,
        localPort: Int,
        token: String,
    ): String =
        // The token contributes only its hash, so the fingerprint can be
        // kept/compared without holding another copy of the secret.
        "$serverAddr|$serverPort|$remotePort|$localPort|${token.hashCode()}"

    @Synchronized
    private fun start(
        serverAddr: String,
        serverPort: Int,
        remotePort: Int,
        localPort: Int,
        token: String,
    ) {
        val ctx = appContext ?: return
        val fp = fingerprint(serverAddr, serverPort, remotePort, localPort, token)
        val alive = process?.isAlive == true
        if (alive && currentFingerprint == fp) {
            return
        }
        if (serverAddr.isBlank()) {
            lastError = "服务器地址为空"
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
            file.writeText(buildConfig(serverAddr, serverPort, remotePort, localPort, token))
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
        Log.i(TAG, "frpc started (server=$serverAddr:$serverPort remotePort=$remotePort)")
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
            if (process === proc) {
                exitCode = code
                if (!stoppedByUser && loginOk.not() && lastError == null) {
                    lastError = "frpc 已退出（代码 ${code ?: "?"}）"
                }
                if (!stoppedByUser) {
                    Log.w(TAG, "frpc exited: code=$code")
                }
                process = null
            }
        }
        thread.isDaemon = true
        thread.name = "yousj-frpc-log"
        thread.start()
        readerThread = thread
    }

    @Synchronized
    private fun stop() {
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
        )
    }

    // --- config -------------------------------------------------------------------

    private fun tomlString(value: String): String =
        "\"" + value.replace("\\", "\\\\").replace("\"", "\\\"") + "\""

    private fun buildConfig(
        serverAddr: String,
        serverPort: Int,
        remotePort: Int,
        localPort: Int,
        token: String,
    ): String {
        val sb = StringBuilder()
        sb.append("serverAddr = ").append(tomlString(serverAddr)).append('\n')
        sb.append("serverPort = ").append(serverPort).append('\n')
        if (token.isNotEmpty()) {
            sb.append("auth.method = \"token\"\n")
            sb.append("auth.token = ").append(tomlString(token)).append('\n')
        }
        sb.append('\n')
        sb.append("[[proxies]]\n")
        sb.append("name = ").append(tomlString(PROXY_NAME)).append('\n')
        sb.append("type = \"tcp\"\n")
        sb.append("localIP = \"127.0.0.1\"\n")
        sb.append("localPort = ").append(localPort).append('\n')
        sb.append("remotePort = ").append(remotePort).append('\n')
        return sb.toString()
    }
}
