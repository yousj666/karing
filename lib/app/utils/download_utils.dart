// Reconstructed for the Yousj Enhanced fork (upstream file missing).
//
// API pinned from call sites:
//   * auto_update_manager.dart:280:
//       ReturnResult<HttpHeaders> result =
//           await DownloadUtils.downloadWithPort(
//               uri, downloadPath, null, false, port);
//     — positional (Uri, savePath, userAgent, resume, proxyPort); the
//     manager loops over candidate ports until one succeeds and checks
//     error.message for "404".

import 'dart:io';

import 'package:karing/app/runtime/return_result.dart';
import 'package:karing/app/utils/http_utils.dart';

class DownloadUtils {
  static Future<ReturnResult<HttpHeaders>> downloadWithPort(
    Uri uri,
    String savePath,
    String? userAgent,
    bool resume,
    int? proxyPort,
  ) {
    return HttpUtils.httpDownload(
      uri,
      savePath,
      proxyPort,
      userAgent,
      resume,
      const Duration(minutes: 10),
    );
  }
}
