// singbox_config_builder.dart — RECONSTRUCTED by the yousj-plus fork.
//
// The upstream Karing release does not ship this file (partial source
// release). This reconstruction is written from scratch against the call
// sites that survive in the repo (chiefly lib/screens/my_profiles_screen.dart
// and the settings models in lib/app/modules/) plus sing-box 1.12 config
// semantics. It is a mainline skeleton: the generation path used at runtime
// (inbounds / outbounds / endpoints / route / dns / ntp for one selected
// profile) is implemented; export flavours other than the runtime one and
// several upstream parameters whose meaning no surviving call site pins down
// are marked TODO. See goals/karing-fork/hidden_files/reconstruction-spec.md
// for the full interface inventory this file is built against.
//
// yousj-plus feature: SettingConfig.wireguardInboundDirect — when on,
// route() prepends {"inbound":[<endpoint tag>],"action":"route",
// "outbound":<direct>} for every emitted WireGuard endpoint, so
// server-initiated connections arriving through a WireGuard tunnel are
// delivered to local listeners instead of looping back into the tunnel.
// (Semantics verified live against sing-box 1.12.12: the rule must NOT
// carry ip_cidr and does NOT need override_address.)

import 'package:karing/app/modules/server_manager.dart';
import 'package:karing/app/modules/setting_manager.dart';
import 'package:karing/app/runtime/return_result.dart';
import 'package:tuple/tuple.dart';
import 'package:vpn_service/state.dart';

/// Which flavour of config to generate. Only [karing] (the runtime config)
/// is exercised by the reconstruction's mainline path.
enum SingboxExportType { karing, tvos, clash, singbox }

/// Log level values, shaped as the settings code expects: value objects with
/// a [name], plus a static [names] list (setting_manager.dart, about_screen).
class SingboxLogLevel {
  final String name;
  const SingboxLogLevel._(this.name);

  static const SingboxLogLevel trace = SingboxLogLevel._('trace');
  static const SingboxLogLevel debug = SingboxLogLevel._('debug');
  static const SingboxLogLevel info = SingboxLogLevel._('info');
  static const SingboxLogLevel warn = SingboxLogLevel._('warn');
  static const SingboxLogLevel error = SingboxLogLevel._('error');
  static const SingboxLogLevel fatal = SingboxLogLevel._('fatal');
  static const SingboxLogLevel panic = SingboxLogLevel._('panic');
  static const SingboxLogLevel disable = SingboxLogLevel._('disable');

  static List<String> names() => const [
    'trace',
    'debug',
    'info',
    'warn',
    'error',
    'fatal',
    'panic',
    'disable',
  ];
}

/// Options object for the sing-box `tun` inbound. Callers mutate fields
/// directly (my_profiles_screen.dart sets [address], [include_package],
/// [exclude_package] on instances returned by
/// [SingboxConfigBuilder.inbounds]).
class SingboxInboundTunOptions {
  // Mutable statics, not consts: SettingConfigItemTUN.getAddress()
  // (setting_manager.dart:667-685) rewrites these from user settings.
  static String ipv4Address = '172.19.0.1/30';
  static String ipv6Address = 'fdfe:dcba:9876::1/126';

  String tag = 'tun-in';
  List<String> address = [ipv4Address, ipv6Address];
  int mtu = 4064;
  bool auto_route = true;
  bool strict_route = false;
  // TODO(reconstruction): upstream default stack is not pinned by any call
  // site; 'mixed' is sing-box's own default. SettingConfigItemTUN.stack is
  // copied over this in inbounds().
  String stack = 'mixed';
  List<String> include_package = [];
  List<String> exclude_package = [];

  Map<String, dynamic> toJson() => {
    'type': 'tun',
    'tag': tag,
    'address': address,
    'mtu': mtu,
    'auto_route': auto_route,
    'strict_route': strict_route,
    'stack': stack,
    if (include_package.isNotEmpty) 'include_package': include_package,
    if (exclude_package.isNotEmpty) 'exclude_package': exclude_package,
  };
}

