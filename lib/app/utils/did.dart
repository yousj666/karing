// Reconstructed for the Yousj Enhanced fork (2026-11-14) from call sites:
// device-id helper. getDid() is awaited (board_provider managers),
// getFirstTime() is awaited (remote_config_manager), newUUID() is a sync
// UUID v4 (group_helper.dart LAN-sync secret).
//
// The did is persisted as a plain file in the profile dir
// [RECONSTRUCTION CHOICE: file name 'did.txt']; "first time" means the
// did file did not exist yet, i.e. this install has never run before.

import 'dart:io';

import 'package:karing/app/utils/path_utils.dart';
import 'package:path/path.dart' as path;
import 'package:uuid/uuid.dart';

class Did {
  Did._();

  static String? _did;
  static bool _firstTime = false;
  static bool _loaded = false;

  static String newUUID() {
    return const Uuid().v4();
  }

  static Future<File> _didFile() async {
    return File(path.join(await PathUtils.profileDir(), 'did.txt'));
  }

  static Future<void> _ensureLoaded() async {
    if (_loaded) {
      return;
    }
    _loaded = true;
    try {
      final file = await _didFile();
      if (await file.exists()) {
        final content = (await file.readAsString()).trim();
        if (content.isNotEmpty) {
          _did = content;
          _firstTime = false;
          return;
        }
      }
    } catch (_) {}
    _did = newUUID();
    _firstTime = true;
    try {
      final file = await _didFile();
      await file.parent.create(recursive: true);
      await file.writeAsString(_did!);
    } catch (_) {}
  }

  static Future<String> getDid() async {
    await _ensureLoaded();
    return _did!;
  }

  static Future<bool> getFirstTime() async {
    await _ensureLoaded();
    return _firstTime;
  }
}
