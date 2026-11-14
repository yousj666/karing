// Reconstructed for the Yousj Enhanced fork (upstream file missing).
//
// API pinned from call sites:
//   * my_profiles_screen.dart (add/edit server flows):
//       SingboxOutboundType.getNames() -> List<String> of editable types;
//       SingboxOutboundType.socks.name;
//       var o = SingboxOutboundOptions();
//       o.type / o.tag (String), o.server (String), o.server_port (int);
//       o.<protocol> = SingboxOutbound<Protocol>Options() for each of the
//         23 protocols (fields: shadowsocks, shadowsocksr, shadowtls,
//         vmess, vless, trojan, socks, http, hysteria, hysteria2, wg, tuic,
//         tor, ssh, anytls, naive, snell, tailscale, openvpn, mieru,
//         sudoku, trusttunnel, masque);
//       o.dialer?.detour (String?);
//       o.<protocol>!.getRequired() -> String? (first missing required
//         field name, null when complete);
//       o.<protocol>!.server (String?) / .server_port (int?);
//       o.fromJson(server.raw); o.toJson() -> Map (stored into
//         ProxyConfig.raw); o.isValid() -> bool;
//       await o.getWidgetOptions(context, setstate) -> List<GroupItem>.
//   * setting_manager.dart: SingboxOutboundMultiplexBrutalOptions with
//     toJson() and static fromJsonStatic(Map?) (the mux "brutal" options).
//   * server_select_screen.dart: SingboxOutboundUrltest with .tag (String)
//     and .outbounds (List<String>), produced by VPNService.getUrltests().
//
// Protocol option fields follow the sing-box outbound JSON schema. Only
// `server`/`server_port` are accessed as typed fields by the surviving
// code; the remaining fields round-trip through a spec-driven value map
// so unknown keys survive an edit unchanged.

import 'package:flutter/widgets.dart';
import 'package:karing/screens/group_item_creator.dart';
import 'package:karing/screens/group_item_options.dart';

enum SingboxOutboundType {
  shadowsocks,
  shadowsocksr,
  shadowtls,
  vmess,
  vless,
  trojan,
  socks,
  http,
  hysteria,
  hysteria2,
  wireguard,
  tuic,
  tor,
  ssh,
  anytls,
  naive,
  snell,
  tailscale,
  openvpn,
  mieru,
  sudoku,
  trusttunnel,
  masque,
  direct,
  block,
  dns,
  selector,
  urltest;

  /// Type names offered by the "add server" picker. Note the openvpn
  /// entry is spelled "openvpn-client" (that is the case the add/edit
  /// switch matches on).
  static List<String> getNames() {
    return [
      shadowsocks.name,
      shadowsocksr.name,
      shadowtls.name,
      vmess.name,
      vless.name,
      trojan.name,
      socks.name,
      http.name,
      hysteria.name,
      hysteria2.name,
      wireguard.name,
      tuic.name,
      tor.name,
      ssh.name,
      anytls.name,
      naive.name,
      snell.name,
      tailscale.name,
      'openvpn-client',
      mieru.name,
      sudoku.name,
      trusttunnel.name,
      masque.name,
    ];
  }
}

enum SingboxFieldKind { string, integer, boolean, stringList, map, any }

class SingboxFieldSpec {
  final String key;
  final SingboxFieldKind kind;
  final bool required;
  const SingboxFieldSpec(
    this.key,
    this.kind, {
    this.required = false,
  });
}

abstract class SingboxOutboundBaseOptions {
  String? server;
  int? serverPort;

  final Map<String, dynamic> _values = {};

  String get typeName;
  List<SingboxFieldSpec> get fieldSpecs;

  /// Tor and Tailscale outbounds have no server endpoint.
  bool get requiresServer => true;

  int? get server_port => serverPort;
  set server_port(int? value) => serverPort = value;

  dynamic operator [](String key) => _values[key];
  void operator []=(String key, dynamic value) {
    _values[key] = value;
  }