/// Options object for the sing-box `mixed` (http+socks) inbound
/// (proxy_cluster.dart sets [listen], [listen_port], [tag] via cascade).
class SingboxInboundMixedOptions {
  String tag = 'mixed-in';
  String listen = '127.0.0.1';
  int listen_port = 0;

  Map<String, dynamic> toJson() => {
    'type': 'mixed',
    'tag': tag,
    'listen': listen,
    'listen_port': listen_port,
  };
}

/// The assembled sing-box configuration. Sections are held as the builder
/// produces them (option objects for inbounds, plain JSON values elsewhere)
/// and serialised through [toJson].
class SingboxConfig {
  dynamic log;
  dynamic ntp;
  dynamic dns;
  List<dynamic> inbounds = [];
  List<dynamic> outbounds = [];
  List<dynamic> endpoints = [];
  dynamic route;

  Map<String, dynamic> toJson() {
    final ret = <String, dynamic>{};
    if (log != null) ret['log'] = _encode(log);
    if (dns != null) ret['dns'] = _encode(dns);
    if (ntp != null) ret['ntp'] = _encode(ntp);
    if (inbounds.isNotEmpty) {
      ret['inbounds'] = inbounds.map(_encode).toList();
    }
    if (outbounds.isNotEmpty) {
      ret['outbounds'] = outbounds.map(_encode).toList();
    }
    if (endpoints.isNotEmpty) {
      ret['endpoints'] = endpoints.map(_encode).toList();
    }
    if (route != null) ret['route'] = _encode(route);
    return ret;
  }

  static dynamic _encode(dynamic value) {
    if (value is Map) {
      return value.map((k, v) => MapEntry(k.toString(), _encode(v)));
    }
    if (value is List) {
      return value.map(_encode).toList();
    }
    if (value is SingboxInboundTunOptions) return value.toJson();
    if (value is SingboxInboundMixedOptions) return value.toJson();
    return value;
  }
}

class SingboxConfigBuilder {
  /// Endpoint types in sing-box (>=1.11): these live under `endpoints`, not
  /// `outbounds`, in the final config.
  static const Set<String> _endpointTypes = {'wireguard', 'tailscale'};

  /// Build the sing-box outbound/endpoint JSON for one node.
  ///
  /// A node that carries its full JSON in [ProxyConfig.raw] (the normal case
  /// after parsing or manual editing) is emitted from the raw map with its
  /// tag/type reconciled; otherwise a minimal map is synthesised from the
  /// node's scalar fields. Returns null when the node has no usable type.
  static dynamic buildOutbound(ProxyConfig server) {
    if (server.raw is Map) {
      final map = Map<String, dynamic>.from(server.raw as Map);
      map['tag'] = server.tag;
      map['type'] ??= server.type;
      return map;
    }
    if (server.type.isEmpty) {
      return null;
    }
    final map = <String, dynamic>{'type': server.type, 'tag': server.tag};
    if (server.server.isNotEmpty) {
      map['server'] = server.server;
    }
    if (server.serverport != 0) {
      map['server_port'] = server.serverport;
    }
    // TODO(reconstruction): protocol-specific fields for raw-less nodes
    // (transport, tls, uuid/password, wireguard keys, ...) belong to the
    // per-protocol option classes in singbox_outbound.dart; nodes created by
    // the parsers always carry raw JSON, so this path is a fallback only.
    return map;
  }

  /// The `ntp` section, or null when NTP is disabled in settings.
  static dynamic ntp() {
    final ntp = SettingManager.getConfig().ntp;
    if (!ntp.enable) {
      return null;
    }
    return {
      'enabled': true,
      'server': ntp.server,
      'server_port': ntp.port,
    };
  }

