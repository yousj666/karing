// Reconstructed for the Yousj Enhanced fork (2026-11-14) from call sites:
//  - deletePath(String, {recursive}) — 27 sites, awaited, files and dirs
//  - recursionFile(dir, {extensionFilter}) -> List<String> — sync listing
//    used for backup zips and log cleanup
//  - recursiveFile(dir, {filter}) — same listing under the other name
//  - readAsStringReverse(path, maxBytes, bool) -> Tuple2<String, bool>?
//    — tail-read for the log viewer (file_content_viewer_screen.dart)
//  - readAndDelete(path) -> String? (referenced from home_screen.dart)
//  - validJsonFile(path) -> bool (my_profiles_screen.dart export check)
//  - openDirectory(path) (about_screen.dart "open profile dir")
//  - FileSaver — debounced JSON persistence used by server_manager,
//    board_provider_manager, auto_update_manager and
//    remote_config_manager: `FileSaver()`, `setSavePath(path)`,
//    `await saveAsJson(configObject)` (objects expose toJson()).

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:tuple/tuple.dart';

class FileUtils {
  FileUtils._();

  /// Delete a file or directory if it exists. Missing paths are a no-op.
  static Future<void> deletePath(String filePath, {bool recursive = false}) async {
    if (filePath.isEmpty) {
      return;
    }
    try {
      final type = await FileSystemEntity.type(filePath);
      if (type == FileSystemEntityType.file ||
          type == FileSystemEntityType.link) {
        await File(filePath).delete();
      } else if (type == FileSystemEntityType.directory) {
        await Directory(filePath).delete(recursive: recursive);
      }
    } catch (_) {}
  }

  static List<String> _listFiles(
    String dir,
    Set<String>? extensionFilter,
  ) {
    final result = <String>[];
    try {
      final directory = Directory(dir);
      if (!directory.existsSync()) {
        return result;
      }
      for (final entity in directory.listSync(recursive: true)) {
        if (entity is File) {
          if (extensionFilter == null ||
              extensionFilter.contains(path.extension(entity.path))) {
            result.add(entity.path);
          }
        }
      }
    } catch (_) {}
    return result;
  }

  /// All files under [dir] (recursive), optionally filtered by extension
  /// (extensions include the leading dot, e.g. `{".zip"}`).
  static List<String> recursionFile(
    String dir, {
    Set<String>? extensionFilter,
  }) {
    return _listFiles(dir, extensionFilter);
  }

  /// Alias of [recursionFile] under its other historical name.
  static List<String> recursiveFile(String dir, {Set<String>? filter}) {
    return _listFiles(dir, filter);
  }

  /// Read the tail of a (potentially large) file: at most [maxBytes] from
  /// the end. Returns (content, truncated) or null when the file is
  /// missing/unreadable. [reverse] is accepted for signature compatibility
  /// with the log viewer call site; the tail is returned in file order.
  static Future<Tuple2<String, bool>?> readAsStringReverse(
    String filePath,
    int maxBytes,
    bool reverse,
  ) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) {
        return null;
      }
      final length = await file.length();
      if (length <= maxBytes) {
        return Tuple2(await file.readAsString(), false);
      }
      final raf = await file.open();
      try {
        await raf.setPosition(length - maxBytes);
        final bytes = await raf.read(maxBytes);
        return Tuple2(utf8.decode(bytes, allowMalformed: true), true);
      } finally {
        await raf.close();
      }
    } catch (_) {
      return null;
    }
  }

  /// Read a file's text content and delete the file afterwards.
  static Future<String?> readAndDelete(String filePath) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) {
        return null;
      }
      final content = await file.readAsString();
      await deletePath(filePath);
      return content;
    } catch (_) {
      return null;
    }
  }

  /// True when [filePath] exists and parses as JSON.
  static Future<bool> validJsonFile(String filePath) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) {
        return false;
      }
      jsonDecode(await file.readAsString());
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Reveal [dirPath] in the platform file manager.
  static Future<void> openDirectory(String dirPath) async {
    try {
      if (Platform.isWindows) {
        await Process.start('explorer', [dirPath], mode: ProcessStartMode.detached);
      } else if (Platform.isMacOS) {
        await Process.start('open', [dirPath], mode: ProcessStartMode.detached);
      } else if (Platform.isLinux) {
        await Process.start('xdg-open', [dirPath], mode: ProcessStartMode.detached);
      }
    } catch (_) {}
  }
}

/// Debounced JSON file persistence for config objects.
///
/// Usage pattern in the managers:
///   final saver = FileSaver();
///   saver.setSavePath(await PathUtils.xxxFilePath());
///   await saver.saveAsJson(config); // config exposes toJson()
///
/// Writes are serialized through a future chain so rapid successive
/// saves cannot interleave or truncate the file.
class FileSaver {
  String? _savePath;
  Future<void> _chain = Future.value();

  void setSavePath(String path) {
    _savePath = path;
  }

  String? getSavePath() {
    return _savePath;
  }

  Future<void> saveAsJson(dynamic content) {
    final task = _chain.then((_) async {
      final target = _savePath;
      if (target == null || target.isEmpty) {
        return;
      }
      try {
        final Map<String, dynamic> map = content is Map<String, dynamic>
            ? content
            : (content.toJson() as Map<String, dynamic>);
        final file = File(target);
        await file.parent.create(recursive: true);
        await file.writeAsString(jsonEncode(map), flush: true);
      } catch (_) {}
    });
    _chain = task;
    return task;
  }
}
