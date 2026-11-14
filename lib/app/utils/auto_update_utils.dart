// Reconstructed for the Yousj Enhanced fork (upstream file missing).
//
// API pinned from call sites:
//   * auto_update_manager.dart:391:
//       ReturnResult<List<AutoupdateItem>> items =
//           await AutoupdateUtils.getAutoupdate(body, checkByProxy);
//     Item fields read by the manager: platform (String), updateChannel
//     (String, substring-matched), version / url / sha256 (String),
//     abis (List<String>), channels (List<String>).
//   * remote_config_manager.dart:139:
//       ReturnResult<RemoteConfig> gConfig =
//           await AutoupdateUtils.getRemoteConfig(checkByProxy);
//
// Endpoints come from RemoteConfig's defaults (remote_config.dart):
// config.json and autoupdate.json under https://dot.karing.app/.
// [byProxy] is best-effort: the update endpoints are plain HTTPS and are
// fetched directly; routing them through the local proxy needs the
// running core's port, which only the VPN service layer knows.

import 'dart:convert';

import 'package:karing/app/modules/remote_config.dart';
import 'package:karing/app/modules/remote_config_manager.dart';
import 'package:karing/app/runtime/return_result.dart';
import 'package:karing/app/utils/convert_utils.dart';
import 'package:karing/app/utils/http_utils.dart';

class AutoupdateItem {
  String platform = '';
  String version = '';
  String url = '';
  String sha256 = '';
  String updateChannel = '';
  List<String> abis = [];
  List<String> channels = [];
  String body = '';

  void fromJson(Map<String, dynamic> map) {
    platform = map['platform'] ?? '';
    version = map['version'] ?? '';
    url = map['url'] ?? '';
    sha256 = map['sha256'] ?? '';
    updateChannel = map['update_channel'] ?? map['updateChannel'] ?? '';
    abis =
        ConvertUtils.getListStringFromDynamic(map['abis'], true, []) ?? [];
    channels =
        ConvertUtils.getListStringFromDynamic(map['channels'], true, []) ??
        [];
    body = map['body'] ?? '';
  }

  static AutoupdateItem fromJsonStatic(Map<String, dynamic> map) {
    final item = AutoupdateItem();
    item.fromJson(map);
    return item;
  }
}

class AutoupdateUtils {
  static Future<ReturnResult<RemoteConfig>> getRemoteConfig(
    bool byProxy,
  ) async {
    final result = await HttpUtils.httpGetRequest(
      RemoteConfig.kDefaultConfig,
      null,
      null,
      const Duration(seconds: 15),
      null,
      null,
    );
    if (result.error != null) {
      return ReturnResult(error: result.error);
    }
    try {
      final decoded = jsonDecode(result.data!.item2);
      if (decoded is Map<String, dynamic>) {
        return ReturnResult(data: RemoteConfig.fromJsonStatic(decoded));
      }
      return ReturnResult(error: ReturnResultError('invalid remote config'));
    } catch (err) {
      return ReturnResult(error: ReturnResultError(err.toString()));
    }
  }

  static Future<ReturnResult<List<AutoupdateItem>>> getAutoupdate(
    bool body,
    bool byProxy,
  ) async {
    String url = RemoteConfig.kDefaultAutoUpdate;
    try {
      final configured = RemoteConfigManager.getConfig().autoUpdate;
      if (configured.isNotEmpty) {
        url = configured;
      }
    } catch (_) {}
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
    try {
      final decoded = jsonDecode(result.data!.item2);
      final items = <AutoupdateItem>[];
      final list = decoded is List
          ? decoded
          : (decoded is Map<String, dynamic>
                ? decoded['items'] ?? decoded['versions'] ?? []
                : []);
      if (list is List) {
        for (final entry in list) {
          if (entry is Map<String, dynamic>) {
            items.add(AutoupdateItem.fromJsonStatic(entry));
          } else if (entry is Map) {
            items.add(
              AutoupdateItem.fromJsonStatic(Map<String, dynamic>.from(entry)),
            );
          }
        }
      }
      return ReturnResult(data: items);
    } catch (err) {
      return ReturnResult(error: ReturnResultError(err.toString()));
    }
  }
}
