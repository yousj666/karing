// yousj-plus: external AI API.
//
// A small token-guarded HTTP interface served by the app process itself
// (plain dart:io HttpServer; no native/libbox dependency), so external AI
// programs — e.g. an agent running on the user's PC — can inspect profiles,
// switch the selected profile, import new profiles and read/write the
// built-in AI assistant's BYOK settings.
//
// Security model:
// - Off by default. Started/stopped with the app process per the settings
//   toggle; toggling in settings applies immediately.
// - Binds 127.0.0.1 only, unless the user separately enables LAN access.
// - Every endpoint except GET /api/v1/health requires the access token:
//   "Authorization: Bearer <token>" or "X-API-Key: <token>". The token is
//   read from settings on every request and is never written to logs.
// - Actions that need the proxy core (start/stop connection, node
//   switching) are intentionally NOT exposed: the core (libbox) is not
//   integrated in this build, and the status endpoint reports the proxy
//   state truthfully instead of pretending.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:karing/app/local_services/vpn_service.dart';
import 'package:karing/app/modules/server_manager.dart';
import 'package:karing/app/modules/setting_manager.dart';
import 'package:karing/app/runtime/return_result.dart';
import 'package:karing/app/utils/app_utils.dart';
import 'package:karing/app/utils/auto_conf_utils.dart';
import 'package:karing/app/utils/http_utils.dart';
import 'package:karing/app/utils/log.dart';
import 'package:uuid/uuid.dart';
// Note: profile/state types (RemoteContent, ProxyFilter, ProxyStrategy,
// SubscriptionLinkType, ServerConfigGroupItem, FlutterVpnServiceState) are
// re-exported by app/local_services/vpn_service.dart above.

class ExternalApiService {
  // Fixed, uncommon port. Shown in settings so external AI programs know
  // where to connect.
  static const int kPort = 18777;
  static const int kMaxBodyBytes = 10 * 1024 * 1024;

  static HttpServer? _server;
  static bool _boundLan = false;

  // Last start failure (e.g. port already in use), for the settings UI.
  // Never contains the token.
  static String? startError;

  static bool get isRunning => _server != null;

  static SettingConfigItemExternalApi get _config =>
      SettingManager.getConfig().externalApi;

  static String loopbackUrl() => 'http://127.0.0.1:$kPort';

  // The address external programs should use right now: the LAN address
  // when LAN access is enabled and a non-loopback IPv4 exists, otherwise
  // the loopback address.
  static Future<String> currentUrl() async {
    if (_config.allowLan) {
      try {
        final interfaces = await NetworkInterface.list(
          type: InternetAddressType.IPv4,
          includeLoopback: false,
        );
        for (final iface in interfaces) {
          for (final addr in iface.addresses) {
            return 'http://${addr.address}:$kPort';
          }
        }
      } catch (_) {}
    }
    return loopbackUrl();
  }

  // Start/stop/restart the server so it matches the current settings.
  // Called from main() after settings load and from the settings UI
  // whenever a related toggle changes.
  static Future<void> applyFromConfig() async {
    final config = _config;
    if (!config.enable) {
      await stop();
      return;
    }
    if (config.token.isEmpty) {
      config.token = SettingConfigItemExternalApi.generateToken();
      SettingManager.setDirty(true);
      await SettingManager.save();
    }
    if (_server != null && _boundLan == config.allowLan) {
      return;
    }
    await stop();
    await _start();
  }

  static Future<void> stop() async {
    final server = _server;
    _server = null;
    if (server != null) {
      try {
        await server.close(force: true);
      } catch (_) {}
    }
  }

