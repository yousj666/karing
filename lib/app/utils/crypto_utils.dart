// Reconstructed for the Yousj Enhanced fork (upstream file missing).
//
// API pinned from call sites:
//   * auto_update_manager.dart:303:
//     `final hash = await CryptoUtils.getFileSha256(downloadPath)` —
//     compared against the update feed's sha256; null when the file
//     cannot be read.

import 'dart:io';

import 'package:crypto/crypto.dart';

class CryptoUtils {
  /// Lowercase hex SHA-256 of a file's contents, streamed in chunks.
  static Future<String?> getFileSha256(String filePath) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) {
        return null;
      }
      final digest = await sha256.bind(file.openRead()).first;
      return digest.toString();
    } catch (_) {
      return null;
    }
  }
}
