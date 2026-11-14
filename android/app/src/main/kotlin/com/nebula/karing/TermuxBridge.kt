package com.nebula.karing

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.lang.ref.WeakReference
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

// yousj-plus (v1.0.6): bridge to Termux.
//
// Two jobs:
//  1. exec: run a command inside Termux through its official RUN_COMMAND
//     intent API and wait for the result. All extra keys below are the
//     values from Termux's own TermuxConstants (termux-app, termux-shared
//     v0.53) and RunCommandService/TermuxPluginUtils sources, verified
//     against upstream — not guessed:
//       service  com.termux.app.RunCommandService
//       action   com.termux.RUN_COMMAND
//       extras   com.termux.RUN_COMMAND_PATH / _ARGUMENTS / _WORKDIR /
//                _BACKGROUND / _PENDING_INTENT
//       result   intent extra "result" (Bundle) with keys "stdout",
//                "stderr", "exitCode", "err", "errmsg"
//     Commands run as the Termux user — not root, not the Android shell.
//  2. openOrInstall: launch the installed Termux as-is (its data is its
//     own; this app never reads com.termux private data), or, when it is
//     missing, start the system installer for the official Termux APK
//     bundled as an asset. Android requires the user to confirm once in
//     the system install UI; silent install is not possible.
//
// The command text and any token are never written to the log.
object TermuxBridge {
    private const val TAG = "YousjTermux"
    private const val CHANNEL = "cc.yousj.enhanced/termux"

    private const val TERMUX_PACKAGE = "com.termux"
    private const val TERMUX_ACTIVITY = "com.termux.app.TermuxActivity"
    private const val PERMISSION_RUN_COMMAND = "com.termux.permission.RUN_COMMAND"
    private const val RUN_COMMAND_SERVICE = "com.termux.app.RunCommandService"
    private const val ACTION_RUN_COMMAND = "com.termux.RUN_COMMAND"
    private const val EXTRA_COMMAND_PATH = "com.termux.RUN_COMMAND_PATH"
    private const val EXTRA_ARGUMENTS = "com.termux.RUN_COMMAND_ARGUMENTS"
    private const val EXTRA_WORKDIR = "com.termux.RUN_COMMAND_WORKDIR"
    private const val EXTRA_BACKGROUND = "com.termux.RUN_COMMAND_BACKGROUND"
    private const val EXTRA_PENDING_INTENT = "com.termux.RUN_COMMAND_PENDING_INTENT"
    private const val BASH_PATH = "/data/data/com.termux/files/usr/bin/bash"
    private const val TERMUX_HOME = "/data/data/com.termux/files/home"
    private const val RESULT_BUNDLE_KEY = "result"

    private const val ACTION_RESULT = "cc.yousj.enhanced.action.TERMUX_RESULT"
    private const val EXTRA_REQUEST_ID = "cc.yousj.enhanced.extra.REQUEST_ID"
    private const val REQUEST_CODE_RUN_COMMAND_PERMISSION = 0x7E02

    private const val ASSET_TERMUX_APK = "termux/termux-app-arm64.apk"
    private const val APK_MIME = "application/vnd.android.package-archive"

    private var channel: MethodChannel? = null
    private var appContext: Context? = null
    private var activityRef: WeakReference<Activity>? = null

    private val nextRequestId = AtomicInteger(1)
    private val pendingResults = ConcurrentHashMap<Int, MethodChannel.Result>()
    private val mainHandler = Handler(Looper.getMainLooper())
    private var resultReceiverRegistered = false
    private var packageAddedReceiver: BroadcastReceiver? = null

