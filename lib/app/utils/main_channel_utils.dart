// Reconstructed for the Yousj Enhanced fork (upstream file missing).
//
// API pinned from call sites:
//   * biz.dart:34/53: MainChannel.init() / MainChannel.uninit() — the
//     bridge to the platform "main" channel (desktop single-instance /
//     protocol activation forwarding).
//   * home_screen.dart:1089:
//       String? command = await MainChannel.call("getCommand", {});
//     — asks the native side for a pending command (e.g. a karing://
//     link or shortcut action delivered before Flutter was ready).

import 'package:flutter/services.dart';

class MainChannel {
  static const MethodChannel _channel = MethodChannel('karing/main_channel');

  static bool _initialized = false;
  static String? _pendingCommand;

  static void init() {
    if (_initialized) {
      return;
    }
    _initialized = true;
    _channel.setMethodCallHandler((call) async {
      // Native side pushing a command/link into the app.
      if (call.method == 'onCommand' && call.arguments is String) {
        _pendingCommand = call.arguments as String;
      }
      return null;
    });
  }

  static void uninit() {
    if (!_initialized) {
      return;
    }
    _initialized = false;
    _channel.setMethodCallHandler(null);
  }

  /// Invoke a method on the native main channel. "getCommand" first
  /// drains any command pushed through init's handler.
  static Future<String?> call(String method, Map<dynamic, dynamic> args) async {
    if (method == 'getCommand' && _pendingCommand != null) {
      final command = _pendingCommand;
      _pendingCommand = null;
      return command;
    }
    try {
      final result = await _channel.invokeMethod<String>(method, args);
      return result;
    } catch (_) {
      return null;
    }
  }
}
