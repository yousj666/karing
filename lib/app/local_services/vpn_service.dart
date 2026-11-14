// vpn_service.dart (app layer) — RECONSTRUCTED by the yousj-plus fork (R3).
//
// The app-facing VPN service facade. Upstream this file wrapped the
// private vpn_service plugin: it kept the "current" profile selection,
// assembled the sing-box core config via SingboxConfigBuilder, tracked
// lifecycle state, and re-exported the plugin libraries so screens could
// use the shared models (ProxyConfig, ServerConfigGroupItem, ...) through
// this single import.
//
// This reconstruction keeps that exact shape:
//  * the plugin libraries are re-exported below (transitive-import
//    contract — many screens rely on it);
//  * config assembly in [VPNService.setServer] is REAL: it drives the
//    same builder pipeline the profile-share screen uses and writes the
//    JSON config to the requested path;
//  * lifecycle/system operations delegate to the FlutterVpnService plugin
//    stubs, which perform no platform work until phase R4 lands the real
//    native bridge. Where the plugin has no surface yet, the wrapper
//    keeps in-memory state and says so — start/reload honestly report
//    "not implemented" instead of pretending a tunnel exists.

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:karing/app/modules/server_manager.dart';
import 'package:karing/app/modules/setting_manager.dart';
import 'package:karing/app/runtime/return_result.dart';
import 'package:karing/app/utils/clash_api.dart';
import 'package:karing/app/utils/ruleset_codes_utils.dart';
import 'package:karing/app/utils/singbox_config_builder.dart';
import 'package:karing/app/utils/singbox_outbound.dart';
import 'package:tuple/tuple.dart';
import 'package:vpn_service/state.dart';
import 'package:vpn_service/vpn_service.dart';

export 'package:karing/app/utils/singbox_outbound.dart';
export 'package:vpn_service/state.dart';
export 'package:vpn_service/vpn_service.dart';

/// Options threaded through [VPNService.setServer]: localized error
/// strings for the three validation failures, plus the set of outbound
/// tags the assembled config ended up with (home_screen.dart reads
/// `allOutboundsTags.length` right after setServer to sanity-check the
/// result).
class VPNServiceSetServerOptions {
  String disabledServerError = '';
  String invalidServerError = '';
  String expiredServerError = '';
  Set<String> allOutboundsTags = {};
}

class VPNService {
  VPNService._();

  /// State-change listeners (home_screen.dart, server_manager.dart add
  /// and remove their callbacks here).
  static final List<
    Future<void> Function(FlutterVpnServiceState, Map<String, String>)
  >
  onEventStateChanged = [];

  static ServerConfigGroupItem? _current;
  static ProxyConfig? _currentServer;
  static CurrentServerForUrltest? _currentServerForUrltest;
  static FlutterVpnServiceState _state = FlutterVpnServiceState.disconnected;
  static bool _started = false;
  static bool _systemProxyEnabled = false;
  static bool _launchAtStartup = false;

  // --- lifecycle ---------------------------------------------------------

  static Future<void> init() async {
    // The plugin facade has no init handshake yet (R4); state starts
    // disconnected, matching the stub core.
  }

  static Future<void> uninit() async {}

  static Future<void> initABI() async {
    // ABI probing is synchronous via [getABIs]; nothing to prepare.
  }

  static Future<void> prepareFiles() async {
    // Core binaries/assets ship with the app bundle; nothing to extract
    // in this reconstruction.
  }

  static Future<ReturnResultError?> uninstall() async {
    // Helper-service removal is platform work (R4).
    return null;
  }

  // --- current selection ---------------------------------------------------

  /// Records the currently selected node (home_screen.dart keeps its
  /// selection as a ProxyConfig, not a group).
  static void setCurrent(ProxyConfig server) {
    _currentServer = server;
  }

  static ServerConfigGroupItem getCurrent() {
    if (_current != null) {
      return _current!;
    }
    final server = _currentServer;
    if (server != null) {
      for (final group in ServerManager.getConfig().items) {
        if (group.groupid == server.groupid) {
          return _current = group;
        }
      }
    }
    return _current ??= ServerConfigGroupItem();
  }

  static void setCurrentServerForUrltest(CurrentServerForUrltest current) {
    _currentServerForUrltest = current;
  }

  static String getCurrentRealTag() {
    final urltest = _currentServerForUrltest;
    if (urltest != null && urltest.now.isNotEmpty) {
      return urltest.now;
    }
    if (_currentServer != null) {
      return _currentServer!.tag;
    }
    final item = _current;
    if (item != null && item.servers.isNotEmpty) {
      return item.servers.first.tag;
    }
    return '';
  }

