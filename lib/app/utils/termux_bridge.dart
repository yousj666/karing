// yousj-plus (v1.0.6): Dart side of the Android Termux bridge.
//
// The native half (android/.../TermuxBridge.kt, MethodChannel
// "cc.yousj.enhanced/termux") wraps Termux's official RUN_COMMAND intent
// API and can launch — or, when Termux is missing, install from the
// bundled official APK asset — the Termux app itself. Commands run as
// the Termux user (not root, not the Android shell). Nothing here ever
// touches com.termux's private data; the sandbox makes that impossible
// anyway, and an already-installed Termux is simply used as-is.
//
// Errors come back as PlatformException codes so callers can react
// precisely: TERMUX_NOT_INSTALLED, PERMISSION_DENIED,
// EXTERNAL_APPS_DISABLED, TIMEOUT, EXEC_FAILED, TERMUX_ASSET_MISSING,
// LAUNCH_FAILED.

import 'dart:io';

import 'package:flutter/services.dart';

class TermuxBridge {
  static const MethodChannel _channel = MethodChannel(
    'cc.yousj.enhanced/termux',
  );

  static bool get isSupported => Platform.isAndroid;

  // {installed, permission_granted, ready}; all false when Termux (or the
  // bridge) is unavailable. Never throws.
  static Future<Map<String, dynamic>> status() async {
    if (!isSupported) {
      return {
        'installed': false,
        'permission_granted': false,
        'ready': false,
      };
    }
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'status',
      );
      if (result != null) {
        return result;
      }
    } catch (_) {}
    return {'installed': false, 'permission_granted': false, 'ready': false};
  }

  // Runs [command] in Termux via bash -c and waits for the result.
  // Returns {ok: true, exit_code, stdout, stderr} on execution (exit_code
  // may be null when Termux reported none) or {ok: false, error_code,
  // error_message} when the command could not be carried out at all.
  static Future<Map<String, dynamic>> exec(
    String command,
    int timeoutSeconds,
  ) async {
    if (!isSupported) {
      return {
        'ok': false,
        'error_code': 'EXEC_FAILED',
        'error_message': 'Termux 执行只支持 Android 平台',
      };
    }
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>('exec', {
        'command': command,
        'timeoutSeconds': timeoutSeconds,
      });
      if (result == null) {
        return {
          'ok': false,
          'error_code': 'EXEC_FAILED',
          'error_message': 'Termux 桥未返回结果',
        };
      }
      return {
        'ok': true,
        'exit_code': result['exit_code'],
        'stdout': (result['stdout'] as String?) ?? '',
        'stderr': (result['stderr'] as String?) ?? '',
      };
    } on PlatformException catch (e) {
      return {
        'ok': false,
        'error_code': e.code,
        'error_message': e.message ?? e.code,
      };
    } catch (e) {
      return {
        'ok': false,
        'error_code': 'EXEC_FAILED',
        'error_message': e.toString(),
      };
    }
  }

  // Opens Termux when installed; otherwise starts the system installer
  // for the bundled official Termux APK (the user still has to confirm
  // once in the system install UI — Android does not allow silent
  // installs). Returns {ok: true, result: 'launched'|'install_started',
  // auto_launch_after_install: bool} or {ok: false, error_code, ...}.
  static Future<Map<String, dynamic>> openOrInstall() async {
    if (!isSupported) {
      return {
        'ok': false,
        'error_code': 'EXEC_FAILED',
        'error_message': 'Termux 只支持 Android 平台',
      };
    }
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'openOrInstall',
      );
      if (result == null) {
        return {
          'ok': false,
          'error_code': 'LAUNCH_FAILED',
          'error_message': 'Termux 桥未返回结果',
        };
      }
      return {
        'ok': true,
        'result': result['result'],
        'auto_launch_after_install':
            result['auto_launch_after_install'] == true,
      };
    } on PlatformException catch (e) {
      return {
        'ok': false,
        'error_code': e.code,
        'error_message': e.message ?? e.code,
      };
    } catch (e) {
      return {
        'ok': false,
        'error_code': 'LAUNCH_FAILED',
        'error_message': e.toString(),
      };
    }
  }
}
