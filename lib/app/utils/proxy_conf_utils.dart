// Reconstructed for the Yousj Enhanced fork (2026-11-14) from call sites:
//  - convertTrafficToStringDouble(int) -> String (22 call sites in the
//    home / tvos / net-connections screens, human-readable byte counts)
//  - getTraffic(HttpHeaders) -> SubscriptionTraffic?
//    (server_manager.dart reloadTraffic; parses the `subscription-userinfo`
//    response header of a HEAD request against the subscription URL)
//  - getUrlFromQRContent(String) -> ReturnResult<String>
//    (add_profile_by_link_or_content_screen.dart; extracts the http(s) URL
//    out of scanned/pasted QR content)

import 'dart:io';

import 'package:karing/app/runtime/return_result.dart';
import 'package:vpn_service/state.dart';

class ProxyConfUtils {
  ProxyConfUtils._();

  static const List<String> _units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];

  /// Human-readable byte count with two decimals once past plain bytes
  /// (e.g. `512 B`, `1.50 KB`, `23.42 GB`). Negative input is clamped to 0
  /// (callers subtract direct traffic from totals).
  static String convertTrafficToStringDouble(int value) {
    var v = value < 0 ? 0 : value;
    if (v < 1024) {
      return '$v B';
    }
    var d = v.toDouble();
    var unit = 0;
    while (d >= 1024 && unit < _units.length - 1) {
      d /= 1024;
      unit++;
    }
    return '${d.toStringAsFixed(2)} ${_units[unit]}';
  }

  /// Parse the standard `subscription-userinfo` header:
  /// `upload=..; download=..; total=..; expire=..` (byte counts, unix
  /// seconds). Returns null when the header is absent or unparseable.
  static SubscriptionTraffic? getTraffic(HttpHeaders headers) {
    final raw = headers.value('subscription-userinfo');
    if (raw == null || raw.isEmpty) {
      return null;
    }
    int upload = 0;
    int download = 0;
    int total = 0;
    int expire = 0;
    var seen = false;
    for (final part in raw.split(';')) {
      final kv = part.trim().split('=');
      if (kv.length != 2) {
        continue;
      }
      final value = int.tryParse(kv[1].trim()) ?? 0;
      switch (kv[0].trim()) {
        case 'upload':
          upload = value;
          seen = true;
          break;
        case 'download':
          download = value;
          seen = true;
          break;
        case 'total':
          total = value;
          seen = true;
          break;
        case 'expire':
          expire = value;
          break;
      }
    }
    if (!seen) {
      return null;
    }
    final traffic = SubscriptionTraffic();
    traffic.upload = convertTrafficToStringDouble(upload);
    traffic.download = convertTrafficToStringDouble(download);
    traffic.total = convertTrafficToStringDouble(total);
    traffic.expire = expire;
    traffic.overQuota = total > 0 && (upload + download) >= total;
    return traffic;
  }

  static final RegExp _urlPattern = RegExp(r'https?://[^\s]+');

  /// Extract the subscription URL from scanned QR content / pasted text.
  static ReturnResult<String> getUrlFromQRContent(String content) {
    final trimmed = content.trim();
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      return ReturnResult<String>(data: trimmed);
    }
    final match = _urlPattern.firstMatch(trimmed);
    if (match != null) {
      return ReturnResult<String>(data: match.group(0));
    }
    return ReturnResult<String>(
      error: ReturnResultError('no url found in content'),
    );
  }
}