  /// Name of the first missing required field, or null when complete.
  String? getRequired() {
    if (requiresServer) {
      if ((server ?? '').trim().isEmpty) {
        return 'server';
      }
      if ((serverPort ?? 0) <= 0) {
        return 'server_port';
      }
    }
    for (final spec in fieldSpecs) {
      if (!spec.required) {
        continue;
      }
      final value = _values[spec.key];
      if (value == null || (value is String && value.trim().isEmpty)) {
        return spec.key;
      }
    }
    return null;
  }

  Map<String, dynamic> toJson() {
    final ret = <String, dynamic>{'type': typeName};
    if (server != null) {
      ret['server'] = server;
    }
    if (serverPort != null) {
      ret['server_port'] = serverPort;
    }
    _values.forEach((key, value) {
      if (value != null) {
        ret[key] = value;
      }
    });
    return ret;
  }

  void fromJson(Map<String, dynamic>? map) {
    if (map == null) {
      return;
    }
    server = map['server'] as String?;
    final port = map['server_port'];
    serverPort = port is num
        ? port.toInt()
        : (port is String ? int.tryParse(port) : null);
    map.forEach((key, value) {
      if (key == 'type' ||
          key == 'tag' ||
          key == 'server' ||
          key == 'server_port') {
        return;
      }
      _values[key] = value;
    });
  }
}

class SingboxOutboundShadowsocksOptions extends SingboxOutboundBaseOptions {
  @override
  String get typeName => 'shadowsocks';
  @override
  List<SingboxFieldSpec> get fieldSpecs => const [
    SingboxFieldSpec('method', SingboxFieldKind.string, required: true),
    SingboxFieldSpec('password', SingboxFieldKind.string, required: true),
    SingboxFieldSpec('plugin', SingboxFieldKind.string),
    SingboxFieldSpec('plugin_opts', SingboxFieldKind.string),
    SingboxFieldSpec('udp_over_tcp', SingboxFieldKind.any),
    SingboxFieldSpec('network', SingboxFieldKind.string),
    SingboxFieldSpec('multiplex', SingboxFieldKind.map),
  ];
}

class SingboxOutboundShadowsocksROptions extends SingboxOutboundBaseOptions {
  @override
  String get typeName => 'shadowsocksr';
  @override
  List<SingboxFieldSpec> get fieldSpecs => const [
    SingboxFieldSpec('method', SingboxFieldKind.string, required: true),
    SingboxFieldSpec('password', SingboxFieldKind.string, required: true),
    SingboxFieldSpec('obfs', SingboxFieldKind.string),
    SingboxFieldSpec('obfs_param', SingboxFieldKind.string),
    SingboxFieldSpec('protocol', SingboxFieldKind.string),
    SingboxFieldSpec('protocol_param', SingboxFieldKind.string),
  ];
}

class SingboxOutboundShadowTLSOptions extends SingboxOutboundBaseOptions {
  @override
  String get typeName => 'shadowtls';
  @override
  List<SingboxFieldSpec> get fieldSpecs => const [
    SingboxFieldSpec('version', SingboxFieldKind.integer),
    SingboxFieldSpec('password', SingboxFieldKind.string, required: true),
    SingboxFieldSpec('tls', SingboxFieldKind.map),
  ];
}

class SingboxOutboundVMessOptions extends SingboxOutboundBaseOptions {
  @override
  String get typeName => 'vmess';
  @override
  List<SingboxFieldSpec> get fieldSpecs => const [
    SingboxFieldSpec('uuid', SingboxFieldKind.string, required: true),
    SingboxFieldSpec('security', SingboxFieldKind.string),
    SingboxFieldSpec('alter_id', SingboxFieldKind.integer),
    SingboxFieldSpec('global_padding', SingboxFieldKind.boolean),
    SingboxFieldSpec('authenticated_length', SingboxFieldKind.boolean),
    SingboxFieldSpec('packet_encoding', SingboxFieldKind.string),
    SingboxFieldSpec('transport', SingboxFieldKind.map),
    SingboxFieldSpec('tls', SingboxFieldKind.map),
    SingboxFieldSpec('multiplex', SingboxFieldKind.map),
  ];
}