  /// The `dns` section.
  ///
  /// TODO(reconstruction): upstream builds this from the full
  /// SettingConfigItemDNS model (per-ISP server lists, detours, domain
  /// rules) via the SingboxDNS* option classes that live in the missing
  /// singbox_dns.dart. This skeleton emits the resolver set the settings
  /// model itself nominates (SettingConfigItemDNS.getResolverDns) as udp
  /// servers plus the configured ip strategy — valid sing-box, but not yet
  /// upstream-faithful. Params 3–4 are unpinned by call sites (always null).
  static ReturnResult<Map<String, dynamic>> dns(
    bool tunMode,
    SingboxExportType type,
    dynamic extra1,
    dynamic extra2,
  ) {
    final setting = SettingManager.getConfig();
    final resolverUrls = setting.dns.getResolverDns(
      setting.regionCode.toLowerCase(),
      tunMode,
    );
    final servers = <Map<String, dynamic>>[];
    var i = 0;
    for (final url in resolverUrls) {
      final server = _dnsServerFromUrl(url, 'dns-${i++}');
      if (server != null) {
        servers.add(server);
      }
    }
    if (servers.isEmpty) {
      servers.add({'type': 'udp', 'tag': 'dns-0', 'server': '223.5.5.5'});
    }
    return ReturnResult(
      data: {
        'servers': servers,
        'final': servers.first['tag'],
        'strategy': setting.ipStrategy.name,
      },
    );
  }

