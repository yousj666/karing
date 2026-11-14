// Reconstructed for the Yousj Enhanced fork (upstream file missing).
//
// API pinned from call sites (server_manager.dart, group_helper.dart):
//   var error = await ZipUtils.zip(zipFileList, zipPath);
//       -> Future<ReturnResultError?> (null on success)
//   var error = await ZipUtils.unzip(zipPath, dir, whiteList: whiteList);
//       -> Future<ReturnResultError?>; whiteList is a Set<String> of entry
//          names allowed to be extracted (backup restore safety).
//   var result = await ZipUtils.list(zipPath);
//       -> Future<ReturnResult<List<String>>> of entry names.
//
// Implemented over package:archive.

import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:karing/app/runtime/return_result.dart';

class ZipUtils {
  /// Zip [files] (file paths; stored under their base names) into
  /// [zipPath]. Returns null on success.
  static Future<ReturnResultError?> zip(
    List<String> files,
    String zipPath,
  ) async {
    try {
      final encoder = ZipFileEncoder();
      encoder.create(zipPath);
      for (final path in files) {
        final file = File(path);
        if (await file.exists()) {
          await encoder.addFile(file);
        }
      }
      await encoder.close();
      return null;
    } catch (err) {
      return ReturnResultError(err.toString());
    }
  }

  /// Extract [zipPath] into [dir]. When [whiteList] is non-null, only
  /// entries whose name is in the set are written. Returns null on
  /// success.
  static Future<ReturnResultError?> unzip(
    String zipPath,
    String dir, {
    Set<String>? whiteList,
  }) async {
    try {
      final bytes = await File(zipPath).readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);
      for (final entry in archive) {
        if (whiteList != null && !whiteList.contains(entry.name)) {
          continue;
        }
        // Zip-slip guard: never write outside the target directory.
        final name = entry.name.replaceAll('\\', '/');
        if (name.contains('..')) {
          continue;
        }
        final outPath = '$dir/$name';
        if (entry.isFile) {
          final out = File(outPath);
          await out.parent.create(recursive: true);
          await out.writeAsBytes(entry.content as List<int>, flush: true);
        } else {
          await Directory(outPath).create(recursive: true);
        }
      }
      return null;
    } catch (err) {
      return ReturnResultError(err.toString());
    }
  }

  /// List the entry names inside [zipPath].
  static Future<ReturnResult<List<String>>> list(String zipPath) async {
    try {
      final bytes = await File(zipPath).readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);
      return ReturnResult(
        data: archive.files.map((entry) => entry.name).toList(),
      );
    } catch (err) {
      return ReturnResult(error: ReturnResultError(err.toString()));
    }
  }
}