class SingboxOutboundVLESSOptions extends SingboxOutboundBaseOptions {
  @override
  String get typeName => 'vless';
  @override
  List<SingboxFieldSpec> get fieldSpecs => const [
    SingboxFieldSpec('uuid', SingboxFieldKind.string, required: true),
    SingboxFieldSpec('flow', SingboxFieldKind.string),
    SingboxFieldSpec('packet_encoding', SingboxFieldKind.string),
    SingboxFieldSpec('transport', SingboxFieldKind.map),
    SingboxFieldSpec('tls', SingboxFieldKind.map),
    SingboxFieldSpec('multiplex', SingboxFieldKind.map),
  ];
}

class SingboxOutboundTrojanOptions extends SingboxOutboundBaseOptions {
  @override
  String get typeName => 'trojan';
  @override
  List<SingboxFieldSpec> get fieldSpecs => const [
    SingboxFieldSpec('password', SingboxFieldKind.string, required: true),
    SingboxFieldSpec('transport', SingboxFieldKind.map),
    SingboxFieldSpec('tls', SingboxFieldKind.map),
    SingboxFieldSpec('multiplex', SingboxFieldKind.map),
  ];
}

class SingboxOutboundSocksOptions extends SingboxOutboundBaseOptions {
  @override
  String get typeName => 'socks';
  @override
  List<SingboxFieldSpec> get fieldSpecs => const [
    SingboxFieldSpec('version', SingboxFieldKind.string),
    SingboxFieldSpec('username', SingboxFieldKind.string),
    SingboxFieldSpec('password', SingboxFieldKind.string),
    SingboxFieldSpec('udp_over_tcp', SingboxFieldKind.any),
    SingboxFieldSpec('network', SingboxFieldKind.string),
  ];
}

class SingboxOutboundHTTPOptions extends SingboxOutboundBaseOptions {
  @override
  String get typeName => 'http';
  @override
  List<SingboxFieldSpec> get fieldSpecs => const [
    SingboxFieldSpec('username', SingboxFieldKind.string),
    SingboxFieldSpec('password', SingboxFieldKind.string),
    SingboxFieldSpec('path', SingboxFieldKind.string),
    SingboxFieldSpec('headers', SingboxFieldKind.map),
    SingboxFieldSpec('tls', SingboxFieldKind.map),
  ];
}

class SingboxOutboundHysteriaOptions extends SingboxOutboundBaseOptions {
  @override
  String get typeName => 'hysteria';
  @override
  List<SingboxFieldSpec> get fieldSpecs => const [
    SingboxFieldSpec('up', SingboxFieldKind.string),
    SingboxFieldSpec('down', SingboxFieldKind.string),
    SingboxFieldSpec('up_mbps', SingboxFieldKind.integer),
    SingboxFieldSpec('down_mbps', SingboxFieldKind.integer),
    SingboxFieldSpec('obfs', SingboxFieldKind.string),
    SingboxFieldSpec('auth', SingboxFieldKind.any),
    SingboxFieldSpec('auth_str', SingboxFieldKind.string),
    SingboxFieldSpec('server_ports', SingboxFieldKind.stringList),
    SingboxFieldSpec('recv_window_conn', SingboxFieldKind.integer),
    SingboxFieldSpec('recv_window', SingboxFieldKind.integer),
    SingboxFieldSpec('disable_mtu_discovery', SingboxFieldKind.boolean),
    SingboxFieldSpec('tls', SingboxFieldKind.map),
  ];
}

class SingboxOutboundHysteria2Options extends SingboxOutboundBaseOptions {
  @override
  String get typeName => 'hysteria2';
  @override
  List<SingboxFieldSpec> get fieldSpecs => const [
    SingboxFieldSpec('password', SingboxFieldKind.any, required: true),
    SingboxFieldSpec('obfs', SingboxFieldKind.map),
    SingboxFieldSpec('up_mbps', SingboxFieldKind.integer),
    SingboxFieldSpec('down_mbps', SingboxFieldKind.integer),
    SingboxFieldSpec('server_ports', SingboxFieldKind.stringList),
    SingboxFieldSpec('hop_interval', SingboxFieldKind.string),
    SingboxFieldSpec('tls', SingboxFieldKind.map),
  ];
}

