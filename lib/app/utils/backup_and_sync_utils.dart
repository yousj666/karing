// Reconstructed for the Yousj Enhanced fork (2026-11-14) from call sites:
//  - getZipFileName() -> String — backup archive file name used by the
//    icloud / webdav / lan-sync flows
//  - getZipFileNameList() -> List<String> — the profile files a backup
//    archive contains (server_manager.backup walks profileDir with it)
//  - validZip(path) -> Future<ReturnResultError?> — null when the archive
//    opens and lists cleanly (server_manager import flow)
//  - zipExtension — FilePicker allowedExtensions value, hence no dot
//    (group_helper.onTapImport strips dots before comparing)

import 'dart:io';

import 'package:archive/archive.dart';
import 'package:karing/app/runtime/return_result.dart';
import 'package:karing/app/utils/proxy_conf_utils.dart';
import 'package:karing/app/utils/path_utils.dart';

class BackupAndSyncUtils {
  BackupAndSyncUtils._();

  static const String zipExtension = 'zip';

  /// Timestamped backup name, e.g. `karing_backup_20261114_103000.zip`.
  static String getZipFileName() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final stamp =
        '${now.year}${two(now.month)}${two(now.day)}_${two(now.hour)}${two(now.minute)}${two(now.second)}';
    return 'karing_backup_$stamp.$zipExtension';
  }

  /// Files (relative to the profile dir) that make up a backup archive:
  /// every PathUtils-managed config file name.
  static List<BackupZipFileEntry> getZipFileNameList() {
    return [
      BackupZipFileEntry(PathUtils.subscribeFileName(), required: true),
      BackupZipFileEntry(PathUtils.subscribeUseFileName(), required: false),
      BackupZipFileEntry(PathUtils.diversionGroupFileName(), required: false),
      BackupZipFileEntry(PathUtils.settingFileName(), required: true),
      BackupZipFileEntry(PathUtils.storageFileName(), required: false),
      BackupZipFileEntry(PathUtils.serviceConfigFileName(), required: true),
      BackupZipFileEntry(PathUtils.remoteConfigFileName(), required: false),
      BackupZipFileEntry(PathUtils.remoteISPConfigFileName(), required: false),
      BackupZipFileEntry(PathUtils.autoUpdateFileName(), required: false),
      BackupZipFileEntry(PathUtils.noticeFileName(), required: false),
      BackupZipFileEntry(PathUtils.ispNoticeFileName(), required: false),
      BackupZipFileEntry(PathUtils.cloudflareWarpFileName(), required: false),
    ];
  }

  /// Null when [zipPath] is a readable zip archive, an error otherwise.
  static Future<ReturnResultError?> validZip(String zipPath) async {
    try {
      final file = File(zipPath);
      if (!await file.exists()) {
        return ReturnResultError('file not exist: $zipPath');
      }
      final bytes = await file.readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);
      if (archive.isEmpty) {
        return ReturnResultError('empty archive: $zipPath');
      }
      return null;
    } catch (err) {
      return ReturnResultError(err.toString());
    }
  }
}
