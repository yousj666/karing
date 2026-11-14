// yousj-plus (v1.0.7): Dart side of the built-in reverse tunnel (frpc).
//
// The phone is usually behind NAT, so the external AI API on port 18777
// would only be reachable from the local network. To make it reachable
// from the internet, the app bundles frpc (fatedier/frp, shipped as a
// native library — see FrpcBridge.kt) and, whenever the external API is
// enabled, automatically starts a TCP tunnel:
//   frps (serverAddr:serverPort) remotePort  ->  127.0.0.1:18777 (phone)
// External programs then reach the API at http://serverAddr:remotePort,
// still guarded by the API access token.
//
// Lifecycle rules (user decision, v1.0.7; server config v1.0.8):
// - Everything defaults on: API on -> tunnel on.
// - The tunnel has its own switch, but the API master switch wins:
//   API off => tunnel stopped, always.
// - There is no preset server: while no server address is configured
//   the tunnel stays "unconfigured" and frpc is never started. Once the
//   user saves an address, the tunnel comes up automatically, and the
//   native bridge keeps it up (in-frpc retry + supervised restarts).
// - The tunnel process lives and dies with the app process; if Android
//   kills the app, the tunnel is down until the app runs again.
//
// The frp token is passed to the native side only; it is never logged
// here or there.

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:karing/app/modules/setting_manager.dart';

class FrpcTunnelService {
  static const MethodChannel _channel = MethodChannel(
    'cc.yousj.enhanced/frpc',
  );

  // Must match ExternalApiService.kPort (kept as a literal to avoid an
  // import cycle; the two files are maintained together).
  static const int kLocalPort = 18777;

  static bool get isSupported => Platform.isAndroid;

  static SettingConfigItemExternalApi get _config =>
      SettingManager.getConfig().externalApi;

  // Start/stop the tunnel so it matches the current settings. Called
  // from ExternalApiService.applyFromConfig (app start, API toggles)
  // and from the settings UI whenever a tunnel field changes.
  static Future<void> applyFromConfig() async {
    if (!isSupported) {
      return;
    }
    final config = _config;
    try {
      if (!config.enable ||
          !config.tunnelEnable ||
          config.tunnelServerAddr.trim().isEmpty) {
        // Off, or no server configured yet (v1.0.8): make sure nothing
        // is running and do not attempt a start — an empty address is
        // "unconfigured", not a connection failure.
        await _channel.invokeMethod('stop');
        return;
      }
      await _channel.invokeMethod('start', {
        'serverAddr': config.tunnelServerAddr,
        'serverPort': config.tunnelServerPort,
        'remotePort': config.tunnelRemotePort,
        'token': config.tunnelToken,
        'localPort': kLocalPort,
      });
    } catch (_) {
      // The bridge is best-effort: a failure here must never break the
      // API startup path. The status query surfaces the problem.
    }
  }

  // Normalised status for the settings UI:
  //   state: 'disabled'     — the API master switch is off (tunnel stopped)
  //          'off'          — the tunnel's own switch is off
  //          'unconfigured' — no server address saved yet (v1.0.8);
  //                           frpc is not started and this is NOT an error
  //          'missing'      — frpc is not bundled in this build/arch
  //          'connected'    — frpc logged in AND the proxy started
  //          'connecting'   — frpc process running, not fully up yet
  //          'reconnecting' — process down, supervisor restart pending
  //                           or retrying (detail carries the retry count);
  //                           never a terminal failure
  //          'failed'       — bridge-level problem (query failed etc.)
  //          'stopped'      — not running, no error recorded
  //   detail: human-readable summary (never contains the token)
  //   log_tail: last frpc output lines, for diagnosis
  static Future<Map<String, dynamic>> status() async {
    final config = _config;
    if (!config.enable) {
      return {
        'state': 'disabled',
        'detail': '已停用（外部 AI 接口已关闭）',
        'log_tail': <String>[],
      };
    }
    if (!config.tunnelEnable) {
      return {
        'state': 'off',
        'detail': '已关闭',
        'log_tail': <String>[],
      };
    }
    if (config.tunnelServerAddr.trim().isEmpty) {
      return {
        'state': 'unconfigured',
        'detail': '未配置（请填写你自己的 frps 服务器地址，保存后自动连接）',
        'log_tail': <String>[],
      };
    }
    if (!isSupported) {
      return {
        'state': 'stopped',
        'detail': '仅 Android 支持',
        'log_tail': <String>[],
      };
    }
    Map<String, dynamic> raw;
    try {
      raw =
          await _channel.invokeMapMethod<String, dynamic>('status') ??
          <String, dynamic>{};
    } catch (err) {
      return {
        'state': 'failed',
        'detail': '通道状态查询失败：${err.toString()}',
        'log_tail': <String>[],
      };
    }
    final bundled = raw['bundled'] == true;
    final running = raw['running'] == true;
    final loginOk = raw['login_ok'] == true;
    final proxyOk = raw['proxy_ok'] == true;
    final lastError = (raw['last_error'] as String?) ?? '';
    final logTail = (raw['log_tail'] as List?)?.cast<String>() ?? <String>[];
    // Supervision fields from the bridge (v1.0.8): whether it is trying
    // to keep the tunnel up, how many restarts the current outage has
    // taken, and whether a restart is counting down right now.
    final supervisorActive = raw['supervisor_active'] == true;
    final retryCount = (raw['retry_count'] as num?)?.toInt() ?? 0;
    final restartPending = raw['restart_pending'] == true;
    final nextRetrySec = (raw['next_retry_sec'] as num?)?.toInt() ?? 0;
    if (!bundled) {
      return {
        'state': 'missing',
        'detail': '此安装包未内置 frpc（仅 arm64 版本提供）',
        'log_tail': logTail,
      };
    }
    if (running && loginOk && proxyOk) {
      return {
        'state': 'connected',
        'detail':
            '已连接：http://${config.tunnelServerAddr}:${config.tunnelRemotePort}',
        'log_tail': logTail,
      };
    }
    if (supervisorActive && retryCount > 0) {
      // The tunnel has been up (or tried) and dropped: the bridge is
      // bringing it back on its own. This is a transient state, never
      // report it as a terminal failure.
      final countdown = restartPending && nextRetrySec > 0
          ? '，${nextRetrySec} 秒后重试'
          : '';
      return {
        'state': 'reconnecting',
        'detail': '重连中（已重试 $retryCount 次$countdown）',
        'log_tail': logTail,
      };
    }
    if (running) {
      return {
        'state': 'connecting',
        'detail': loginOk ? '已登录服务器，通道建立中…' : '连接中…',
        'log_tail': logTail,
      };
    }
    if (supervisorActive) {
      // Wanted but momentarily down with a restart on the way (first
      // outage, counter not yet bumped): still reconnecting, and any
      // recorded error is context, not a final verdict.
      return {
        'state': 'reconnecting',
        'detail': lastError.isNotEmpty ? '重连中（上次错误：$lastError）' : '重连中…',
        'log_tail': logTail,
      };
    }
    if (lastError.isNotEmpty) {
      return {'state': 'failed', 'detail': '连接失败：$lastError', 'log_tail': logTail};
    }
    return {'state': 'stopped', 'detail': '未运行', 'log_tail': logTail};
  }
}