  static Map<String, dynamic>? _dnsServerFromUrl(String url, String tag) {
    if (url == 'local') {
      return {'type': 'local', 'tag': tag};
    }
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) {
      return null;
    }
    switch (uri.scheme) {
      case 'udp':
        return {
          'type': 'udp',
          'tag': tag,
          'server': uri.host,
          if (uri.hasPort) 'server_port': uri.port,
        };
      case 'tcp':
        return {
          'type': 'tcp',
          'tag': tag,
          'server': uri.host,
          if (uri.hasPort) 'server_port': uri.port,
        };
      case 'tls':
        return {
          'type': 'tls',
          'tag': tag,
          'server': uri.host,
          if (uri.hasPort) 'server_port': uri.port,
        };
      case 'https':
        return {
          'type': 'https',
          'tag': tag,
          'server': uri.host,
          if (uri.hasPort) 'server_port': uri.port,
          if (uri.path.isNotEmpty && uri.path != '/') 'path': uri.path,
        };
      default:
        // dhcp://, h3://, quic:// etc. need the full sing-box DNS option
        // classes (singbox_dns.dart) — TODO(reconstruction).
        return null;
    }
  }

  /// The `inbounds` list: TUN (when [tunMode] and TUN is enabled in
  /// settings) plus the mixed http/socks inbound on the rule port.
  ///
  /// Elements are option objects (see [SingboxInboundTunOptions],
  /// [SingboxInboundMixedOptions]); [SingboxConfig.toJson] serialises them.
  static List<dynamic> inbounds(bool tunMode, SingboxExportType type) {
    final setting = SettingManager.getConfig();
    final ret = <dynamic>[];
    if (tunMode && setting.tun.enable) {
      final tun = SingboxInboundTunOptions()
        ..address = [
          setting.tun.ipv4Address,
          if (setting.tun.ipv6Address.isNotEmpty) setting.tun.ipv6Address,
        ]
        ..mtu = setting.tun.mtu
        ..auto_route = setting.tun.autoRoute
        ..strict_route = setting.tun.strictRoute
        ..stack = setting.tun.stack;
      // TODO(reconstruction): per-app include/exclude packages come from
      // SettingConfigItemPerapp; upstream population rules are not pinned
      // by call sites (the export path zeroes both lists for sharing).
      ret.add(tun);
    }
    if (setting.proxy.mixedRulePort > 0) {
      ret.add(
        SingboxInboundMixedOptions()
          ..tag = 'mixed-in'
          ..listen = '127.0.0.1'
          ..listen_port = setting.proxy.mixedRulePort,
      );
    }
    return ret;
  }

  /// Assemble the final `outbounds` list.
  ///
  /// Positional params follow the surviving call site
  /// (my_profiles_screen.dart:1795–1806). Only [selectOutbound] (the built
  /// outbound for the current selection / urltest group), [allOutBounds]
  /// (every node's built outbound) and [type] are pinned by that site; the
  /// remaining parameters are accepted for signature compatibility and are
  /// currently unused — TODO(reconstruction): recover their upstream
  /// semantics (chain-proxy map, disabled-tag set, warp/tailscale extras
  /// are the likely candidates).
  static ReturnResult<List<dynamic>> outbounds(
    String groupidUnused,
    Set<String> selectedTags,
    Map chainProxyUnused,
    dynamic selectOutbound,
    List<dynamic> allOutBounds,
    dynamic extra1,
    Map extra2,
    List extra3,
    dynamic extra4,
    SingboxExportType type,
  ) {
    final ret = <dynamic>[];
    final seenTags = <String>{};
    void addOne(dynamic bound) {
      if (bound is Map) {
        final tag = bound['tag'];
        if (tag is String && tag.isNotEmpty) {
          if (!seenTags.add(tag)) {
            return;
          }
        }
      }
      ret.add(bound);
    }

    if (selectOutbound != null) {
      addOne(selectOutbound);
    }
    for (final bound in allOutBounds) {
      addOne(bound);
    }
    // The pseudo outbounds every generated config needs. Their tags are the
    // shared constants from the plugin's state.dart.
    if (!seenTags.contains(kOutboundTagDirect)) {
      ret.add({'type': 'direct', 'tag': kOutboundTagDirect});
    }
    if (!seenTags.contains(kOutboundTagBlock)) {
      ret.add({'type': 'block', 'tag': kOutboundTagBlock});
    }
    return ReturnResult(data: ret);
  }

  /// Move endpoint-type entries (wireguard, tailscale) out of an assembled
  /// outbound list and return them as the config's `endpoints` section.
  /// The input list is mutated: extracted entries are removed from it, so
  /// no tag ever appears in both sections of the final config.
  static List<dynamic> endpoints(List<dynamic> outbounds) {
    final ret = <dynamic>[];
    outbounds.removeWhere((bound) {
      if (bound is Map && _endpointTypes.contains(bound['type'])) {
        ret.add(bound);
        return true;
      }
      return false;
    });
    return ret;
  }

  /// Tags of the WireGuard endpoints present in an assembled bound list.
  static List<String> _wireguardEndpointTags(List<dynamic> bounds) {
    final tags = <String>[];
    for (final bound in bounds) {
      if (bound is Map && bound['type'] == 'wireguard') {
        final tag = bound['tag'];
        if (tag is String && tag.isNotEmpty) {
          tags.add(tag);
        }
      }
    }
    return tags;
  }

  /// Build the `route` section.
  ///
  /// Positional params follow the surviving call site
  /// (my_profiles_screen.dart:1824–1845); params whose meaning no call site
  /// pins down are accepted and currently unused (TODO(reconstruction)).
  /// [diversionGroups] is the resolved list from
  /// ServerManager.getDiversionGroups(): (rules group, target node,
  /// per-group DNS servers). The tuple whose group id is the final group
  /// supplies `route.final` instead of a rule.
  static dynamic route(
    String unused1,
    String unused2,
    String unused3,
    String unused4,
    int siteCodesHashCode,
    int ipCodesHashCode,
    int aclCodesHashCode,
    bool tunMode,
    List<dynamic> allOutBounds,
    Map unused10,
    dynamic unused11,
    List<Tuple3<DiversionRulesGroup, ProxyConfig, List<String>>>
    diversionGroups,
    List<dynamic> inbounds,
    dynamic dns,
    dynamic unused15,
    dynamic unused16,
    dynamic unused17,
    String groupid,
    SingboxExportType type,
  ) {
    final setting = SettingManager.getConfig();
    final rules = <Map<String, dynamic>>[];

    // yousj-plus Feature 1: WireGuard endpoint inbound -> direct.
    // These rules MUST precede every diversion rule: a diversion rule that
    // routes the tunnel subnet to the endpoint outbound would otherwise
    // capture the inbound connection first and loop it back into the
    // tunnel (the failure mode this feature exists to fix). No ip_cidr
    // (breaks the match), no override_address (not needed — a direct dial
    // to the endpoint's own address lands on local listeners).
    if (setting.wireguardInboundDirect) {
      for (final tag in _wireguardEndpointTags(allOutBounds)) {
        rules.add({
          'inbound': [tag],
          'action': 'route',
          'outbound': kOutboundTagDirect,
        });
      }
    }

    // Private (LAN) destinations bypass the proxy. Inferred from
    // SettingConfig.privateDirect; upstream placement is unpinned.
    if (setting.privateDirect) {
      rules.add({
        'ip_is_private': true,
        'action': 'route',
        'outbound': kOutboundTagDirect,
      });
    }

    String? finalTag;
    for (final tuple in diversionGroups) {
      final rg = tuple.item1;
      final target = tuple.item2;
      if (rg.groupid == ServerManager.getFinalGroupId()) {
        finalTag = target.tag;
        continue;
      }
      final rule = _diversionRule(rg, target.tag);
      if (rule != null) {
        rules.add(rule);
      }
    }

    final ret = <String, dynamic>{
      'auto_detect_interface': true,
      // TODO(reconstruction): rule_set entries are keyed by the three
      // ruleset content hashes (siteCodesHashCode / ipCodesHashCode /
      // aclCodesHashCode) against the ruleset items the profile import
      // collected; emission lands with the ruleset reconstruction.
      'rules': rules,
    };
    if (finalTag != null && finalTag.isNotEmpty) {
      ret['final'] = finalTag;
    }
    return ret;
  }

  /// Convert one diversion group into a sing-box route rule, or null when
  /// the group carries no matchers at all.
  static Map<String, dynamic>? _diversionRule(
    DiversionRulesGroup rg,
    String outboundTag,
  ) {
    final matchers = _diversionMatchers(rg);
    if (matchers.isEmpty && rg.groups.isEmpty) {
      return null;
    }
    if (rg.groups.isNotEmpty) {
      // Logical (OR/AND) group: sub-groups become nested matcher-only rules.
      final subRules = <Map<String, dynamic>>[];
      for (final sub in rg.groups) {
        final m = _diversionMatchers(sub);
        if (m.isNotEmpty) {
          subRules.add(m);
        }
      }
      if (subRules.isEmpty) {
        return null;
      }
      return {
        'type': 'logical',
        'mode': rg.or ? 'or' : 'and',
        'rules': subRules,
        ...matchers,
        'action': 'route',
        'outbound': outboundTag,
      };
    }
    return {...matchers, 'action': 'route', 'outbound': outboundTag};
  }

  /// The matcher half of a diversion group, keyed by sing-box route-rule
  /// field names. Empty matcher sets are omitted entirely.
  static Map<String, dynamic> _diversionMatchers(DiversionRulesGroup rg) {
    final ret = <String, dynamic>{};
    if (rg.ruleSetBuildIn.isNotEmpty || rg.ruleSet.isNotEmpty) {
      ret['rule_set'] = [...rg.ruleSetBuildIn, ...rg.ruleSet];
    }
    if (rg.domain.isNotEmpty) ret['domain'] = rg.domain;
    if (rg.domainSuffix.isNotEmpty) ret['domain_suffix'] = rg.domainSuffix;
    if (rg.domainKeyword.isNotEmpty) {
      ret['domain_keyword'] = rg.domainKeyword;
    }
    if (rg.domainRegex.isNotEmpty) ret['domain_regex'] = rg.domainRegex;
    if (rg.ipCidr.isNotEmpty) ret['ip_cidr'] = rg.ipCidr;
    if (rg.port.isNotEmpty) ret['port'] = rg.port;
    if (rg.portRange.isNotEmpty) ret['port_range'] = rg.portRange;
    if (rg.package.isNotEmpty) ret['package_name'] = rg.package;
    if (rg.processName.isNotEmpty) ret['process_name'] = rg.processName;
    if (rg.processPath.isNotEmpty) ret['process_path'] = rg.processPath;
    // TODO(reconstruction): network / networkType / protocol / ipVersion /
    // wifiSsid / wifiBssid / processDir — their model types are not pinned
    // by surviving call sites, so they are not emitted yet. The per-group
    // DNS server list (Tuple3.item3) likewise has no sing-box route-rule
    // home; upstream presumably folds it into the dns section's rules.
    return ret;
  }
}
