// vpn_service.dart — RECONSTRUCTED by the yousj-plus fork.
//
// Dart facade of the vpn_service plugin. The upstream plugin (private
// repo) wraps the sing-box core through platform channels; this
// reconstruction provides the exact static surface the app calls, as safe
// STUBS: every method returns a neutral default and performs no platform
// work. The real platform bridge lands in reconstruction phase R4.
// Signatures were pinned from call sites in the app (main.dart,
// home_screen.dart, proxy_cluster.dart, settings_screen.dart, ...).

import 'dart:io';

/// Lifecycle state of the VPN service, mirrored from the native side.
enum FlutterVpnServiceState {
  disconnected,
  connecting,
  connected,
  disconnecting,
  reasserting,
  invalid,
}

/// Error object returned by plugin calls that can fail with a
/// user-presentable message (call sites read `.message`).
class FlutterVpnServiceError {
  FlutterVpnServiceError(this.message);

  String message;

  @override
  String toString() => message;
}

class FlutterVpnService {
  // STUB(reconstruction): no platform channel exists yet (phase R4).
  // Defaults are chosen so callers take their "not available" paths
  // instead of crashing.

  /// OS version string shown in the About screen.
  static Future<String> getSystemVersion() async {
    return '';
  }

  /// Android: keep the app out of the recents screen. Returns null on
  /// success, an error message otherwise (settings_screen.dart reads the
  /// value and shows it in an alert dialog).
  static Future<String?> setExcludeFromRecents(bool exclude) async {
    return null;
  }

  /// Whether the privileged helper service (Linux/Windows) is authorized.
  static Future<bool> isServiceAuthorized(String servicePath) async {
    return false;
  }

  /// Authorize the privileged helper service with an admin password.
  /// Returns null on success, an error object otherwise.
  static Future<FlutterVpnServiceError?> authorizeService(
    String servicePath,
    String password,
  ) async {
    return FlutterVpnServiceError('vpn service plugin not implemented');
  }

  /// Windows: add firewall allow rules for the given ports.
  static Future<void> firewallAddPorts(
    List<int> ports,
    String exeName,
  ) async {}

  /// Android: toggle the VPN always-on setting.
  static Future<void> setAlwaysOn(bool enable) async {}

  /// macOS: hide the Dock icon.
  static Future<void> hideDockIcon(bool hide) async {}

  /// Apple platforms: the app-group shared directory.
  static Future<Directory?> getAppGroupDirectory(String groupId) async {
    return null;
  }

  /// Snapshot of the core's Clash-API /connections payload, as raw JSON.
  static Future<String> clashiApiConnections(bool includeProxies) async {
    return '';
  }
}
