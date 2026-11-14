// Reconstructed for the Yousj Enhanced fork (upstream file missing).
//
// API pinned from call sites:
//   * perapp_macos_screen.dart:77:
//       List<MacosProcessInfo> value =
//           await ProcessUtilsMacos.getProcessList();
//     entries expose .name and .identifier (bundle id), and current rows
//     are matched by identifier.
//   * perapp_macos_screen.dart:104:
//       return ProcessUtilsMacos.getProcessIcon(_processInfoList, identifier);
//     -> Future<Image?> (the screen's own getProcessIcon returns it
//     directly from a Future<Image?> function).
//   * net_connections_screen.dart also calls getProcessList/getProcessIcon
//     for per-connection app attribution on macOS.

import 'dart:io';

import 'package:flutter/widgets.dart' as widgets;

class MacosProcessInfo {
  String name = '';
  String identifier = '';
  String path = '';
  int pid = 0;

  Map<String, dynamic> toJson() => {
    'name': name,
    'identifier': identifier,
    'path': path,
    'pid': pid,
  };

  void fromJson(Map<String, dynamic>? map) {
    if (map == null) {
      return;
    }
    name = map['name'] ?? '';
    identifier = map['identifier'] ?? '';
    path = map['path'] ?? '';
    final p = map['pid'];
    pid = p is num ? p.toInt() : 0;
  }

  static MacosProcessInfo fromJsonStatic(Map<String, dynamic>? map) {
    final info = MacosProcessInfo();
    info.fromJson(map);
    return info;
  }
}

class ProcessUtilsMacos {
  static final Map<String, widgets.Image?> _iconCache = {};

  /// Enumerate running GUI apps via `osascript` (System Events), which
  /// yields name + bundle identifier + pid for every background/foreground
  /// process without special entitlements.
  static Future<List<MacosProcessInfo>> getProcessList() async {
    final result = <MacosProcessInfo>[];
    if (!Platform.isMacOS) {
      return result;
    }
    try {
      final script =
          'tell application "System Events" to get {name, bundle identifier, unix id} of every process';
      final proc = await Process.run('osascript', ['-e', script]);
      if (proc.exitCode != 0) {
        return result;
      }
      // osascript prints three comma-separated groups in order; parsing
      // robustly is done via a JSON-producing variant instead.
      final jsonProc = await Process.run('osascript', [
        '-e',
        'set out to {}',
        '-e',
        'tell application "System Events"',
        '-e',
        'repeat with p in (every process)',
        '-e',
        'try',
        '-e',
        'set end of out to (name of p) & "|" & (bundle identifier of p) & "|" & (unix id of p) & "|" & (POSIX path of (file of p))',
        '-e',
        'end try',
        '-e',
        'end repeat',
        '-e',
        'end tell',
        '-e',
        'return out',
      ]);
      final output = (jsonProc.stdout as String).trim();
      if (jsonProc.exitCode == 0 && output.isNotEmpty) {
        for (final entry in output.split(', ')) {
          final parts = entry.split('|');
          if (parts.length < 3) {
            continue;
          }
          final info = MacosProcessInfo();
          info.name = parts[0].trim();
          info.identifier = parts[1].trim();
          info.pid = int.tryParse(parts[2].trim()) ?? 0;
          if (parts.length > 3) {
            info.path = parts[3].trim();
          }
          result.add(info);
        }
      }
    } catch (_) {}
    return result;
  }

  /// Icon for the app with [identifier] from a previously fetched list:
  /// reads the app's bundle icon (AppIcon.icns) when the path is known.
  static Future<widgets.Image?> getProcessIcon(
    List<MacosProcessInfo> list,
    String identifier,
  ) async {
    if (_iconCache.containsKey(identifier)) {
      return _iconCache[identifier];
    }
    widgets.Image? image;
    try {
      MacosProcessInfo? match;
      for (final info in list) {
        if (info.identifier == identifier) {
          match = info;
          break;
        }
      }
      final appPath = match?.path ?? '';
      if (Platform.isMacOS && appPath.isNotEmpty) {
        final resources = Directory('$appPath/Contents/Resources');
        if (await resources.exists()) {
          await for (final entity in resources.list()) {
            if (entity is File && entity.path.endsWith('.icns')) {
              final bytes = await entity.readAsBytes();
              image = widgets.Image.memory(bytes);
              break;
            }
          }
        }
      }
    } catch (_) {
      image = null;
    }
    _iconCache[identifier] = image;
    return image;
  }
}
