// Reconstructed for the Yousj Enhanced fork (upstream file missing).
//
// API pinned from call sites:
//   * notice_manager.dart:203:
//       ReturnResult<RawNoticeItem> gnotice =
//           await KaringUtils.getNotice(url, checkByProxy);
//     Fetches the app notice document (the RemoteConfig notice URL serves
//     JSON; provider pages may be HTML) and parses it into a
//     RawNoticeItem (defined in notice_utils.dart).

import 'dart:convert';

import 'package:karing/app/runtime/return_result.dart';
import 'package:karing/app/utils/http_utils.dart';
import 'package:karing/app/utils/notice_utils.dart';

class KaringUtils {
  static Future<ReturnResult<RawNoticeItem>> getNotice(
    String url,
    bool byProxy,
  ) async {
    final result = await HttpUtils.httpGetRequest(
      url,
      null,
      null,
      const Duration(seconds: 15),
      null,
      null,
    );
    if (result.error != null) {
      return ReturnResult(error: result.error);
    }
    final content = result.data!.item2;
    // JSON first (the app's own notice feed), HTML as fallback.
    try {
      final decoded = jsonDecode(content);
      if (decoded is Map<String, dynamic>) {
        return ReturnResult(data: RawNoticeItem.fromJsonStatic(decoded));
      }
    } catch (_) {}
    final parsed = await NoticeUtils.parseNotice(content);
    if (parsed == null) {
      return ReturnResult(error: ReturnResultError('notice parse failed'));
    }
    return ReturnResult(data: parsed);
  }
}