class SingboxOutboundWireGuardOptions extends SingboxOutboundBaseOptions {
  @override
  String get typeName => 'wireguard';
  @override
  List<SingboxFieldSpec> get fieldSpecs => const [
    SingboxFieldSpec('private_key', SingboxFieldKind.string, required: true),
    SingboxFieldSpec('peer_public_key', SingboxFieldKind.string),
    SingboxFieldSpec('pre_shared_key', SingboxFieldKind.string),
    SingboxFieldSpec('reserved', SingboxFieldKind.any),
    SingboxFieldSpec('local_address', SingboxFieldKind.stringList),
    SingboxFieldSpec('mtu', SingboxFieldKind.integer),
    SingboxFieldSpec('workers', SingboxFieldKind.integer),
  ];
}

class SingboxOutboundTUICOptions extends SingboxOutboundBaseOptions {
  @override
  String get typeName => 'tuic';
  @override
  List<SingboxFieldSpec> get fieldSpecs => const [
    SingboxFieldSpec('uuid', SingboxFieldKind.string, required: true),
    SingboxFieldSpec('password', SingboxFieldKind.string),
    SingboxFieldSpec('congestion_control', SingboxFieldKind.string),
    SingboxFieldSpec('udp_relay_mode', SingboxFieldKind.string),
    SingboxFieldSpec('udp_over_tcp', SingboxFieldKind.any),
    SingboxFieldSpec('zero_rtt_handshake', SingboxFieldKind.boolean),
    SingboxFieldSpec('heartbeat', SingboxFieldKind.string),
    SingboxFieldSpec('tls', SingboxFieldKind.map),
  ];
}

class SingboxOutboundTorOptions extends SingboxOutboundBaseOptions {
  @override
  String get typeName => 'tor';
  @override
  bool get requiresServer => false;
  @override
  List<SingboxFieldSpec> get fieldSpecs => const [
    SingboxFieldSpec('executable_path', SingboxFieldKind.string),
    SingboxFieldSpec('extra_args', SingboxFieldKind.stringList),
    SingboxFieldSpec('data_directory', SingboxFieldKind.string),
  ];
}

class SingboxOutboundSSHOptions extends SingboxOutboundBaseOptions {
  @override
  String get typeName => 'ssh';
  @override
  List<SingboxFieldSpec> get fieldSpecs => const [
    SingboxFieldSpec('user', SingboxFieldKind.string),
    SingboxFieldSpec('password', SingboxFieldKind.string),
    SingboxFieldSpec('private_key', SingboxFieldKind.any),
    SingboxFieldSpec('private_key_path', SingboxFieldKind.string),
    SingboxFieldSpec('private_key_passphrase', SingboxFieldKind.string),
    SingboxFieldSpec('host_key', SingboxFieldKind.stringList),
    SingboxFieldSpec('host_key_algorithms', SingboxFieldKind.stringList),
    SingboxFieldSpec('client_version', SingboxFieldKind.string),
  ];
}

class SingboxOutboundAnyTlsOptions extends SingboxOutboundBaseOptions {
  @override
  String get typeName => 'anytls';
  @override
  List<SingboxFieldSpec> get fieldSpecs => const [
    SingboxFieldSpec('password', SingboxFieldKind.string, required: true),
    SingboxFieldSpec('idle_session_check_interval', SingboxFieldKind.string),
    SingboxFieldSpec('idle_session_timeout', SingboxFieldKind.string),
    SingboxFieldSpec('min_idle_session', SingboxFieldKind.integer),
    SingboxFieldSpec('tls', SingboxFieldKind.map),
    SingboxFieldSpec('udp_over_tcp', SingboxFieldKind.any),
  ];
}

