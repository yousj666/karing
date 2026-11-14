// Reconstructed for the Yousj Enhanced fork (upstream file missing).
//
// API pinned from call sites:
//   * settings_screen.dart:1625: a WARP license is accepted when
//     `license.length == CloudflareWarpApi.licenseLength`.
//   * setting_manager.dart:36: `WarpAccount account = WarpAccount();`
//     (the field lives on SettingConfigItemUICloudflareWarp; its
//     serialization is currently commented out upstream, so only the
//     model shape matters here).
//
// Cloudflare WARP license keys are 26 characters in the
// "xxxxxxxx-xxxxxxxx-xxxxxxxx" form issued by the 1.1.1.1 app.

class CloudflareWarpApi {
  static const int licenseLength = 26;
}

/// A Cloudflare WARP account record (api.cloudflareclient.com model).
class WarpAccount {
  String id = '';
  String accountType = '';
  String name = '';
  String license = '';
  bool premium = false;
  int quota = 0;
  String created = '';
  String updated = '';

  Map<String, dynamic> toJson() => {
    'id': id,
    'account_type': accountType,
    'name': name,
    'license': license,
    'premium': premium,
    'quota': quota,
    'created': created,
    'updated': updated,
  };

  void fromJson(Map<String, dynamic>? map) {
    if (map == null) {
      return;
    }
    id = map['id'] ?? '';
    accountType = map['account_type'] ?? '';
    name = map['name'] ?? '';
    license = map['license'] ?? '';
    premium = map['premium'] ?? false;
    final q = map['quota'];
    quota = q is num ? q.toInt() : 0;
    created = map['created'] ?? '';
    updated = map['updated'] ?? '';
  }

  static WarpAccount fromJsonStatic(Map<String, dynamic>? map) {
    final account = WarpAccount();
    account.fromJson(map);
    return account;
  }
}
