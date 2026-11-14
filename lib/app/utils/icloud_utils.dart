// Reconstructed for the Yousj Enhanced fork (upstream file missing).
//
// API pinned from call sites (backup_and_sync_icloud_screen.dart):
//   var result = await ICloudUtils.list();
//       -> ReturnResult<List<String>> of backup file names
//   error = await ICloudUtils.upload(
//       relativePath: path.basename(filePath), localPath: filePath);
//   ReturnResultError? error = await ICloudUtils.download(
//       relativePath: filename, localPath: filePath);
//   var error = await ICloudUtils.delete(filename);
//
// Backed by package:icloud_storage against the app's container
// "iCloud.com.nebula.karing" (ios/macos Runner.entitlements).

import 'package:icloud_storage/icloud_storage.dart';
import 'package:karing/app/runtime/return_result.dart';

class ICloudUtils {
  static const String containerId = 'iCloud.com.nebula.karing';

  static Future<ReturnResult<List<String>>> list() async {
    try {
      final files = await ICloudStorage.gather(containerId: containerId);
      return ReturnResult(
        data: files.map((file) => file.relativePath).toList(),
      );
    } catch (err) {
      return ReturnResult(error: ReturnResultError(err.toString()));
    }
  }

  static Future<ReturnResultError?> upload({
    required String relativePath,
    required String localPath,
  }) async {
    try {
      await ICloudStorage.upload(
        containerId: containerId,
        filePath: localPath,
        destinationRelativePath: relativePath,
      );
      return null;
    } catch (err) {
      return ReturnResultError(err.toString());
    }
  }

  static Future<ReturnResultError?> download({
    required String relativePath,
    required String localPath,
  }) async {
    try {
      await ICloudStorage.download(
        containerId: containerId,
        relativePath: relativePath,
        destinationFilePath: localPath,
      );
      return null;
    } catch (err) {
      return ReturnResultError(err.toString());
    }
  }

  static Future<ReturnResultError?> delete(String relativePath) async {
    try {
      await ICloudStorage.delete(
        containerId: containerId,
        relativePath: relativePath,
      );
      return null;
    } catch (err) {
      return ReturnResultError(err.toString());
    }
  }
}