class SingboxOutboundNaiveOptions extends SingboxOutboundBaseOptions {
  @override
  String get typeName => 'naive';
  @override
  List<SingboxFieldSpec> get fieldSpecs => const [
    SingboxFieldSpec('username', SingboxFieldKind.string),
    SingboxFieldSpec('password', SingboxFieldKind.string),
    SingboxFieldSpec('extra_headers', SingboxFieldKind.map),
    SingboxFieldSpec('udp_over_tcp', SingboxFieldKind.any),
    SingboxFieldSpec('tls', SingboxFieldKind.map),
  ];
}

class SingboxOutboundSnellOptions extends SingboxOutboundBaseOptions {
  @override
  String get typeName => 'snell';
  @override
  List<SingboxFieldSpec> get fieldSpecs => const [
    SingboxFieldSpec('psk', SingboxFieldKind.string, required: true),
    SingboxFieldSpec('version', SingboxFieldKind.integer),
    SingboxFieldSpec('obfs_mode', SingboxFieldKind.string),
    SingboxFieldSpec('obfs_host', SingboxFieldKind.string),
    SingboxFieldSpec('udp', SingboxFieldKind.boolean),
    SingboxFieldSpec('reuse', SingboxFieldKind.boolean),
  ];
}

class SingboxOutboundTailscaleOptions extends SingboxOutboundBaseOptions {
  @override
  String get typeName => 'tailscale';
  @override
  bool get requiresServer => false;
  @override
  List<SingboxFieldSpec> get fieldSpecs => const [
    SingboxFieldSpec('state_directory', SingboxFieldKind.string),
    SingboxFieldSpec('auth_key', SingboxFieldKind.string),
    SingboxFieldSpec('control_url', SingboxFieldKind.string),
    SingboxFieldSpec('ephemeral', SingboxFieldKind.boolean),
    SingboxFieldSpec('hostname', SingboxFieldKind.string),
    SingboxFieldSpec('accept_routes', SingboxFieldKind.boolean),
    SingboxFieldSpec('exit_node', SingboxFieldKind.string),
    SingboxFieldSpec('exit_node_allow_lan_access', SingboxFieldKind.boolean),
    SingboxFieldSpec('advertise_routes', SingboxFieldKind.stringList),
    SingboxFieldSpec('advertise_exit_node', SingboxFieldKind.boolean),
  ];
}

class SingboxOutboundOpenvpnOptions extends SingboxOutboundBaseOptions {
  @override
  String get typeName => 'openvpn-client';
  @override
  bool get requiresServer => false;
  @override
  List<SingboxFieldSpec> get fieldSpecs => const [
    SingboxFieldSpec('config', SingboxFieldKind.string, required: true),
    SingboxFieldSpec('username', SingboxFieldKind.string),
    SingboxFieldSpec('password', SingboxFieldKind.string),
  ];
}

class SingboxOutboundMieruOptions extends SingboxOutboundBaseOptions {
  @override
  String get typeName => 'mieru';
  @override
  List<SingboxFieldSpec> get fieldSpecs => const [
    SingboxFieldSpec('user_name', SingboxFieldKind.string),
    SingboxFieldSpec('password', SingboxFieldKind.string, required: true),
    SingboxFieldSpec('traffic_pattern', SingboxFieldKind.string),
    SingboxFieldSpec('mtu', SingboxFieldKind.integer),
  ];
}

class SingboxOutboundSudokuOptions extends SingboxOutboundBaseOptions {
  @override
  String get typeName => 'sudoku';
  @override
  List<SingboxFieldSpec> get fieldSpecs => const [
    SingboxFieldSpec('key', SingboxFieldKind.string, required: true),
    SingboxFieldSpec('aead_method', SingboxFieldKind.string),
    SingboxFieldSpec('padding_min', SingboxFieldKind.integer),
    SingboxFieldSpec('padding_max', SingboxFieldKind.integer),
    SingboxFieldSpec('enable_pure_downlink', SingboxFieldKind.boolean),
  ];
}

class SingboxOutboundTrustTunnelOptions extends SingboxOutboundBaseOptions {
  @override
  String get typeName => 'trusttunnel';
  @override
  List<SingboxFieldSpec> get fieldSpecs => const [
    SingboxFieldSpec('username', SingboxFieldKind.string),
    SingboxFieldSpec('password', SingboxFieldKind.string, required: true),
    SingboxFieldSpec('congestion_control', SingboxFieldKind.string),
    SingboxFieldSpec('tls', SingboxFieldKind.map),
  ];
}

