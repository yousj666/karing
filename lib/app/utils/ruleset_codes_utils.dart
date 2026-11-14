// Reconstructed for the Yousj Enhanced fork (upstream file missing).
//
// API pinned from call sites:
//   * diversion_group_custom_edit_screen.dart:352-354:
//     `_sitecodes ??= await RulesetCodesUtils.siteCodes()` (and ipCodes /
//     aclCodes) — results are List<String>.
//   * my_profiles_screen.dart:1820-1822 and server_manager.dart:923:
//     `await RulesetCodesUtils.siteCodesHashCode()` (and ip/acl variants) —
//     results feed the config builder's int hash parameters, used to decide
//     whether the downloaded rule-set files changed.
//
// The code lists ship as assets (one code per line):
// assets/datas/geosite_codes.txt, geoip_codes.txt, acl_codes.txt.

import 'package:flutter/services.dart' show rootBundle;

class RulesetCodesUtils {
  static List<String>? _siteCodes;
  static List<String>? _ipCodes;
  static List<String>? _aclCodes;
  static String? _siteRaw;
  static String? _ipRaw;
  static String? _aclRaw;

  static Future<String> _loadRaw(String assetPath) async {
    try {
      return await rootBundle.loadString(assetPath);
    } catch (_) {
      return '';
    }
  }

  static List<String> _splitCodes(String raw) {
    return raw
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
  }

  static Future<List<String>> siteCodes() async {
    if (_siteCodes == null) {
      _siteRaw = await _loadRaw('assets/datas/geosite_codes.txt');
      _siteCodes = _splitCodes(_siteRaw!);
    }
    return _siteCodes!;
  }

  static Future<List<String>> ipCodes() async {
    if (_ipCodes == null) {
      _ipRaw = await _loadRaw('assets/datas/geoip_codes.txt');
      _ipCodes = _splitCodes(_ipRaw!);
    }
    return _ipCodes!;
  }

  static Future<List<String>> aclCodes() async {
    if (_aclCodes == null) {
      _aclRaw = await _loadRaw('assets/datas/acl_codes.txt');
      _aclCodes = _splitCodes(_aclRaw!);
    }
    return _aclCodes!;
  }

  /// FNV-1a 32-bit hash of the raw list content: stable per content, so the
  /// builder can detect rule-set updates.

  static Future<Set<int>> siteCodesHashCode() async {
    final codes = await siteCodes();
    return codes.map((c) => c.hashCode).toSet();
  }

  static Future<Set<int>> ipCodesHashCode() async {
    final codes = await ipCodes();
    return codes.map((c) => c.hashCode).toSet();
  }

  static Future<Set<int>> aclCodesHashCode() async {
    final codes = await aclCodes();
    return codes.map((c) => c.hashCode).toSet();
  }
}
