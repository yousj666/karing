// Reconstructed for the Yousj Enhanced fork (upstream file missing).
//
// API pinned from call sites:
//   * user_agreement_screen.dart:156:
//     `_res = await AssetsUtils.loadUserAgreement(isChinese)` — the texts
//     ship as assets/txts/user_agreement_cn.txt and
//     assets/txts/user_agreement_en.txt.

import 'package:flutter/services.dart' show rootBundle;

class AssetsUtils {
  static Future<String> loadUserAgreement(bool isChinese) async {
    final asset = isChinese
        ? 'assets/txts/user_agreement_cn.txt'
        : 'assets/txts/user_agreement_en.txt';
    try {
      return await rootBundle.loadString(asset);
    } catch (_) {
      return '';
    }
  }
}