  static bool currentIsDirect() {
    final server = _currentServer ??
        ((_current != null && _current!.servers.isNotEmpty)
            ? _current!.servers.first
            : null);
    if (server == null) {
      return false;
    }
    return server.type == kOutboundTypeDirect ||
        server.tag == kOutboundTagDirect;
  }

  // --- config assembly -----------------------------------------------------

  /// Validates [item], builds its sing-box config through
  /// [SingboxConfigBuilder] (same pipeline as the profile-share screen)
  /// and writes the JSON to [savePath]. [secret] is the Clash-API secret
  /// the core must be started with; the builder's config model has no
  /// `experimental` slot yet, so threading the secret into the generated
  /// config lands with the R4 core wiring — the parameter is part of the
  /// contract and intentionally accepted here.
  static Future<ReturnResultError?> setServer(
    ServerConfigGroupItem item,
    VPNServiceSetServerOptions options,
    SingboxExportType exportType,
    String? host,
    String secret,
    String savePath,
  ) async {
    _current = item;
    if (!item.enable) {
      return ReturnResultError(options.disabledServerError);
    }
    if (item.servers.isEmpty) {
      return ReturnResultError(options.invalidServerError);
    }
    final tunMode = SettingManager.getConfig().tun.enable;

    final diversionGroupsResult = ServerManager.getDiversionGroups();
    if (diversionGroupsResult.error != null) {
      return diversionGroupsResult.error;
    }

    final config = SingboxConfig();
    final selectOutbound = SingboxConfigBuilder.buildOutbound(
      ServerManager.getUrltest(),
    );
    final selectTags = <String>{};
    final allOutBounds = <dynamic>[];
    for (final server in item.servers) {
      selectTags.add(server.tag);
      final bound = SingboxConfigBuilder.buildOutbound(server);
      if (bound != null) {
        allOutBounds.add(bound);
      }
    }
    config.ntp = SingboxConfigBuilder.ntp();
    final dns = SingboxConfigBuilder.dns(tunMode, exportType, null, null);
    if (dns.error != null) {
      return dns.error;
    }
    config.dns = dns.data!;
    config.inbounds = SingboxConfigBuilder.inbounds(tunMode, exportType);
    final outbounds = SingboxConfigBuilder.outbounds(
      '',
      selectTags,
      {},
      selectOutbound,
      allOutBounds,
      null,
      {},
      [],
      null,
      exportType,
    );
    if (outbounds.error != null) {
      return outbounds.error;
    }
    config.outbounds = outbounds.data!;
    config.endpoints = SingboxConfigBuilder.endpoints(config.outbounds);
    config.route = SingboxConfigBuilder.route(
      '',
      '',
      '',
      '',
      await RulesetCodesUtils.siteCodesHashCode(),
      await RulesetCodesUtils.ipCodesHashCode(),
      await RulesetCodesUtils.aclCodesHashCode(),
      tunMode,
      allOutBounds,
      {},
      null,
      diversionGroupsResult.data!,
      config.inbounds,
      config.dns,
      null,
      null,
      null,
      item.groupid,
      exportType,
    );

    try {
      await File(
        savePath,
      ).writeAsString(const JsonEncoder.withIndent('  ').convert(config.toJson()));
    } catch (e) {
      return ReturnResultError(e.toString());
    }

    options.allOutboundsTags = {
      for (final bound in [...config.outbounds, ...config.endpoints])
        if (bound is Map && bound['tag'] is String) bound['tag'] as String,
    };
    return null;
  }

  // --- run control -----------------------------------------------------------

  static Future<bool> getStarted() async {
    return _started;
  }

  static Future<FlutterVpnServiceState> getState() async {
    return _state;
  }

  static Future<bool> getTunMode() async {
    return SettingManager.getConfig().tun.enable;
  }

  static Future<ReturnResultError?> start(Duration timeout) async {
    // The plugin stub has no core to launch (R4). Report honestly so the
    // UI surfaces it instead of showing a phantom connection.
    _state = FlutterVpnServiceState.disconnected;
    _started = false;
    return ReturnResultError('vpn service plugin not implemented');
  }

  static Future<ReturnResultError?> reload(Duration timeout) async {
    if (!_started) {
      return null;
    }
    return ReturnResultError('vpn service plugin not implemented');
  }

  static Future<void> stop() async {
    _started = false;
    _state = FlutterVpnServiceState.disconnected;
  }

  /// Startup/reload budget grows with the outbound count (each outbound
  /// may need a handshake); capped so a huge profile cannot hang forever.
  static Duration getTimeoutByOutboundCount(int count, bool tunMode) {
    final seconds = 30 + count * 2 + (tunMode ? 15 : 0);
    return Duration(seconds: seconds > 300 ? 300 : seconds);
  }

