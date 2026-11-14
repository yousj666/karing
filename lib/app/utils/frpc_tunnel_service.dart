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
// Lifecycle rules (user decision, v1.0.7):
// - Everything defaults on: API on -> tunnel on.
// - The tunnel has its own switch, but the API master switch wins:
//   API off => tunnel stopped, always.
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
      if (!config.enable || !config.tunnelEnable) {
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
  //   state: 'disabled'  — the API master switch is off (tunnel stopped)
  //          'off'       — the tunnel's own switch is off
  //          'missing'   — frpc is not bundled in this build/arch
  //          'connected' — frpc logged in AND the proxy started
  //          'connecting'— frpc process running, not fully up yet
  //          'failed'    — frpc exited or reported an error (see detail)
  //          'stopped'   — not running, no error recorded
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
    if (running) {
      return {
        'state': 'connecting',
        'detail': loginOk ? '已登录服务器，通道建立中…' : '连接中…',
        'log_tail': logTail,
      };
    }
    if (lastError.isNotEmpty) {
      return {'state': 'failed', 'detail': '连接失败：$lastError', 'log_tail': logTail};
    }
    return {'state': 'stopped', 'detail': '未运行', 'log_tail': logTail};
  }
}