class SingboxOutboundMasqueOptions extends SingboxOutboundBaseOptions {
  @override
  String get typeName => 'masque';
  @override
  List<SingboxFieldSpec> get fieldSpecs => const [
    SingboxFieldSpec('private_key', SingboxFieldKind.string, required: true),
    SingboxFieldSpec('peer_public_key', SingboxFieldKind.string),
    SingboxFieldSpec('local_address', SingboxFieldKind.stringList),
    SingboxFieldSpec('mtu', SingboxFieldKind.integer),
  ];
}

/// Dialer options shared by all outbounds (the fields live at the top
/// level of the outbound JSON). Only `detour` is touched by surviving
/// code; the rest round-trip.
class SingboxOutboundDialerOptions {
  String? detour;
  String? bindInterface;
  String? inet4BindAddress;
  String? inet6BindAddress;
  int? routingMark;
  bool? reuseAddr;
  String? connectTimeout;
  bool? tcpFastOpen;
  bool? tcpMultiPath;
  bool? udpFragment;

  Map<String, dynamic> toJson() {
    final ret = <String, dynamic>{};
    if (detour != null) ret['detour'] = detour;
    if (bindInterface != null) ret['bind_interface'] = bindInterface;
    if (inet4BindAddress != null) {
      ret['inet4_bind_address'] = inet4BindAddress;
    }
    if (inet6BindAddress != null) {
      ret['inet6_bind_address'] = inet6BindAddress;
    }
    if (routingMark != null) ret['routing_mark'] = routingMark;
    if (reuseAddr != null) ret['reuse_addr'] = reuseAddr;
    if (connectTimeout != null) ret['connect_timeout'] = connectTimeout;
    if (tcpFastOpen != null) ret['tcp_fast_open'] = tcpFastOpen;
    if (tcpMultiPath != null) ret['tcp_multi_path'] = tcpMultiPath;
    if (udpFragment != null) ret['udp_fragment'] = udpFragment;
    return ret;
  }

  void fromJson(Map<String, dynamic>? map) {
    if (map == null) {
      return;
    }
    detour = map['detour'] as String?;
    bindInterface = map['bind_interface'] as String?;
    inet4BindAddress = map['inet4_bind_address'] as String?;
    inet6BindAddress = map['inet6_bind_address'] as String?;
    final mark = map['routing_mark'];
    routingMark = mark is num ? mark.toInt() : null;
    reuseAddr = map['reuse_addr'] as bool?;
    connectTimeout = map['connect_timeout'] as String?;
    tcpFastOpen = map['tcp_fast_open'] as bool?;
    tcpMultiPath = map['tcp_multi_path'] as bool?;
    udpFragment = map['udp_fragment'] as bool?;
  }
}

/// The mux "brutal" options used by SettingConfigItemMux.
class SingboxOutboundMultiplexBrutalOptions {
  bool? enabled;
  int? upMbps;
  int? downMbps;

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'up_mbps': upMbps,
    'down_mbps': downMbps,
  };

  void fromJson(Map<String, dynamic>? map) {
    if (map == null) {
      return;
    }
    enabled = map['enabled'] as bool?;
    final up = map['up_mbps'];
    upMbps = up is num ? up.toInt() : null;
    final down = map['down_mbps'];
    downMbps = down is num ? down.toInt() : null;
  }

  static SingboxOutboundMultiplexBrutalOptions? fromJsonStatic(
    Map<String, dynamic>? map,
  ) {
    if (map == null) {
      return null;
    }
    final options = SingboxOutboundMultiplexBrutalOptions();
    options.fromJson(map);
    return options;
  }
}

/// A urltest outbound as reported by the core (server_select_screen).
class SingboxOutboundUrltest {
  String tag = '';
  List<String> outbounds = [];
  String url = '';
  String interval = '';
  int tolerance = 0;