  // --- ports -----------------------------------------------------------------

  /// Candidate listen ports for the core, ordered by [strategy]
  /// (server_manager.dart probes them in order with HTTP HEAD requests).
  static Future<List<int?>> getPortsBySetting(ProxyStrategy strategy) async {
    final proxy = SettingManager.getConfig().proxy;
    switch (strategy) {
      case ProxyStrategy.preferProxy:
        return [proxy.mixedRulePort, proxy.mixedForwardPort, proxy.mixedDirectPort];
      case ProxyStrategy.preferDirect:
        return [proxy.mixedDirectPort, proxy.mixedRulePort, proxy.mixedForwardPort];
      case ProxyStrategy.onlyProxy:
        return [proxy.mixedRulePort];
      case ProxyStrategy.onlyDirect:
        return [proxy.mixedDirectPort];
    }
  }

  /// Download port candidates (auto_update_utils.dart): a null entry
  /// means "connect directly".
  static Future<List<int?>> getPortsByPrefer(bool preferProxy) async {
    final proxy = SettingManager.getConfig().proxy;
    if (preferProxy) {
      return [proxy.mixedRulePort, proxy.mixedForwardPort, null];
    }
    return [null, proxy.mixedDirectPort, proxy.mixedRulePort];
  }

  // --- outbound / urltest inventories -----------------------------------------

  /// Fills [outbounds] with every concrete server of every group and
  /// collects their tags into [allTags] (urltest/selector pseudo-nodes
  /// excluded). The two trailing parameters are part of the upstream
  /// signature and unused by callers.
  static void getOutboundsWithoutUrltest(
    Set<String> allTags,
    Tuple2<List<ProxyConfig>, List<dynamic>>? outbounds,
    dynamic unused1,
    dynamic unused2,
  ) {
    for (final group in ServerManager.getConfig().items) {
      for (final server in group.servers) {
        if (server.type == kOutboundTypeUrltest ||
            server.type == kOutboundTypeSelector) {
          continue;
        }
        outbounds?.item1.add(server);
        allTags.add(server.tag);
      }
    }
  }

  /// One urltest definition per group that has servers in [tags]; the
  /// tuple's second element is the owning group (server_select_screen.dart
  /// only consumes item1 today; the group is the useful context).
  static List<Tuple2<SingboxOutboundUrltest, ServerConfigGroupItem>>
  getUrltests(
    Set<String> tags, {
    bool uniTag = false,
    bool includeEmpty = false,
  }) {
    final ret = <Tuple2<SingboxOutboundUrltest, ServerConfigGroupItem>>[];
    var index = 0;
    for (final group in ServerManager.getConfig().items) {
      final members = group.servers
          .where((s) => tags.isEmpty || tags.contains(s.tag))
          .map((s) => s.tag)
          .toList();
      if (members.isEmpty && !includeEmpty) {
        continue;
      }
      final urltest = SingboxOutboundUrltest();
      urltest.tag = uniTag
          ? kOutboundTagUrltest
          : (group.groupid.isNotEmpty
                ? '${group.groupid}_$kOutboundTagUrltest'
                : '${kOutboundTagUrltest}_${index++}');
      urltest.outbounds = members;
      ret.add(Tuple2(urltest, group));
    }
    return ret;
  }

  // --- system integration -------------------------------------------------------

  static bool isRunAsAdmin() {
    // Real elevation checks are platform-specific (R4); false makes the
    // UI offer its "run as admin" hints, which is the safe default.
    return false;
  }

  static List<String> getABIs() {
    return [Abi.current().toString()];
  }

  static Future<bool> getSystemProxyEnable() async {
    // In-memory until the plugin grows real OS proxy accessors (R4).
    return _systemProxyEnabled;
  }

  static Future<void> setSystemProxy(bool enable) async {
    _systemProxyEnabled = enable;
  }

  static Future<bool> getLaunchAtStartup() async {
    return _launchAtStartup;
  }

  static Future<ReturnResultError?> setLaunchAtStartup(bool enable) async {
    // Registry/LaunchAgent writes are platform work (R4); the flag keeps
    // the settings toggle coherent within the session.
    _launchAtStartup = enable;
    return null;
  }

  /// Normalizes a plugin call result into the app's error type
  /// (home_screen.dart wraps FlutterVpnService.authorizeService results).
  static ReturnResultError? convertErr(dynamic err) {
    if (err == null) {
      return null;
    }
    if (err is ReturnResultError) {
      return err;
    }
    if (err is FlutterVpnServiceError) {
      return ReturnResultError(err.message);
    }
    return ReturnResultError(err.toString());
  }
}