  static Future<void> _start() async {
    final config = _config;
    try {
      final server = await HttpServer.bind(
        config.allowLan
            ? InternetAddress.anyIPv4
            : InternetAddress.loopbackIPv4,
        kPort,
      );
      _server = server;
      _boundLan = config.allowLan;
      startError = null;
      server.listen(
        (HttpRequest request) {
          unawaited(_handle(request));
        },
        onError: (Object err) {
          Log.w("ExternalApiService listen error: ${err.toString()}");
        },
      );
      Log.w(
        "ExternalApiService started on port $kPort (lan=${config.allowLan})",
      );
    } catch (err) {
      _server = null;
      startError = err.toString();
      Log.w("ExternalApiService start failed: ${err.toString()}");
    }
  }

  // --- request handling ----------------------------------------------------

  static bool _authorized(HttpRequest request) {
    final token = _config.token;
    if (token.isEmpty) {
      return false;
    }
    final apiKey = request.headers.value('x-api-key');
    if (apiKey != null && apiKey == token) {
      return true;
    }
    final auth = request.headers.value('authorization');
    if (auth != null && auth.startsWith('Bearer ')) {
      return auth.substring('Bearer '.length).trim() == token;
    }
    return false;
  }

  static Future<void> _sendJson(
    HttpRequest request,
    int statusCode,
    Map<String, dynamic> body,
  ) async {
    final response = request.response;
    response.statusCode = statusCode;
    response.headers.contentType = ContentType(
      'application',
      'json',
      charset: 'utf-8',
    );
    response.write(jsonEncode(body));
    await response.close();
  }

  static Future<void> _ok(HttpRequest request, Map<String, dynamic> data) {
    return _sendJson(request, 200, {'ok': true, 'data': data});
  }

  static Future<void> _fail(HttpRequest request, int statusCode, String error) {
    return _sendJson(request, statusCode, {'ok': false, 'error': error});
  }