    fun register(flutterEngine: FlutterEngine, activity: Activity) {
        appContext = activity.applicationContext
        activityRef = WeakReference(activity)
        if (channel != null) {
            return
        }
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "status" -> result.success(status())
                "exec" -> {
                    val command = call.argument<String>("command") ?: ""
                    val timeoutSeconds = call.argument<Int>("timeoutSeconds") ?: 30
                    exec(command, timeoutSeconds, result)
                }
                "openOrInstall" -> openOrInstall(result)
                else -> result.notImplemented()
            }
        }
        channel = ch
    }

    // --- status --------------------------------------------------------------

    private fun isTermuxInstalled(): Boolean {
        val ctx = appContext ?: return false
        return try {
            ctx.packageManager.getPackageInfo(TERMUX_PACKAGE, 0)
            true
        } catch (e: PackageManager.NameNotFoundException) {
            false
        }
    }

    private fun isPermissionGranted(): Boolean {
        val ctx = appContext ?: return false
        return ContextCompat.checkSelfPermission(ctx, PERMISSION_RUN_COMMAND) ==
            PackageManager.PERMISSION_GRANTED
    }

    private fun status(): Map<String, Any> {
        val installed = isTermuxInstalled()
        val granted = isPermissionGranted()
        return mapOf(
            "installed" to installed,
            "permission_granted" to granted,
            "ready" to (installed && granted),
        )
    }

    // --- exec (RUN_COMMAND) ----------------------------------------------------

    private fun exec(command: String, timeoutSeconds: Int, result: MethodChannel.Result) {
        val ctx = appContext
        if (ctx == null) {
            result.error("EXEC_FAILED", "bridge not initialised", null)
            return
        }
        if (!isTermuxInstalled()) {
            result.error(
                "TERMUX_NOT_INSTALLED",
                "Termux 未安装：请先在主页点 Termux 入口安装，或自行安装 Termux",
                null,
            )
            return
        }
        if (!isPermissionGranted()) {
            // Ask for the runtime permission so the next attempt can pass;
            // this call itself still fails — the caller must retry.
            val activity = activityRef?.get()
            if (activity != null) {
                try {
                    ActivityCompat.requestPermissions(
                        activity,
                        arrayOf(PERMISSION_RUN_COMMAND),
                        REQUEST_CODE_RUN_COMMAND_PERMISSION,
                    )
                } catch (e: Exception) {
                    Log.w(TAG, "requestPermissions failed: ${e.message}")
                }
            }
            result.error(
                "PERMISSION_DENIED",
                "尚未授予 RUN_COMMAND 权限：已尝试弹出授权请求，请在系统弹窗中允许后重试；也可在系统设置 → 应用 → Yousj Enhanced → 权限中开启",
                null,
            )
            return
        }

        val requestId = nextRequestId.getAndIncrement()
        ensureResultReceiver(ctx)
        pendingResults[requestId] = result

        // Timeout watchdog: complete with TIMEOUT if Termux never calls
        // back (e.g. it was killed, or the result intent was lost).
        mainHandler.postDelayed({
            val pending = pendingResults.remove(requestId)
            if (pending != null) {
                pending.error(
                    "TIMEOUT",
                    "Termux 在 ${timeoutSeconds} 秒内没有返回结果（命令可能仍在后台运行）",
                    null,
                )
            }
        }, timeoutSeconds * 1000L + 2000L)

        // The PendingIntent must be MUTABLE: Termux delivers the result by
        // merging its result Intent into ours (PendingIntent.send with a
        // fill-in intent), and an immutable PendingIntent would silently
        // drop those extras. The receiver is registered NOT_EXPORTED and
        // the intent is addressed to our own package only, and each
        // request carries a unique request code + request id, so results
        // cannot be cross-delivered between requests.
        val resultIntent = Intent(ACTION_RESULT)
            .setPackage(ctx.packageName)
            .putExtra(EXTRA_REQUEST_ID, requestId)
        val pendingIntent = PendingIntent.getBroadcast(
            ctx,
            requestId,
            resultIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
        )

        val intent = Intent(ACTION_RUN_COMMAND)
            .setClassName(TERMUX_PACKAGE, RUN_COMMAND_SERVICE)
            .putExtra(EXTRA_COMMAND_PATH, BASH_PATH)
            .putExtra(EXTRA_ARGUMENTS, arrayOf("-c", command))
            .putExtra(EXTRA_WORKDIR, TERMUX_HOME)
            .putExtra(EXTRA_BACKGROUND, true)
            .putExtra(EXTRA_PENDING_INTENT, pendingIntent)

        try {
            ctx.startService(intent)
            // Log metadata only — never the command itself.
            Log.i(TAG, "exec dispatched: request=$requestId len=${command.length}")
        } catch (e: SecurityException) {
            pendingResults.remove(requestId)
            result.error(
                "PERMISSION_DENIED",
                "Termux 拒绝了 RUN_COMMAND 调用（权限未授予或被撤销）：${e.message}",
                null,
            )
        } catch (e: IllegalStateException) {
            pendingResults.remove(requestId)
            result.error(
                "EXEC_FAILED",
                "系统不允许在后台启动 Termux 服务：请先打开一次 Yousj Enhanced 后再重试（${e.message}）",
                null,
            )
        } catch (e: Exception) {
            pendingResults.remove(requestId)
            result.error("EXEC_FAILED", "启动 Termux 服务失败：${e.message}", null)
        }
    }

    private val resultReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val requestId = intent.getIntExtra(EXTRA_REQUEST_ID, -1)
            val result = pendingResults.remove(requestId) ?: return
            val bundle: Bundle? = try {
                intent.getBundleExtra(RESULT_BUNDLE_KEY)
            } catch (e: Exception) {
                null
            }
            // Fallback: some Termux versions may put the fields at the top
            // level of the result intent instead of inside the bundle.
            val stdout = bundle?.getString("stdout") ?: intent.getStringExtra("stdout") ?: ""
            val stderr = bundle?.getString("stderr") ?: intent.getStringExtra("stderr") ?: ""
            val hasExitCode = bundle?.containsKey("exitCode") == true ||
                intent.hasExtra("exitCode")
            val exitCode: Int? = when {
                bundle?.containsKey("exitCode") == true -> bundle.getInt("exitCode")
                intent.hasExtra("exitCode") -> intent.getIntExtra("exitCode", 0)
                else -> null
            }
            val err = bundle?.getInt("err", 0) ?: intent.getIntExtra("err", 0)
            val errmsg = bundle?.getString("errmsg") ?: intent.getStringExtra("errmsg")
            if (err != 0) {
                if (errmsg != null && errmsg.contains("allow-external-apps")) {
                    result.error(
                        "EXTERNAL_APPS_DISABLED",
                        "Termux 未开启 allow-external-apps：请在 Termux 里编辑 ~/.termux/termux.properties 加入 allow-external-apps=true，然后完全重启 Termux 再重试",
                        null,
                    )
                } else {
                    result.error(
                        "EXEC_FAILED",
                        "Termux 执行失败（err=$err）${if (errmsg.isNullOrEmpty()) "" else "：$errmsg"}",
                        null,
                    )
                }
                return
            }
            Log.i(
                TAG,
                "exec done: request=$requestId exit=${if (hasExitCode) exitCode else "n/a"} " +
                    "stdoutLen=${stdout.length} stderrLen=${stderr.length}",
            )
            result.success(
                mapOf(
                    "exit_code" to exitCode,
                    "stdout" to stdout,
                    "stderr" to stderr,
                ),
            )
        }
    }

    private fun ensureResultReceiver(ctx: Context) {
        if (resultReceiverRegistered) {
            return
        }
        val filter = IntentFilter(ACTION_RESULT)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            ctx.registerReceiver(resultReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            ctx.registerReceiver(resultReceiver, filter)
        }
        resultReceiverRegistered = true
    }

    // --- open / install --------------------------------------------------------

    private fun openOrInstall(result: MethodChannel.Result) {
        val ctx = appContext
        if (ctx == null) {
            result.error("LAUNCH_FAILED", "bridge not initialised", null)
            return
        }
        if (isTermuxInstalled()) {
            // Never attempt an overlay install over an existing Termux:
            // its signature may differ (F-Droid / GitHub / Play builds are
            // signed differently) and Android would refuse anyway. Just
            // open the user's existing Termux, data untouched.
            if (launchTermux(ctx)) {
                result.success(
                    mapOf("result" to "launched", "auto_launch_after_install" to false),
                )
            } else {
                result.error("LAUNCH_FAILED", "Termux 已安装，但拉起窗口失败", null)
            }
            return
        }
        installBundledTermux(ctx, result)
    }

    private fun launchTermux(ctx: Context): Boolean {
        val launch = ctx.packageManager.getLaunchIntentForPackage(TERMUX_PACKAGE)
            ?: Intent(Intent.ACTION_MAIN).setComponent(
                ComponentName(TERMUX_PACKAGE, TERMUX_ACTIVITY),
            )
        launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return try {
            ctx.startActivity(launch)
            true
        } catch (e: Exception) {
            Log.w(TAG, "launch Termux failed: ${e.message}")
            false
        }
    }

    private fun installBundledTermux(ctx: Context, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !ctx.packageManager.canRequestPackageInstalls()
        ) {
            // Send the user to the exact settings page; they flip the
            // switch and tap the grid entry again.
            try {
                val settings = Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:${ctx.packageName}"),
                ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                ctx.startActivity(settings)
            } catch (e: Exception) {
                Log.w(TAG, "open unknown-sources settings failed: ${e.message}")
            }
            result.error(
                "INSTALL_PERMISSION_REQUIRED",
                "请先在系统设置里允许 Yousj Enhanced 安装未知应用，允许后回来再点一次 Termux 入口",
                null,
            )
            return
        }

        val apkFile: File = try {
            val dir = File(ctx.cacheDir, "termux")
            if (!dir.exists()) {
                dir.mkdirs()
            }
            val out = File(dir, "termux-app-arm64.apk")
            ctx.assets.open(ASSET_TERMUX_APK).use { input ->
                out.outputStream().use { output -> input.copyTo(output) }
            }
            out
        } catch (e: Exception) {
            result.error(
                "TERMUX_ASSET_MISSING",
                "安装包内未找到内置 Termux APK 资产：${e.message}",
                null,
            )
            return
        }

        val uri: Uri = try {
            FileProvider.getUriForFile(ctx, "${ctx.packageName}.fileProvider", apkFile)
        } catch (e: Exception) {
            result.error("EXEC_FAILED", "无法生成安装包 Uri：${e.message}", null)
            return
        }

        registerAutoLaunchAfterInstall(ctx)
        val install = Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, APK_MIME)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        try {
            ctx.startActivity(install)
            result.success(
                mapOf("result" to "install_started", "auto_launch_after_install" to true),
            )
        } catch (e: Exception) {
            result.error("EXEC_FAILED", "拉起系统安装器失败：${e.message}", null)
        }
    }

    // One-shot: when the Termux package appears (install finished), open
    // it right away so the flow feels built-in. Unregisters itself after
    // firing or after 10 minutes.
    private fun registerAutoLaunchAfterInstall(ctx: Context) {
        if (packageAddedReceiver != null) {
            return
        }
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                val pkg = intent.data?.schemeSpecificPart
                if (pkg == TERMUX_PACKAGE) {
                    unregisterAutoLaunch(ctx)
                    launchTermux(ctx)
                }
            }
        }
        val filter = IntentFilter(Intent.ACTION_PACKAGE_ADDED).apply {
            addDataScheme("package")
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            ctx.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            ctx.registerReceiver(receiver, filter)
        }
        packageAddedReceiver = receiver
        mainHandler.postDelayed({ unregisterAutoLaunch(ctx) }, 10 * 60 * 1000L)
    }

    private fun unregisterAutoLaunch(ctx: Context) {
        val receiver = packageAddedReceiver ?: return
        packageAddedReceiver = null
        try {
            ctx.unregisterReceiver(receiver)
        } catch (e: Exception) {
            // Already unregistered — fine.
        }
    }
}
