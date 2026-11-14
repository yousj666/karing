// Reconstructed for the Yousj Enhanced fork (2026-11-14) from call sites:
// `Log.init()` / `Log.uninit()` are awaited from main.dart / my_app.dart;
// `Log.w/d/i/e` take a single positional argument that is usually a String
// but is sometimes an error object (`Log.w(err)`), hence `Object?`.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:karing/app/utils/path_utils.dart';
import 'package:path/path.dart' as path;

class Log {
  Log._();

  static IOSink? _sink;

  /// Open the app log file (`<profile>/<logFileName>`) for appending.
  /// Called once from main() after the profile dir is known; logging before
  /// init only echoes to the console in debug builds.
  static Future<void> init() async {
    try {
      final dir = await PathUtils.profileDir();
      if (dir.isEmpty) {
        return;
      }
      final file = File(path.join(dir, PathUtils.logFileName()));
      _sink = file.openWrite(mode: FileMode.append);
      w('Log init');
    } catch (_) {
      _sink = null;
    }
  }

  static Future<void> uninit() async {
    try {
      await _sink?.flush();
      await _sink?.close();
    } catch (_) {}
    _sink = null;
  }

  static void _write(String level, Object? message) {
    final line =
        '${DateTime.now().toIso8601String()} [$level] ${message?.toString() ?? ''}';
    try {
      _sink?.writeln(line);
    } catch (_) {}
    if (kDebugMode) {
      debugPrint(line);
    }
  }

  static void d(Object? message) => _write('D', message);
  static void i(Object? message) => _write('I', message);
  static void w(Object? message) => _write('W', message);
  static void e(Object? message) => _write('E', message);
}