  static Future<ReturnResult<Map<String, dynamic>>> _readJsonBody(
    HttpRequest request,
  ) async {
    if ((request.contentLength) > kMaxBodyBytes) {
      return ReturnResult(
        error: ReturnResultError('request body too large', report: false),
      );
    }
    try {
      final text = await utf8.decoder.bind(request).join();
      if (text.length > kMaxBodyBytes) {
        return ReturnResult(
          error: ReturnResultError('request body too large', report: false),
        );
      }
      if (text.trim().isEmpty) {
        return ReturnResult(data: <String, dynamic>{});
      }
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) {
        return ReturnResult(data: decoded);
      }
      return ReturnResult(
        error: ReturnResultError(
          'request body must be a JSON object',
          report: false,
        ),
      );
    } catch (err) {
      return ReturnResult(
        error: ReturnResultError(
          'invalid JSON body: ${err.toString()}',
          report: false,
        ),
      );
    }
  }

  static Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    final method = request.method;
    try {
      if (method == 'GET' && path == '/api/v1/health') {
        await _ok(request, {
          'app': AppUtils.getName(),
          'app_id': AppUtils.getId(),
          'version': AppUtils.getBuildinVersion(),
          'api': 'v1',
          'status': 'running',
        });
        return;
      }
      if (!path.startsWith('/api/v1/')) {
        await _fail(request, 404, 'not found: $method $path');
        return;
      }
      if (!_authorized(request)) {
        await _fail(
          request,
          401,
          'unauthorized: missing or invalid access token',
        );
        return;
      }
      if (method == 'GET' && path == '/api/v1/status') {
        await _handleStatus(request);
        return;
      }
      if (method == 'GET' && path == '/api/v1/profiles') {
        await _ok(request, {
          'profiles': ServerManager.getConfig().items
              .map(_profileData)
              .toList(),
        });
        return;
      }
      if (method == 'POST' && path == '/api/v1/profiles/select') {
        await _handleSelectProfile(request);
        return;
      }
      if (method == 'POST' && path == '/api/v1/profiles/import') {
        await _handleImportProfile(request);
        return;
      }
      if (method == 'GET' && path == '/api/v1/settings/ai') {
        await _ok(request, _aiSettingsData());
        return;
      }
      if (method == 'PUT' && path == '/api/v1/settings/ai') {
        await _handlePutAiSettings(request);
        return;
      }
      await _fail(request, 404, 'not found: $method $path');
    } catch (err) {
      Log.w("ExternalApiService $method $path error: ${err.toString()}");
      try {
        await _fail(request, 500, 'internal error: ${err.toString()}');
      } catch (_) {}
    }
  }

  static Map<String, dynamic> _profileData(ServerConfigGroupItem item) {
    final source = item.isRemote()
        ? 'remote'
        : (item.groupid == ServerManager.getCustomGroupId()
              ? 'custom'
              : 'local');
    return {
      'id': item.groupid,
      'name': item.remark,
      'type': item.type.name,
      'source': source,
      'url_or_path': item.urlOrPath,
      'enabled': item.enable,
      // The app's connection config merges all enabled profiles; with the
      // exclusive selection done by POST /profiles/select, the enabled one
      // is the selected one.
      'selected': item.enable,
      'server_count': item.servers.length,
    };
  }

  static Future<void> _handleStatus(HttpRequest request) async {
    final items = ServerManager.getConfig().items;
    ServerConfigGroupItem? selected;
    final enabledIds = <String>[];
    for (final item in items) {
      if (item.enable) {
        enabledIds.add(item.groupid);
        selected ??= item;
      }
    }
    final state = await VPNService.getState();
    final started = await VPNService.getStarted();
    final running = started && state == FlutterVpnServiceState.connected;
    await _ok(request, {
      'app': AppUtils.getName(),
      'version': AppUtils.getBuildinVersion(),
      'selected_profile_id': selected?.groupid,
      'selected_profile_name': selected?.remark,
      'enabled_profile_ids': enabledIds,
      'profile_count': items.length,
      'proxy_running': running,
      'proxy_state': state.name,
      'proxy_note':
          'The proxy core (libbox) is not integrated in this build yet, so '
          'the proxy is never actually running; proxy_running and '
          'proxy_state are reported truthfully from the app state manager.',
    });
  }

  static Future<void> _handleSelectProfile(HttpRequest request) async {
    final body = await _readJsonBody(request);
    if (body.error != null) {
      await _fail(request, 400, body.error!.message);
      return;
    }
    final id = body.data!['id'];
    if (id is! String || id.isEmpty) {
      await _fail(request, 400, 'field "id" (profile id) is required');
      return;
    }
    final items = ServerManager.getConfig().items;
    ServerConfigGroupItem? target;
    for (final item in items) {
      if (item.groupid == id) {
        target = item;
        break;
      }
    }
    if (target == null) {
      await _fail(request, 404, 'profile not found: $id');
      return;
    }
    // Exclusive selection through the app's existing state management: the
    // chosen profile becomes the (only) enabled one, so the next connection
    // is built from exactly this profile.
    for (final item in items) {
      final want = item.groupid == id;
      if (item.enable != want) {
        await ServerManager.enableGroup(item.groupid, want);
      }
    }
    await ServerManager.saveServerConfig();
    await _ok(request, {
      'selected_profile_id': target.groupid,
      'selected_profile_name': target.remark,
      'note':
          'Selection updated in the app. This only changes which profile '
          'is selected; it does not start the proxy connection.',
    });
  }

  static Future<void> _handleImportProfile(HttpRequest request) async {
    final body = await _readJsonBody(request);
    if (body.error != null) {
      await _fail(request, 400, body.error!.message);
      return;
    }
    final contentRaw = body.data!['content'];
    if (contentRaw is! String || contentRaw.trim().isEmpty) {
      await _fail(
        request,
        400,
        'field "content" (sing-box JSON or Clash YAML text) is required',
      );
      return;
    }
    final content = contentRaw.trim();
    var remark = '';
    final remarkRaw = body.data!['remark'];
    if (remarkRaw != null) {
      if (remarkRaw is! String) {
        await _fail(request, 400, 'field "remark" must be a string');
        return;
      }
      remark = remarkRaw.trim();
    }
    if (remark.isEmpty) {
      final now = DateTime.now();
      String two(int v) => v.toString().padLeft(2, '0');
      remark =
          'AI 导入 ${two(now.hour)}:${two(now.minute)}:${two(now.second)}';
    }
    if (remark.length > kRemarkMaxLength) {
      await _fail(
        request,
        400,
        'remark too long (max $kRemarkMaxLength characters)',
      );
      return;
    }
    if (ServerManager.hasGroupByRemark(remark)) {
      await _fail(request, 400, 'remark already exists: $remark');
      return;
    }

    // Same import pipeline as the add-profile UI: the raw content travels
    // as RemoteContent, conversion (incl. Clash -> sing-box and WireGuard
    // endpoints) happens in AutoConfUtils via ServerManager.addRemoteConfig.
    // A unique urlOrPath marker keeps the new profile from being mistaken
    // for an update of an existing one.
    final remoteContent = RemoteContent()..text = content;
    final result = await ServerManager.addRemoteConfig(
      '',
      remark,
      'api-import:${const Uuid().v4()}',
      SubscriptionLinkType.unknown,
      true,
      HttpUtils.getUserAgents(),
      false,
      ProxyFilter(),
      const [],
      false,
      false,
      false,
      false,
      false,
      ProxyStrategy.preferProxy,
      remoteContent,
      null,
    );
    if (result.error != null || result.data == null) {
      await _fail(
        request,
        400,
        'import failed: ${result.error?.message ?? 'unknown error'}',
      );
      return;
    }
    ServerManager.setDirty(true);
    final item = result.data!;
    await _ok(request, {
      'profile_id': item.groupid,
      'name': item.remark,
      'type': item.type.name,
      'server_count': item.servers.length,
      'skipped_unconvertible': AutoConfUtils.skippedUnconvertible,
    });
  }

  static Map<String, dynamic> _aiSettingsData() {
    final ai = SettingManager.getConfig().ai;
    return {
      'base_url': ai.baseUrl,
      'model': ai.model,
      // The key itself is never returned, only whether one is stored.
      'api_key_set': ai.apiKey.isNotEmpty,
      'configured': ai.isConfigured,
    };
  }

  static Future<void> _handlePutAiSettings(HttpRequest request) async {
    final body = await _readJsonBody(request);
    if (body.error != null) {
      await _fail(request, 400, body.error!.message);
      return;
    }
    final map = body.data!;
    // Returns null when the field is absent, the string (possibly empty,
    // e.g. to clear the key) when present, or a non-String marker value
    // that the type check below rejects.
    Object? pickRaw(String camel, String snake) {
      if (map.containsKey(camel)) {
        return map[camel];
      }
      if (map.containsKey(snake)) {
        return map[snake];
      }
      return null;
    }

    final baseUrlRaw = pickRaw('baseUrl', 'base_url');
    final apiKeyRaw = pickRaw('apiKey', 'api_key');
    final modelRaw = pickRaw('model', 'model');
    for (final entry in {
      'baseUrl': baseUrlRaw,
      'apiKey': apiKeyRaw,
      'model': modelRaw,
    }.entries) {
      if (entry.value != null && entry.value is! String) {
        await _fail(request, 400, 'field "${entry.key}" must be a string');
        return;
      }
    }
    final baseUrl = baseUrlRaw as String?;
    final apiKey = apiKeyRaw as String?;
    final model = modelRaw as String?;
    if (baseUrl == null && apiKey == null && model == null) {
      await _fail(
        request,
        400,
        'no fields to update: provide baseUrl, apiKey and/or model',
      );
      return;
    }
    final ai = SettingManager.getConfig().ai;
    if (baseUrl != null) {
      ai.baseUrl = baseUrl.trim();
    }
    if (apiKey != null) {
      ai.apiKey = apiKey.trim();
    }
    if (model != null) {
      ai.model = model.trim();
    }
    SettingManager.setDirty(true);
    await SettingManager.save();
    await _ok(request, _aiSettingsData());
  }
}
