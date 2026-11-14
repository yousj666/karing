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

import 'package:karing/app/modules/board_provider_manager.dart';
import 'package:karing/app/runtime/return_result.dart';
import 'package:vpn_service/state.dart';

// Upstream re-exported the plugin model library through this hub:
// most screens import proxy_conf_utils.dart and use ProxyConfig,
// ServerConfigGroupItem, ProxyStrategy, ... from it transitively.
export 'package:vpn_service/state.dart';

class ProxyConfUtils {
  ProxyConfUtils._();

  static const List<String> _units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];

  /// Human-readable byte count with two decimals once past plain bytes
  /// (e.g. `512 B`, `1.50 KB`, `23.42 GB`). Negative input is clamped to 0
  /// (callers subtract direct traffic from totals).
  static String convertTrafficToStringDouble(num value) {
    var v = value < 0 ? 0 : value.toInt();
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

/// Default system-proxy bypass domains (upstream spelling preserved:
/// "Doamins"). `.toList()` at call sites implies a Set.
const Set<String> ProxyBypassDoaminsDefault = {
  'localhost',
  '127.0.0.1',
  '10.0.0.0/8',
  '172.16.0.0/12',
  '192.168.0.0/16',
  '*.local',
};

/// App-side helpers on the plugin's profile model. These live here (not
/// in the plugin) because [getBindProvider] needs app services
/// (BoardProviderManager) that the self-contained plugin cannot see.
extension ServerConfigGroupItemApp on ServerConfigGroupItem {
  /// The subscription's ISP/provider binding info, if any.
  SubscriptionISP? getISP() {
    return isp;
  }

  /// Drops servers whose last latency test failed (latency holds an
  /// error string rather than a numeric delay). Returns true when the
  /// server list changed.
  bool removeLatencyError() {
    final before = servers.length;
    servers.removeWhere(
      (s) => s.latency.isNotEmpty && int.tryParse(s.latency) == null,
    );
    return servers.length != before;
  }

  /// Short human label of the profile's link type for list rows
  /// (my_profiles_screen.dart renders it in a badge).
  String getTypeShort() {
    return type.name;
  }

  /// A stable tag for this group (its groupid).
  String getTag() {
    return groupid;
  }

  /// The board provider this profile is bound to: by ISP id first, then
  /// by matching the profile's site against provider domains.
  BoardProviderConfig? getBindProvider() {
    final ispId = isp?.id ?? '';
    if (ispId.isNotEmpty) {
      final byId = BoardProviderManager.getProviderById(ispId);
      if (byId != null) {
        return byId;
      }
    }
    if (site.isNotEmpty) {
      for (final provider in BoardProviderManager.getProviders()) {
        if (provider.domain == site || provider.domains.contains(site)) {
          return provider;
        }
      }
    }
    return null;
  }
}

/// One file of a backup zip: its name inside the profile directory and
/// whether a backup is invalid without it (server_manager.dart's backup
/// restore reads `.fileName` / `.required` off the entries returned by
/// BackupAndSyncUtils.getZipFileNameList).
class BackupZipFileEntry {
  const BackupZipFileEntry(this.fileName, {this.required = false});

  final String fileName;
  final bool required;
}