  Map<String, dynamic> toJson() => {
    'type': 'urltest',
    'tag': tag,
    'outbounds': outbounds,
    if (url.isNotEmpty) 'url': url,
    if (interval.isNotEmpty) 'interval': interval,
    if (tolerance != 0) 'tolerance': tolerance,
  };

  void fromJson(Map<String, dynamic>? map) {
    if (map == null) {
      return;
    }
    tag = map['tag'] ?? '';
    final list = map['outbounds'];
    outbounds = list is List
        ? list.map((e) => e.toString()).toList()
        : <String>[];
    url = map['url'] ?? '';
    interval = map['interval']?.toString() ?? '';
    final tol = map['tolerance'];
    tolerance = tol is num ? tol.toInt() : 0;
  }

  static SingboxOutboundUrltest fromJsonStatic(Map<String, dynamic>? map) {
    final urltest = SingboxOutboundUrltest();
    urltest.fromJson(map);
    return urltest;
  }
}

/// Holder for one outbound being added/edited: the active protocol
/// options object plus the shared tag/type/server mirror fields.
class SingboxOutboundOptions {
  String type = '';
  String tag = '';
  String server = '';
  int serverPort = 0;

  int get server_port => serverPort;
  set server_port(int value) => serverPort = value;

  SingboxOutboundDialerOptions? dialer;

  SingboxOutboundShadowsocksOptions? shadowsocks;
  SingboxOutboundShadowsocksROptions? shadowsocksr;
  SingboxOutboundShadowTLSOptions? shadowtls;
  SingboxOutboundVMessOptions? vmess;
  SingboxOutboundVLESSOptions? vless;
  SingboxOutboundTrojanOptions? trojan;
  SingboxOutboundSocksOptions? socks;
  SingboxOutboundHTTPOptions? http;
  SingboxOutboundHysteriaOptions? hysteria;
  SingboxOutboundHysteria2Options? hysteria2;
  SingboxOutboundWireGuardOptions? wg;
  SingboxOutboundTUICOptions? tuic;
  SingboxOutboundTorOptions? tor;
  SingboxOutboundSSHOptions? ssh;
  SingboxOutboundAnyTlsOptions? anytls;
  SingboxOutboundNaiveOptions? naive;
  SingboxOutboundSnellOptions? snell;
  SingboxOutboundTailscaleOptions? tailscale;
  SingboxOutboundOpenvpnOptions? openvpn;
  SingboxOutboundMieruOptions? mieru;
  SingboxOutboundSudokuOptions? sudoku;
  SingboxOutboundTrustTunnelOptions? trusttunnel;
  SingboxOutboundMasqueOptions? masque;

  SingboxOutboundBaseOptions? get active {
    switch (type) {
      case 'shadowsocks':
        return shadowsocks;
      case 'shadowsocksr':
        return shadowsocksr;
      case 'shadowtls':
        return shadowtls;
      case 'vmess':
        return vmess;
      case 'vless':
        return vless;
      case 'trojan':
        return trojan;
      case 'socks':
        return socks;
      case 'http':
        return http;
      case 'hysteria':
        return hysteria;
      case 'hysteria2':
        return hysteria2;
      case 'wireguard':
        return wg;
      case 'tuic':
        return tuic;
      case 'tor':
        return tor;
      case 'ssh':
        return ssh;
      case 'anytls':
        return anytls;
      case 'naive':
        return naive;
      case 'snell':
        return snell;
      case 'tailscale':
        return tailscale;
      case 'openvpn-client':
        return openvpn;
      case 'mieru':
        return mieru;
      case 'sudoku':
        return sudoku;
      case 'trusttunnel':
        return trusttunnel;
      case 'masque':
        return masque;
    }
    return null;
  }

