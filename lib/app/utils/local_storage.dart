// Reconstructed for the Yousj Enhanced fork (upstream file missing).
//
// API pinned from call sites (home_screen.dart):
//   agreement = await LocalStorage.read(userAgreementAgreedIdKey);
//   LocalStorage.write(userAgreementAgreedIdKey, "true");
// — a tiny persistent string key/value store. The reconstruction backs
// it with a JSON file in the profile directory.

import 'dart:convert';
import 'dart:io';

import 'package:karing/app/utils/path_utils.dart';

class LocalStorage {
  static Map<String, String>? _cache;
  static Future<void>? _loading;

  static Future<Map<String, String>> _load() async {
    if (_cache != null) {
      return _cache!;
    }
    _loading ??= () async {
      final map = <String, String>{};
      try {
        final file = File(await PathUtils.localStorageFilePath());
        if (await file.exists()) {
          final decoded = jsonDecode(await file.readAsString());
          if (decoded is Map<String, dynamic>) {
            decoded.forEach((key, value) {
              map[key] = value.toString();
            });
          }
        }
      } catch (_) {}
      _cache = map;
    }();
    await _loading;
    return _cache!;
  }

  static Future<String?> read(String key) async {
    final map = await _load();
    return map[key];
  }

  static Future<void> write(String key, String value) async {
    final map = await _load();
    map[key] = value;
    try {
      final file = File(await PathUtils.localStorageFilePath());
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(map), flush: true);
    } catch (_) {}
  }

  static Future<void> remove(String key) async {
    final map = await _load();
    if (map.remove(key) != null) {
      try {
        final file = File(await PathUtils.localStorageFilePath());
        await file.writeAsString(jsonEncode(map), flush: true);
      } catch (_) {}
    }
  }
}
