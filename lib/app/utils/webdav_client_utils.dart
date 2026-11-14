// Reconstructed for the Yousj Enhanced fork (upstream file missing).
//
// API pinned from call sites (backup_and_sync_webdav_screen.dart):
//   result = await WebdavClientUtils.connect(
//       proxyUrl, settingConfig.webdav.url, user, password, ...);
//       -> ReturnResult<WebdavClient> (package:webdav_client_plus)
//   var result = await WebdavClientUtils.list(_webdavClient!);
//       -> ReturnResult<List<String>> of file names in the root folder
//   error = await WebdavClientUtils.upload(_webdavClient!,
//       relativePath: ..., localPath: ...);   -> ReturnResultError?
//   error = await WebdavClientUtils.download(_webdavClient!,
//       relativePath: ..., localPath: ...);   -> ReturnResultError?
//   var error = await WebdavClientUtils.delete(_webdavClient!, filename);
//   WebdavClientUtils.isInnerError(message) -> bool (was used to decide
//   whether a connect failure is the app's own proxy error).

import 'package:karing/app/runtime/return_result.dart';
import 'package:webdav_client_plus/webdav_client_plus.dart';

class WebdavClientUtils {
  /// Create a client and verify the server answers (ping). [proxyUrl] is
  /// accepted for interface compatibility; webdav_client_plus has no
  /// per-client proxy setting, so connections are direct.
  static Future<ReturnResult<WebdavClient>> connect(
    String? proxyUrl,
    String url,
    String user,
    String password,
  ) async {
    try {
      final client = user.isEmpty
          ? WebdavClient.noAuth(url: url)
          : WebdavClient.basicAuth(url: url, user: user, pwd: password);
      client.setConnectTimeout(10000);
      client.setSendTimeout(10000);
      client.setReceiveTimeout(10000);
      await client.ping();
      return ReturnResult(data: client);
    } catch (err) {
      return ReturnResult(error: ReturnResultError(err.toString()));
    }
  }

  static bool isInnerError(String message) {
    final lower = message.toLowerCase();
    return lower.contains('proxy') ||
        lower.contains('socketexception') ||
        lower.contains('connection refused') ||
        lower.contains('network is unreachable');
  }

  static Future<ReturnResult<List<String>>> list(WebdavClient client) async {
    try {
      final entries = await client.readDir('/');
      return ReturnResult(
        data: entries
            .where((entry) => !entry.isDir)
            .map((entry) => entry.name)
            .where((name) => name.isNotEmpty)
            .toList(),
      );
    } catch (err) {
      return ReturnResult(error: ReturnResultError(err.toString()));
    }
  }

  static Future<ReturnResultError?> upload(
    WebdavClient client, {
    required String relativePath,
    required String localPath,
  }) async {
    try {
      await client.writeFile(localPath, '/$relativePath');
      return null;
    } catch (err) {
      return ReturnResultError(err.toString());
    }
  }

  static Future<ReturnResultError?> download(
    WebdavClient client, {
    required String relativePath,
    required String localPath,
  }) async {
    try {
      await client.readFile('/$relativePath', localPath);
      return null;
    } catch (err) {
      return ReturnResultError(err.toString());
    }
  }

  static Future<ReturnResultError?> delete(
    WebdavClient client,
    String relativePath,
  ) async {
    try {
      await client.remove('/$relativePath');
      return null;
    } catch (err) {
      return ReturnResultError(err.toString());
    }
  }
}