  SingboxOutboundBaseOptions _createForType(String type) {
    switch (type) {
      case 'shadowsocks':
        return shadowsocks = SingboxOutboundShadowsocksOptions();
      case 'shadowsocksr':
        return shadowsocksr = SingboxOutboundShadowsocksROptions();
      case 'shadowtls':
        return shadowtls = SingboxOutboundShadowTLSOptions();
      case 'vmess':
        return vmess = SingboxOutboundVMessOptions();
      case 'vless':
        return vless = SingboxOutboundVLESSOptions();
      case 'trojan':
        return trojan = SingboxOutboundTrojanOptions();
      case 'socks':
        return socks = SingboxOutboundSocksOptions();
      case 'http':
        return http = SingboxOutboundHTTPOptions();
      case 'hysteria':
        return hysteria = SingboxOutboundHysteriaOptions();
      case 'hysteria2':
        return hysteria2 = SingboxOutboundHysteria2Options();
      case 'wireguard':
        return wg = SingboxOutboundWireGuardOptions();
      case 'tuic':
        return tuic = SingboxOutboundTUICOptions();
      case 'tor':
        return tor = SingboxOutboundTorOptions();
      case 'ssh':
        return ssh = SingboxOutboundSSHOptions();
      case 'anytls':
        return anytls = SingboxOutboundAnyTlsOptions();
      case 'naive':
        return naive = SingboxOutboundNaiveOptions();
      case 'snell':
        return snell = SingboxOutboundSnellOptions();
      case 'tailscale':
        return tailscale = SingboxOutboundTailscaleOptions();
      case 'openvpn-client':
        return openvpn = SingboxOutboundOpenvpnOptions();
      case 'mieru':
        return mieru = SingboxOutboundMieruOptions();
      case 'sudoku':
        return sudoku = SingboxOutboundSudokuOptions();
      case 'trusttunnel':
        return trusttunnel = SingboxOutboundTrustTunnelOptions();
      case 'masque':
        return masque = SingboxOutboundMasqueOptions();
    }
    return SingboxOutboundSocksOptions();
  }

  bool isValid() {
    return type.isNotEmpty && active != null;
  }

  void fromJson(Map<String, dynamic>? map) {
    if (map == null) {
      return;
    }
    type = map['type'] ?? '';
    tag = map['tag'] ?? '';
    final options = _createForType(type);
    options.fromJson(map);
    server = options.server ?? '';
    serverPort = options.serverPort ?? 0;
    dialer = SingboxOutboundDialerOptions()..fromJson(map);
  }

  Map<String, dynamic> toJson() {
    final options = active;
    final ret = options != null ? options.toJson() : <String, dynamic>{};
    ret['type'] = type;
    ret['tag'] = tag;
    if (dialer != null) {
      ret.addAll(dialer!.toJson());
    }
    return ret;
  }

  /// Editor rows for the active protocol: server/port plus every
  /// string/integer spec field as a text field.
  Future<List<GroupItem>> getWidgetOptions(
    BuildContext context,
    SetStateCallback? setstate,
  ) async {
    final options = active;
    if (options == null) {
      return [];
    }
    final items = <GroupItemOptions>[];
    if (options.requiresServer) {
      items.add(
        GroupItemOptions(
          textFormFieldOptions: GroupItemTextFieldOptions(
            name: 'server',
            text: options.server ?? '',
            textWidthPercent: 0.6,
            onChanged: (String value) {
              options.server = value;
            },
          ),
        ),
      );
      items.add(
        GroupItemOptions(
          textFormFieldOptions: GroupItemTextFieldOptions(
            name: 'server_port',
            text: options.serverPort?.toString() ?? '',
            textWidthPercent: 0.6,
            onChanged: (String value) {
              options.serverPort = int.tryParse(value.trim());
            },
          ),
        ),
      );
    }
    for (final spec in options.fieldSpecs) {
      if (spec.kind != SingboxFieldKind.string &&
          spec.kind != SingboxFieldKind.integer) {
        continue;
      }
      final current = options[spec.key];
      items.add(
        GroupItemOptions(
          textFormFieldOptions: GroupItemTextFieldOptions(
            name: spec.key,
            text: current?.toString() ?? '',
            textWidthPercent: 0.6,
            onChanged: (String value) {
              if (spec.kind == SingboxFieldKind.integer) {
                options[spec.key] = int.tryParse(value.trim());
              } else {
                options[spec.key] = value;
              }
            },
          ),
        ),
      );
    }
    return [GroupItem(options: items)];
  }
}
