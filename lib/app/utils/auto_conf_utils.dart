// auto_conf_utils.dart — RECONSTRUCTED by the yousj-plus fork.
//
// The upstream Karing release does not ship this file (partial source
// release). It implements the single entry point the surviving code calls,
// AutoConfUtils.tryConvert (server_manager.dart:1638), which turns a
// profile source (local file, remote URL, or pre-fetched content) into
// the nodes of a ServerConfigGroupItem.
//
// Contract (from ServerManager.loadFrom): mutates [item] in place —
// fills item.servers / item.traffic / item.urlOrPath; when
// [diversionGroupItem] is non-null (the profile kept its diversion
// rules), fills its groups; appends collected rule-sets to
// [ruleSetItems]. Returns null on success, ReturnResultError on failure.
// loadFrom rejects the profile when item.servers ends up empty.
//
// Formats covered by this reconstruction:
//   - sing-box JSON (outbounds + endpoints + route rules / rule-sets)
//   - WireGuard .conf
//   - share-link lists (vmess/vless/trojan/ss/hysteria2/tuic), plain or
//     base64-wrapped
//   - Clash / mihomo YAML (proxies + proxy-groups + rules), plain or
//     base64-wrapped
// Unconvertible entries inside a supported format are skipped and
// counted in [AutoConfUtils.skippedUnconvertible], never fatal.
//
// yousj-plus Feature 2: the sing-box JSON branch converts `endpoints[]`
// entries — a WireGuard endpoint becomes a first-class wireguard
// ProxyConfig, exactly like a .conf-imported peer — instead of reading
// only `outbounds` and dropping endpoints on the floor (the upstream
// behaviour that produced "no server available" for endpoint-only
// profiles). Endpoint tags missing from the source are synthesised as
// `wireguard:<fnv1a>` over the endpoint JSON (stable across re-imports;
// the upstream .conf tag derivation is not observable in-repo, see the
// reconstruction spec §7).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:karing/app/runtime/return_result.dart';
import 'package:vpn_service/state.dart';
import 'package:yaml/yaml.dart';

/// Outbound types that are structural, not user nodes.
const Set<String> _pseudoTypes = {'direct', 'block', 'dns'};

/// Outbound/endpoint types converted into ProxyConfigs.
const Set<String> _proxyTypes = {
  'socks',
  'http',
  'shadowsocks',
  'vmess',
  'vless',
  'trojan',
  'hysteria',
  'hysteria2',
  'tuic',
  'ssh',
  'anytls',
  'wireguard',
  'tailscale',
  'shadowtls',
};

class AutoConfUtils {
  /// Entries skipped by the last tryConvert call because their type or
  /// shape could not be converted.
  static int skippedUnconvertible = 0;

  static Future<ReturnResultError?> tryConvert(
    String urlOrPath,
    bool local,
    bool isUpdate,
    ServerConfigGroupItem item,
    List<ServerDiversionGroupRuleSetItem> ruleSetItems,
    ServerDiversionGroupItem? diversionGroupItem,
    RemoteContent? remoteContent,
  ) async {
    skippedUnconvertible = 0;
    item.urlOrPath = urlOrPath;
    try {
      String content;
      if (remoteContent != null && remoteContent.text.isNotEmpty) {
        content = remoteContent.text;
      } else if (local) {
        final file = File(urlOrPath);
        if (!await file.exists()) {
          return ReturnResultError('file not found: $urlOrPath');
        }
        content = await file.readAsString();
      } else {
        final fetched = await _fetch(urlOrPath, item);
        if (fetched.error != null) {
          return fetched.error;
        }
        content = fetched.data!;
      }

      content = content.trim();
      if (content.isEmpty) {
        return ReturnResultError('empty content');
      }

      final error = _convertContent(
        content,
        item,
        ruleSetItems,
        diversionGroupItem,
        allowBase64: true,
      );
      if (error != null) {
        return error;
      }

      _applyFilters(item);
      for (var i = 0; i < item.servers.length; i++) {
        item.servers[i].groupid = item.groupid;
        item.servers[i].index = i;
      }
      return null;
    } catch (err) {
      return ReturnResultError(err.toString());
    }
  }

  // --- content acquisition -------------------------------------------------

  static Future<ReturnResult<String>> _fetch(
    String url,
    ServerConfigGroupItem item,
  ) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
      return ReturnResult(error: ReturnResultError('invalid url: $url'));
    }
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client.getUrl(uri);
      final uas = item.userAgentCompatibles;
      request.headers.set(
        HttpHeaders.userAgentHeader,
        uas.isNotEmpty ? uas.join(';') : 'YousjEnhanced',
      );
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      if (response.statusCode != 200) {
        return ReturnResult(
          error: ReturnResultError('http statusCode:${response.statusCode}'),
        );
      }
      final userinfo = response.headers.value('subscription-userinfo');
      if (userinfo != null) {
        item.traffic = _parseTraffic(userinfo);
      }
      final body = await response.transform(utf8.decoder).join();
      return ReturnResult(data: body);
    } catch (err) {
      return ReturnResult(error: ReturnResultError(err.toString()));
    } finally {
      client.close();
    }
  }

  static SubscriptionTraffic _parseTraffic(String header) {
    final traffic = SubscriptionTraffic();
    int up = 0, down = 0, total = 0;
    for (final part in header.split(';')) {
      final kv = part.split('=');
      if (kv.length != 2) continue;
      final value = int.tryParse(kv[1].trim()) ?? 0;
      switch (kv[0].trim()) {
        case 'upload':
          up = value;
        case 'download':
          down = value;
        case 'total':
          total = value;
        case 'expire':
          traffic.expire = value;
      }
    }
    traffic.upload = _formatBytes(up);
    traffic.download = _formatBytes(down);
    traffic.total = _formatBytes(total);
    traffic.overQuota = total > 0 && (up + down) >= total;
    return traffic;
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    const units = ['KB', 'MB', 'GB', 'TB', 'PB'];
    var value = bytes.toDouble();
    var unit = -1;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return '${value.toStringAsFixed(2)} ${units[unit]}';
  }

  // --- format dispatch -----------------------------------------------------

  static ReturnResultError? _convertContent(
    String content,
    ServerConfigGroupItem item,
    List<ServerDiversionGroupRuleSetItem> ruleSetItems,
    ServerDiversionGroupItem? diversionGroupItem, {
    required bool allowBase64,
  }) {
    if (content.startsWith('{')) {
      dynamic decoded;
      try {
        decoded = jsonDecode(content);
      } catch (err) {
        return ReturnResultError('invalid json: $err');
      }
      if (decoded is Map<String, dynamic>) {
        return _convertSingboxJson(
          decoded,
          item,
          ruleSetItems,
          diversionGroupItem,
        );
      }
      return ReturnResultError('invalid sing-box json');
    }
    if (content.contains('[Interface]') && content.contains('[Peer]')) {
      return _convertWireguardConf(content, item);
    }
    if (content.contains('proxies:')) {
      return _convertClashYaml(
        content,
        item,
        ruleSetItems,
        diversionGroupItem,
      );
    }
    if (content.contains('://')) {
      return _convertUriList(content, item);
    }
    if (allowBase64) {
      final decoded = _tryDecodeBase64(content);
      if (decoded != null && decoded.trim().isNotEmpty) {
        return _convertContent(
          decoded.trim(),
          item,
          ruleSetItems,
          diversionGroupItem,
          allowBase64: false,
        );
      }
    }
    return ReturnResultError('unsupported profile format');
  }

  static String? _tryDecodeBase64(String content) {
    try {
      var normalized = content.replaceAll(RegExp(r'\s+'), '');
      normalized = normalized.replaceAll('-', '+').replaceAll('_', '/');
      while (normalized.length % 4 != 0) {
        normalized += '=';
      }
      final text = utf8.decode(base64Decode(normalized));
      // Reject binary garbage: subscriptions decode to printable text.
      if (text.contains('�')) {
        return null;
      }
      return text;
    } catch (_) {
      return null;
    }
  }

  static void _applyFilters(ServerConfigGroupItem item) {
    if (item.proxyFilterRemove.isNotEmpty) {
      final remove = item.proxyFilterRemove.toSet();
      item.servers.removeWhere((s) => remove.contains(s.tag));
    }
    final filter = item.proxyFilter;
    if (filter.method != ProxyFilterMethod.all &&
        filter.keywordOrRegx.isNotEmpty) {
      RegExp? regex;
      try {
        regex = RegExp(filter.keywordOrRegx);
      } catch (_) {
        regex = null;
      }
      bool matches(ProxyConfig s) {
        final keyword = filter.keywordOrRegx;
        if (filter.matchAttribute) {
          return s.tag.contains(keyword) || s.type.contains(keyword);
        }
        if (regex != null) {
          return regex.hasMatch(s.tag) || regex.hasMatch(s.type);
        }
        return s.tag.contains(keyword);
      }

      if (filter.method == ProxyFilterMethod.include) {
        item.servers.removeWhere((s) => !matches(s));
      } else if (filter.method == ProxyFilterMethod.exclude) {
        item.servers.removeWhere(matches);
      }
    }
  }

  static int _fnv1a(String s) {
    var hash = 0x811c9dc5;
    for (final unit in s.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash;
  }

  static String _uniqueTag(String tag, Set<String> used) {
    var candidate = tag;
    var n = 2;
    while (used.contains(candidate)) {
      candidate = '$tag-${n++}';
    }
    used.add(candidate);
    return candidate;
  }
}

// ---------------------------------------------------------------------------
// sing-box JSON
// ---------------------------------------------------------------------------

ReturnResultError? _convertSingboxJson(
  Map<String, dynamic> root,
  ServerConfigGroupItem item,
  List<ServerDiversionGroupRuleSetItem> ruleSetItems,
  ServerDiversionGroupItem? diversionGroupItem,
) {
  final usedTags = <String>{};

  final outbounds = root['outbounds'];
  if (outbounds is List) {
    for (final entry in outbounds) {
      if (entry is! Map) {
        AutoConfUtils.skippedUnconvertible++;
        continue;
      }
      final bound = Map<String, dynamic>.from(entry);
      final type = (bound['type'] ?? '').toString();
      if (_pseudoTypes.contains(type)) {
        continue;
      }
      if (type == 'selector' || type == 'urltest') {
        // Group pseudo-nodes stay selectable: keep them as ProxyConfigs
        // whose membership lives in raw.
        final pc = ProxyConfig()
          ..type = type
          ..tag = AutoConfUtils._uniqueTag(
            (bound['tag'] ?? type).toString(),
            usedTags,
          )
          ..raw = bound;
        bound['tag'] = pc.tag;
        item.servers.add(pc);
        continue;
      }
      if (type == 'wireguard') {
        // Legacy placement (pre-1.11 configs): an endpoint in outbounds.
        final pc = _wireguardEndpointToProxy(bound, usedTags);
        if (pc == null) {
          AutoConfUtils.skippedUnconvertible++;
        } else {
          item.servers.add(pc);
        }
        continue;
      }
      if (!_proxyTypes.contains(type)) {
        AutoConfUtils.skippedUnconvertible++;
        continue;
      }
      item.servers.add(_outboundToProxy(bound, usedTags));
    }
  }

  // Feature 2: endpoints are first-class nodes. A WireGuard endpoint
  // becomes the same wireguard ProxyConfig a .conf import produces.
  final endpoints = root['endpoints'];
  if (endpoints is List) {
    for (final entry in endpoints) {
      if (entry is! Map) {
        AutoConfUtils.skippedUnconvertible++;
        continue;
      }
      final endpoint = Map<String, dynamic>.from(entry);
      final type = (endpoint['type'] ?? '').toString();
      if (type == 'wireguard') {
        final pc = _wireguardEndpointToProxy(endpoint, usedTags);
        if (pc == null) {
          AutoConfUtils.skippedUnconvertible++;
        } else {
          item.servers.add(pc);
        }
        continue;
      }
      if (!_proxyTypes.contains(type)) {
        AutoConfUtils.skippedUnconvertible++;
        continue;
      }
      item.servers.add(_outboundToProxy(endpoint, usedTags));
    }
  }

  final route = root['route'];
  if (route is Map) {
    final ruleSets = route['rule_set'];
    if (ruleSets is List) {
      for (final rs in ruleSets) {
        if (rs is! Map) continue;
        final rsi = ServerDiversionGroupRuleSetItem()
          ..type = (rs['type'] ?? '').toString()
          ..tag = (rs['tag'] ?? '').toString()
          ..format = (rs['format'] ?? '').toString()
          ..url = rs['url']?.toString();
        final exists = ruleSetItems.any(
          (e) =>
              e.type == rsi.type &&
              e.tag == rsi.tag &&
              e.format == rsi.format &&
              e.url == rsi.url,
        );
        if (!exists) {
          ruleSetItems.add(rsi);
        }
      }
    }
    if (diversionGroupItem != null) {
      final rules = route['rules'];
      if (rules is List) {
        var n = 0;
        for (final rule in rules) {
          if (rule is! Map) continue;
          final group = _routeRuleToGroup(
            Map<String, dynamic>.from(rule),
            'rule-${++n}',
          );
          if (group != null) {
            group.groupid = diversionGroupItem.groupid;
            diversionGroupItem.groups.add(group);
          }
        }
      }
    }
  }
  return null;
}

ProxyConfig _outboundToProxy(Map<String, dynamic> bound, Set<String> usedTags) {
  final type = (bound['type'] ?? '').toString();
  final pc = ProxyConfig()
    ..type = type
    ..tag = AutoConfUtils._uniqueTag(
      (bound['tag'] ?? type).toString(),
      usedTags,
    )
    ..server = (bound['server'] ?? '').toString()
    ..serverport = bound['server_port'] is num
        ? (bound['server_port'] as num).toInt()
        : int.tryParse('${bound['server_port']}') ?? 0
    ..raw = bound;
  bound['tag'] = pc.tag;
  return pc;
}

/// Shared by `endpoints[]` entries and legacy wireguard outbounds.
ProxyConfig? _wireguardEndpointToProxy(
  Map<String, dynamic> endpoint,
  Set<String> usedTags,
) {
  final peers = endpoint['peers'];
  Map<String, dynamic>? firstPeer;
  if (peers is List && peers.isNotEmpty && peers.first is Map) {
    firstPeer = Map<String, dynamic>.from(peers.first as Map);
  }
  var tag = (endpoint['tag'] ?? '').toString();
  if (tag.isEmpty) {
    // Synthesise the .conf-style tag from the endpoint content so
    // re-importing the same profile keeps node identity (latencies,
    // selections). See the file header / spec §7.
    tag = 'wireguard:${AutoConfUtils._fnv1a(jsonEncode(endpoint))}';
    endpoint['tag'] = tag;
  }
  final pc = ProxyConfig()
    ..type = 'wireguard'
    ..tag = AutoConfUtils._uniqueTag(tag, usedTags)
    ..server = (firstPeer?['address'] ?? '').toString()
    ..serverport = firstPeer?['port'] is num
        ? (firstPeer!['port'] as num).toInt()
        : int.tryParse('${firstPeer?['port']}') ?? 0
    ..raw = endpoint;
  endpoint['tag'] = pc.tag;
  return pc;
}

DiversionRulesGroup? _routeRuleToGroup(
  Map<String, dynamic> rule,
  String fallbackName,
) {
  if (rule['type'] == 'logical') {
    final group = DiversionRulesGroup()
      ..name = fallbackName
      ..or = rule['mode'] != 'and';
    final subs = rule['rules'];
    if (subs is List) {
      var n = 0;
      for (final sub in subs) {
        if (sub is Map) {
          final subGroup = _routeRuleToGroup(
            Map<String, dynamic>.from(sub),
            '$fallbackName-${++n}',
          );
          if (subGroup != null) {
            group.groups.add(subGroup);
          }
        }
      }
    }
    _copyRouteMatchers(rule, group);
    return group;
  }
  final action = (rule['action'] ?? 'route').toString();
  if (action != 'route' && action != 'reject' && action != '') {
    // sniff / hijack-dns / resolve etc. have no diversion-group home in
    // this reconstruction.
    return null;
  }
  final group = DiversionRulesGroup()..name = fallbackName;
  _copyRouteMatchers(rule, group);
  final outbound = rule['outbound']?.toString();
  if (outbound != null && outbound.isNotEmpty) {
    group.proxies = [outbound];
  } else if (action == 'reject') {
    group.proxies = [kProxyBlock];
  }
  return group;
}

void _copyRouteMatchers(Map<String, dynamic> rule, DiversionRulesGroup group) {
  List<String> strings(String key) {
    final v = rule[key];
    if (v is List) return v.map((e) => e.toString()).toList();
    if (v is String) return [v];
    return <String>[];
  }

  group.domain = strings('domain');
  group.domainSuffix = strings('domain_suffix');
  group.domainKeyword = strings('domain_keyword');
  group.domainRegex = strings('domain_regex');
  group.ipCidr = strings('ip_cidr');
  group.package = strings('package_name');
  group.processName = strings('process_name');
  group.processPath = strings('process_path');
  group.network = strings('network');
  group.protocol = strings('protocol');
  group.portRange = strings('port_range');
  group.wifiSsid = strings('wifi_ssid');
  group.wifiBssid = strings('wifi_bssid');
  final ports = rule['port'];
  if (ports is List) {
    group.port = ports
        .map((e) => e is num ? e.toInt() : int.tryParse('$e') ?? 0)
        .where((e) => e > 0)
        .toList();
  }
  final ipVersion = rule['ip_version'];
  if (ipVersion is num) {
    group.ipVersion = ipVersion.toInt();
  }
  for (final tag in strings('rule_set')) {
    if (tag.startsWith('geosite:') ||
        tag.startsWith('geoip:') ||
        tag.startsWith('acl:')) {
      group.ruleSetBuildIn.add(tag);
    } else {
      group.ruleSet.add(tag);
    }
  }
}

// ---------------------------------------------------------------------------
// WireGuard .conf
// ---------------------------------------------------------------------------

ReturnResultError? _convertWireguardConf(
  String content,
  ServerConfigGroupItem item,
) {
  final sections = <String, Map<String, String>>{};
  var current = '';
  for (final rawLine in content.split('\n')) {
    final line = rawLine.trim();
    if (line.isEmpty || line.startsWith('#') || line.startsWith(';')) {
      continue;
    }
    if (line.startsWith('[') && line.endsWith(']')) {
      current = line.substring(1, line.length - 1);
      sections.putIfAbsent(current, () => <String, String>{});
      continue;
    }
    final eq = line.indexOf('=');
    if (eq > 0 && current.isNotEmpty) {
      sections[current]![line.substring(0, eq).trim()] = line
          .substring(eq + 1)
          .trim();
    }
  }
  final iface = sections['Interface'];
  final peer = sections['Peer'];
  if (iface == null || peer == null || iface['PrivateKey'] == null) {
    return ReturnResultError('invalid wireguard config');
  }
  final endpointHostPort = (peer['Endpoint'] ?? '').trim();
  final colon = endpointHostPort.lastIndexOf(':');
  final peerHost = colon > 0
      ? endpointHostPort.substring(0, colon)
      : endpointHostPort;
  final peerPort = colon > 0
      ? int.tryParse(endpointHostPort.substring(colon + 1)) ?? 51820
      : 51820;

  final endpoint = <String, dynamic>{
    'type': 'wireguard',
    'address':
        (iface['Address'] ?? '')
            .split(',')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList(),
    'private_key': iface['PrivateKey'],
    if (iface['MTU'] != null)
      'mtu': int.tryParse(iface['MTU']!) ?? 1280,
    'peers': [
      {
        'address': peerHost,
        'port': peerPort,
        'public_key': peer['PublicKey'] ?? '',
        if (peer['PresharedKey'] != null)
          'pre_shared_key': peer['PresharedKey'],
        'allowed_ips':
            (peer['AllowedIPs'] ?? '0.0.0.0/0')
                .split(',')
                .map((e) => e.trim())
                .where((e) => e.isNotEmpty)
                .toList(),
        if (peer['PersistentKeepalive'] != null)
          'persistent_keepalive_interval':
              int.tryParse(peer['PersistentKeepalive']!) ?? 0,
      },
    ],
  };
  // The tag the device showed for .conf-imported peers is
  // `wireguard:<number>`; the number's upstream derivation is not
  // observable in-repo (spec §7), so a stable content hash fills in.
  final tag = 'wireguard:${AutoConfUtils._fnv1a(content)}';
  endpoint['tag'] = tag;
  item.servers.add(
    ProxyConfig()
      ..type = 'wireguard'
      ..tag = tag
      ..server = peerHost
      ..serverport = peerPort
      ..raw = endpoint,
  );
  return null;
}

// ---------------------------------------------------------------------------
// Share-link lists (one URI per line)
// ---------------------------------------------------------------------------

ReturnResultError? _convertUriList(String content, ServerConfigGroupItem item) {
  final usedTags = <String>{};
  var converted = 0;
  for (final rawLine in content.split('\n')) {
    final line = rawLine.trim();
    if (line.isEmpty || line.startsWith('#')) {
      continue;
    }
    final pc = _shareLinkToProxy(line, usedTags);
    if (pc == null) {
      AutoConfUtils.skippedUnconvertible++;
      continue;
    }
    item.servers.add(pc);
    converted++;
  }
  if (converted == 0) {
    return ReturnResultError('no convertible share links');
  }
  return null;
}

String _decodeTag(String fragment, String fallback) {
  if (fragment.isEmpty) return fallback;
  try {
    return Uri.decodeComponent(fragment);
  } catch (_) {
    return fragment;
  }
}

ProxyConfig? _shareLinkToProxy(String line, Set<String> usedTags) {
  final schemeEnd = line.indexOf('://');
  if (schemeEnd <= 0) return null;
  final scheme = line.substring(0, schemeEnd).toLowerCase();
  switch (scheme) {
    case 'vmess':
      return _vmessToProxy(line.substring(schemeEnd + 3), usedTags);
    case 'vless':
      return _uriStyleToProxy(line, 'vless', usedTags);
    case 'trojan':
      return _uriStyleToProxy(line, 'trojan', usedTags);
    case 'ss':
      return _ssToProxy(line, usedTags);
    case 'hysteria2':
    case 'hy2':
      return _uriStyleToProxy(line, 'hysteria2', usedTags);
    case 'tuic':
      return _uriStyleToProxy(line, 'tuic', usedTags);
    default:
      return null;
  }
}

ProxyConfig? _vmessToProxy(String payload, Set<String> usedTags) {
  try {
    var normalized = payload.replaceAll('-', '+').replaceAll('_', '/');
    while (normalized.length % 4 != 0) {
      normalized += '=';
    }
    final map = jsonDecode(utf8.decode(base64Decode(normalized)));
    if (map is! Map) return null;
    final m = Map<String, dynamic>.from(map);
    final tag = AutoConfUtils._uniqueTag(
      (m['ps'] ?? 'vmess').toString(),
      usedTags,
    );
    final raw = <String, dynamic>{
      'type': 'vmess',
      'tag': tag,
      'server': (m['add'] ?? '').toString(),
      'server_port': int.tryParse('${m['port']}') ?? 0,
      'uuid': (m['id'] ?? '').toString(),
      'security': (m['scy'] ?? 'auto').toString(),
      'alter_id': int.tryParse('${m['aid']}') ?? 0,
    };
    final net = (m['net'] ?? 'tcp').toString();
    if (net != 'tcp') {
      raw['transport'] = {
        'type': net,
        if (m['path'] != null) 'path': m['path'].toString(),
        if (m['host'] != null)
          'headers': {'Host': m['host'].toString()},
      };
    }
    if ((m['tls'] ?? '').toString() == 'tls') {
      raw['tls'] = {
        'enabled': true,
        if (m['sni'] != null) 'server_name': m['sni'].toString(),
      };
    }
    return ProxyConfig()
      ..type = 'vmess'
      ..tag = tag
      ..server = raw['server'] as String
      ..serverport = raw['server_port'] as int
      ..raw = raw;
  } catch (_) {
    return null;
  }
}

/// vless / trojan / hysteria2 / tuic share links share the
/// `scheme://auth@host:port?query#name` shape.
ProxyConfig? _uriStyleToProxy(
  String line,
  String type,
  Set<String> usedTags,
) {
  final uri = Uri.tryParse(line);
  if (uri == null || uri.host.isEmpty) return null;
  final tag = AutoConfUtils._uniqueTag(
    _decodeTag(uri.fragment, type),
    usedTags,
  );
  final q = uri.queryParameters;
  final raw = <String, dynamic>{
    'type': type,
    'tag': tag,
    'server': uri.host,
    'server_port': uri.hasPort ? uri.port : 0,
  };
  final auth = Uri.decodeComponent(uri.userInfo);
  switch (type) {
    case 'vless':
      raw['uuid'] = auth;
      if (q['flow'] != null) raw['flow'] = q['flow'];
    case 'trojan':
      raw['password'] = auth;
    case 'hysteria2':
      raw['password'] = auth;
      if (q['obfs'] != null) {
        raw['obfs'] = {
          'type': q['obfs'],
          if (q['obfs-password'] != null) 'password': q['obfs-password'],
        };
      }
    case 'tuic':
      final parts = auth.split(':');
      raw['uuid'] = parts.first;
      if (parts.length > 1) raw['password'] = parts.sublist(1).join(':');
      if (q['congestion_control'] != null) {
        raw['congestion_control'] = q['congestion_control'];
      }
  }
  final network = q['type'] ?? q['network'];
  if (network != null && network != 'tcp') {
    raw['transport'] = {
      'type': network,
      if (q['path'] != null) 'path': q['path'],
      if (q['host'] != null) 'headers': {'Host': q['host']},
    };
  }
  final security = q['security'] ?? (type == 'trojan' ? 'tls' : null);
  if (security == 'tls' || security == 'reality') {
    final tls = <String, dynamic>{
      'enabled': true,
      if (q['sni'] != null) 'server_name': q['sni'],
      if (q['insecure'] == '1') 'insecure': true,
      if (q['alpn'] != null) 'alpn': q['alpn']!.split(','),
    };
    if (security == 'reality') {
      tls['reality'] = {
        'enabled': true,
        if (q['pbk'] != null) 'public_key': q['pbk'],
        if (q['sid'] != null) 'short_id': q['sid'],
      };
    }
    raw['tls'] = tls;
  }
  return ProxyConfig()
    ..type = type
    ..tag = tag
    ..server = uri.host
    ..serverport = uri.hasPort ? uri.port : 0
    ..raw = raw;
}

ProxyConfig? _ssToProxy(String line, Set<String> usedTags) {
  try {
    var rest = line.substring('ss://'.length);
    var fragment = '';
    final hashIdx = rest.indexOf('#');
    if (hashIdx >= 0) {
      fragment = rest.substring(hashIdx + 1);
      rest = rest.substring(0, hashIdx);
    }
    final queryIdx = rest.indexOf('?');
    if (queryIdx >= 0) {
      rest = rest.substring(0, queryIdx);
    }
    String method, password, host;
    int port;
    final atIdx = rest.lastIndexOf('@');
    if (atIdx < 0) {
      // Legacy form: the whole authority is base64(method:password@host:port).
      var normalized = rest.replaceAll('-', '+').replaceAll('_', '/');
      while (normalized.length % 4 != 0) {
        normalized += '=';
      }
      final decoded = utf8.decode(base64Decode(normalized));
      final m = RegExp(
        r'^(.+?):(.*)@(.+):(\d+)$',
      ).firstMatch(decoded);
      if (m == null) return null;
      method = m.group(1)!;
      password = m.group(2)!;
      host = m.group(3)!;
      port = int.parse(m.group(4)!);
    } else {
      var userInfo = rest.substring(0, atIdx);
      final hostPort = rest.substring(atIdx + 1);
      final colon = hostPort.lastIndexOf(':');
      if (colon < 0) return null;
      host = hostPort.substring(0, colon);
      port = int.tryParse(hostPort.substring(colon + 1)) ?? 0;
      if (!userInfo.contains(':')) {
        var normalized = userInfo.replaceAll('-', '+').replaceAll('_', '/');
        while (normalized.length % 4 != 0) {
          normalized += '=';
        }
        userInfo = utf8.decode(base64Decode(normalized));
      } else {
        userInfo = Uri.decodeComponent(userInfo);
      }
      final sep = userInfo.indexOf(':');
      if (sep < 0) return null;
      method = userInfo.substring(0, sep);
      password = userInfo.substring(sep + 1);
    }
    final tag = AutoConfUtils._uniqueTag(
      _decodeTag(fragment, 'shadowsocks'),
      usedTags,
    );
    final raw = <String, dynamic>{
      'type': 'shadowsocks',
      'tag': tag,
      'server': host,
      'server_port': port,
      'method': method,
      'password': password,
    };
    return ProxyConfig()
      ..type = 'shadowsocks'
      ..tag = tag
      ..server = host
      ..serverport = port
      ..raw = raw;
  } catch (_) {
    return null;
  }
}

// ---------------------------------------------------------------------------
// Clash / mihomo YAML
// ---------------------------------------------------------------------------

/// Transport networks with a sing-box equivalent. A node naming any
/// other network (xhttp/splithttp, kcp, ...) is skipped and counted.
const Set<String> _clashNetworks = {
  'tcp',
  'ws',
  'grpc',
  'h2',
  'http',
  'httpupgrade',
};

ReturnResultError? _convertClashYaml(
  String content,
  ServerConfigGroupItem item,
  List<ServerDiversionGroupRuleSetItem> ruleSetItems,
  ServerDiversionGroupItem? diversionGroupItem,
) {
  dynamic root;
  try {
    root = _yamlToPlain(loadYaml(content));
  } catch (err) {
    return ReturnResultError('invalid clash yaml: $err');
  }
  if (root is! Map<String, dynamic>) {
    return ReturnResultError('invalid clash yaml: not a mapping');
  }
  final proxiesRaw = root['proxies'];
  if (proxiesRaw is! List || proxiesRaw.isEmpty) {
    return ReturnResultError('invalid clash yaml: no proxies');
  }

  final usedTags = <String>{};
  // Clash display name -> final (uniquified) tag, for group membership,
  // rule targets and dialer-proxy references.
  final tagByName = <String, String>{};
  // Node -> clash name of its dialer-proxy, resolved once every tag is
  // known (a detour may point at a group declared further down).
  final pendingDetour = <ProxyConfig, String>{};

  for (final entry in proxiesRaw) {
    if (entry is! Map) {
      AutoConfUtils.skippedUnconvertible++;
      continue;
    }
    final e = Map<String, dynamic>.from(entry);
    final pc = _clashProxyToProxy(e, usedTags);
    if (pc == null) {
      AutoConfUtils.skippedUnconvertible++;
      continue;
    }
    final name = _clashStr(e, 'name');
    if (name.isNotEmpty) {
      tagByName[name] = pc.tag;
    }
    final detour = _clashStr(e, 'dialer-proxy');
    if (detour.isNotEmpty) {
      pendingDetour[pc] = detour;
    }
    item.servers.add(pc);
  }

  _convertClashGroups(root['proxy-groups'], item, usedTags, tagByName);

  for (final server in item.servers) {
    final detourName = pendingDetour[server];
    if (detourName != null) {
      final detour = _clashResolveTarget(detourName, tagByName);
      if (detour != null && detour != server.tag) {
        server.raw['detour'] = detour;
      }
    }
  }
  // Groups may carry dialer-proxy too; resolve against final tags.
  for (final def in _clashGroupDefs(root['proxy-groups'])) {
    final detourName = _clashStr(def, 'dialer-proxy');
    if (detourName.isEmpty) continue;
    final tag = tagByName[_clashStr(def, 'name')];
    final detour = _clashResolveTarget(detourName, tagByName);
    if (tag == null || detour == null || detour == tag) continue;
    for (final server in item.servers) {
      if (server.tag == tag) {
        server.raw['detour'] = detour;
      }
    }
  }

  if (diversionGroupItem != null) {
    _convertClashRules(root['rules'], tagByName, diversionGroupItem);
  }
  return null;
}

List<Map<String, dynamic>> _clashGroupDefs(dynamic groupsRaw) {
  final defs = <Map<String, dynamic>>[];
  if (groupsRaw is List) {
    for (final g in groupsRaw) {
      if (g is Map) {
        defs.add(Map<String, dynamic>.from(g));
      }
    }
  }
  return defs;
}

void _convertClashGroups(
  dynamic groupsRaw,
  ServerConfigGroupItem item,
  Set<String> usedTags,
  Map<String, String> tagByName,
) {
  final defs = _clashGroupDefs(groupsRaw);
  // Pass 1: allocate every convertible group's tag up front so a group
  // may list a group declared later in the file as a member. Groups of
  // a type with no sing-box form (load-balance / relay / smart) are
  // counted here and never registered, so references to them fail to
  // resolve instead of dangling.
  final plan = <(Map<String, dynamic>, String, String)>[];
  for (final def in defs) {
    final name = _clashStr(def, 'name');
    final type = _clashStr(def, 'type').toLowerCase();
    final String rawType;
    switch (type) {
      case 'select':
        rawType = 'selector';
      case 'url-test':
      case 'fallback':
        // sing-box has no fallback outbound; urltest (first healthy
        // member wins) is its closest expressible semantics.
        rawType = 'urltest';
      default:
        rawType = '';
    }
    if (name.isEmpty || rawType.isEmpty) {
      AutoConfUtils.skippedUnconvertible++;
      continue;
    }
    final tag = AutoConfUtils._uniqueTag(name, usedTags);
    tagByName[name] = tag;
    plan.add((def, tag, rawType));
  }
  // Pass 2: build the group outbounds.
  for (final (def, tag, rawType) in plan) {
    final members = <String>[];
    for (final member in _clashStrList(def, 'proxies')) {
      final resolved = _clashResolveTarget(member, tagByName);
      if (resolved != null && !members.contains(resolved)) {
        members.add(resolved);
      }
    }
    if (members.isEmpty) {
      // e.g. a group fed only by proxy-providers (`use:`), whose
      // members are not part of this document.
      tagByName.remove(_clashStr(def, 'name'));
      AutoConfUtils.skippedUnconvertible++;
      continue;
    }
    final raw = <String, dynamic>{
      'type': rawType,
      'tag': tag,
      'outbounds': members,
    };
    if (rawType == 'selector') {
      raw['default'] = members.first;
    } else {
      final url = _clashStr(def, 'url');
      raw['url'] = url.isEmpty
          ? 'http://www.gstatic.com/generate_204'
          : url;
      final interval = _clashInt(def, 'interval');
      if (interval > 0) raw['interval'] = '${interval}s';
      final tolerance = _clashInt(def, 'tolerance');
      if (tolerance > 0) raw['tolerance'] = tolerance;
    }
    item.servers.add(
      ProxyConfig()
        ..type = rawType
        ..tag = tag
        ..raw = raw,
    );
  }
}

void _convertClashRules(
  dynamic rulesRaw,
  Map<String, String> tagByName,
  ServerDiversionGroupItem diversionGroupItem,
) {
  if (rulesRaw is! List) return;
  var n = 0;
  for (final entry in rulesRaw) {
    n++;
    final line = entry?.toString().trim() ?? '';
    if (line.isEmpty) continue;
    final group = _clashRuleToGroup(line, 'rule-$n', tagByName);
    if (group == null) {
      AutoConfUtils.skippedUnconvertible++;
      continue;
    }
    group.groupid = diversionGroupItem.groupid;
    diversionGroupItem.groups.add(group);
  }
}

DiversionRulesGroup? _clashRuleToGroup(
  String line,
  String name,
  Map<String, String> tagByName,
) {
  // Logical combinators (AND,((...),(...)),TARGET) nest commas inside
  // parentheses; a flat split cannot represent them.
  if (line.contains('((')) return null;
  final parts = line.split(',').map((p) => p.trim()).toList();
  if (parts.length < 2) return null;
  final type = parts[0].toUpperCase();
  final String arg;
  final String targetName;
  if (type == 'MATCH' || type == 'FINAL') {
    arg = '';
    targetName = parts[1];
  } else {
    if (parts.length < 3) return null;
    arg = parts[1];
    targetName = parts[2];
    // Any further fields are options (no-resolve, ...) and are ignored.
  }
  final target = _clashResolveTarget(targetName, tagByName);
  if (target == null) return null;
  final group = DiversionRulesGroup()
    ..name = name
    ..proxies = [target];
  switch (type) {
    case 'DOMAIN':
      group.domain = [arg];
    case 'DOMAIN-SUFFIX':
      group.domainSuffix = [arg];
    case 'DOMAIN-KEYWORD':
      group.domainKeyword = [arg];
    case 'DOMAIN-REGEX':
      group.domainRegex = [arg];
    case 'IP-CIDR':
    case 'IP-CIDR6':
      group.ipCidr = [arg];
    case 'GEOIP':
      group.ruleSetBuildIn = ['geoip:${arg.toLowerCase()}'];
    case 'GEOSITE':
      group.ruleSetBuildIn = ['geosite:${arg.toLowerCase()}'];
    case 'PROCESS-NAME':
      group.processName = [arg];
    case 'PROCESS-PATH':
      group.processPath = [arg];
    case 'NETWORK':
      group.network = [arg.toLowerCase()];
    case 'DST-PORT':
      if (arg.contains('-')) {
        group.portRange = [arg];
      } else {
        final port = int.tryParse(arg);
        if (port == null) return null;
        group.port = [port];
      }
    case 'RULE-SET':
      group.ruleSet = [arg];
    case 'MATCH':
    case 'FINAL':
      // Catch-all: a group with a target and no matchers, exactly what
      // the JSON converter yields for a matcher-less route rule.
      break;
    default:
      // SRC-IP-CIDR / SRC-PORT / IN-PORT / IP-ASN / DOMAIN-WILDCARD ...
      // have no field on DiversionRulesGroup.
      return null;
  }
  return group;
}

/// Clash built-in targets plus the profile's own names.
String? _clashResolveTarget(String name, Map<String, String> tagByName) {
  if (name == 'DIRECT') return kProxyDirect;
  if (name == 'REJECT' || name == 'REJECT-DROP') return kProxyBlock;
  return tagByName[name];
}

dynamic _yamlToPlain(dynamic node) {
  if (node is YamlMap) {
    final ret = <String, dynamic>{};
    node.forEach((k, v) => ret[k.toString()] = _yamlToPlain(v));
    return ret;
  }
  if (node is YamlList) {
    return node.map(_yamlToPlain).toList();
  }
  if (node is YamlScalar) return node.value;
  return node;
}

String _clashStr(Map<String, dynamic> m, String key) =>
    m[key]?.toString() ?? '';

int _clashInt(Map<String, dynamic> m, String key) {
  final v = m[key];
  if (v is num) return v.toInt();
  return int.tryParse('${v ?? ''}') ?? 0;
}

bool _clashBool(Map<String, dynamic> m, String key) {
  final v = m[key];
  return v == true || v?.toString() == 'true';
}

/// Lists arrive as YAML lists; some providers write them comma-joined.
List<String> _clashStrList(Map<String, dynamic> m, String key) {
  final v = m[key];
  if (v is List) return v.map((e) => e.toString()).toList();
  if (v is String) {
    return v
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
  }
  return <String>[];
}

Map<String, dynamic> _clashMap(Map<String, dynamic> m, String key) {
  final v = m[key];
  if (v is Map) return Map<String, dynamic>.from(v);
  return <String, dynamic>{};
}

/// Leading number of a mihomo bandwidth string ("30 Mbps" -> 30).
int _clashMbps(dynamic v) {
  if (v is num) return v.toInt();
  final match = RegExp(r'\d+').firstMatch(v?.toString() ?? '');
  return match == null ? 0 : int.parse(match.group(0)!);
}

/// Finishes a node whose sing-box [raw] map is already built: allocates
/// the tag (the clash `name`) and mirrors the scalar fields, exactly
/// like [_outboundToProxy] does for JSON sources.
ProxyConfig _clashFinish(
  Map<String, dynamic> raw,
  String name,
  Set<String> usedTags,
) {
  final tag = AutoConfUtils._uniqueTag(
    name.isEmpty ? (raw['type'] ?? 'proxy').toString() : name,
    usedTags,
  );
  raw['tag'] = tag;
  return ProxyConfig()
    ..type = (raw['type'] ?? '').toString()
    ..tag = tag
    ..server = (raw['server'] ?? '').toString()
    ..serverport = raw['server_port'] is num
        ? (raw['server_port'] as num).toInt()
        : 0
    ..raw = raw;
}

/// The sing-box `tls` block shared by the TLS-carrying protocols.
/// mihomo spells the server name `sni` on some protocols and
/// `servername` on others; both are honoured.
Map<String, dynamic> _clashTls(Map<String, dynamic> e) {
  final tls = <String, dynamic>{'enabled': true};
  var sni = _clashStr(e, 'sni');
  if (sni.isEmpty) sni = _clashStr(e, 'servername');
  if (sni.isNotEmpty) tls['server_name'] = sni;
  if (_clashBool(e, 'skip-cert-verify')) tls['insecure'] = true;
  final alpn = _clashStrList(e, 'alpn');
  if (alpn.isNotEmpty) tls['alpn'] = alpn;
  final fingerprint = _clashStr(e, 'client-fingerprint');
  if (fingerprint.isNotEmpty) {
    tls['utls'] = {'enabled': true, 'fingerprint': fingerprint};
  }
  final reality = _clashMap(e, 'reality-opts');
  if (reality.isNotEmpty) {
    tls['reality'] = {
      'enabled': true,
      if (_clashStr(reality, 'public-key').isNotEmpty)
        'public_key': _clashStr(reality, 'public-key'),
      if (_clashStr(reality, 'short-id').isNotEmpty)
        'short_id': _clashStr(reality, 'short-id'),
    };
  }
  return tls;
}

/// The sing-box `transport` block for vmess / vless / trojan, or null
/// for plain tcp. Callers reject networks outside [_clashNetworks]
/// before calling.
Map<String, dynamic>? _clashTransport(Map<String, dynamic> e) {
  final net = _clashStr(e, 'network');
  switch (net) {
    case '':
    case 'tcp':
      return null;
    case 'ws':
      final opts = _clashMap(e, 'ws-opts');
      final headers = <String, dynamic>{};
      final rawHeaders = opts['headers'];
      if (rawHeaders is Map) {
        rawHeaders.forEach(
          (k, v) => headers[k.toString()] = v.toString(),
        );
      }
      if (headers.isEmpty && _clashStr(opts, 'host').isNotEmpty) {
        headers['Host'] = _clashStr(opts, 'host');
      }
      return {
        'type': 'ws',
        if (_clashStr(opts, 'path').isNotEmpty)
          'path': _clashStr(opts, 'path'),
        if (headers.isNotEmpty) 'headers': headers,
      };
    case 'httpupgrade':
      final opts = _clashMap(e, 'ws-opts');
      return {
        'type': 'httpupgrade',
        if (_clashStr(opts, 'path').isNotEmpty)
          'path': _clashStr(opts, 'path'),
        if (_clashStr(opts, 'host').isNotEmpty)
          'host': _clashStr(opts, 'host'),
      };
    case 'grpc':
      final opts = _clashMap(e, 'grpc-opts');
      return {
        'type': 'grpc',
        if (_clashStr(opts, 'grpc-service-name').isNotEmpty)
          'service_name': _clashStr(opts, 'grpc-service-name'),
      };
    case 'h2':
      final opts = _clashMap(e, 'h2-opts');
      final hosts = _clashStrList(opts, 'host');
      return {
        'type': 'http',
        if (hosts.isNotEmpty) 'host': hosts,
        if (_clashStr(opts, 'path').isNotEmpty)
          'path': _clashStr(opts, 'path'),
      };
    case 'http':
      final opts = _clashMap(e, 'http-opts');
      final paths = _clashStrList(opts, 'path');
      final headers = <String, dynamic>{};
      final rawHeaders = opts['headers'];
      if (rawHeaders is Map) {
        rawHeaders.forEach((k, v) {
          headers[k.toString()] = v is List
              ? v.map((x) => x.toString()).toList()
              : v.toString();
        });
      }
      return {
        'type': 'http',
        if (paths.isNotEmpty) 'path': paths.first,
        if (headers.isNotEmpty) 'headers': headers,
      };
  }
  return null;
}

ProxyConfig? _clashProxyToProxy(
  Map<String, dynamic> e,
  Set<String> usedTags,
) {
  final type = _clashStr(e, 'type').toLowerCase();
  final name = _clashStr(e, 'name');
  final server = _clashStr(e, 'server');
  final port = _clashInt(e, 'port');
  final network = _clashStr(e, 'network');
  final hasNetwork =
      network.isEmpty || _clashNetworks.contains(network);
  switch (type) {
    case 'ss':
      return _clashSs(e, name, server, port, usedTags);
    case 'vmess':
      if (!hasNetwork) return null;
      final raw = <String, dynamic>{
        'type': 'vmess',
        'server': server,
        'server_port': port,
        'uuid': _clashStr(e, 'uuid'),
        'security': _clashStr(e, 'cipher').isEmpty
            ? 'auto'
            : _clashStr(e, 'cipher'),
        'alter_id': _clashInt(e, 'alterId'),
        if (_clashBool(e, 'global-padding')) 'global_padding': true,
        if (_clashBool(e, 'authenticated-length'))
          'authenticated_length': true,
      };
      final transport = _clashTransport(e);
      if (transport != null) raw['transport'] = transport;
      if (_clashBool(e, 'tls')) raw['tls'] = _clashTls(e);
      return _clashFinish(raw, name, usedTags);
    case 'vless':
      if (!hasNetwork) return null;
      final raw = <String, dynamic>{
        'type': 'vless',
        'server': server,
        'server_port': port,
        'uuid': _clashStr(e, 'uuid'),
        if (_clashStr(e, 'flow').isNotEmpty) 'flow': _clashStr(e, 'flow'),
      };
      final transport = _clashTransport(e);
      if (transport != null) raw['transport'] = transport;
      if (_clashBool(e, 'tls')) raw['tls'] = _clashTls(e);
      switch (_clashStr(e, 'packet-encoding')) {
        case 'xudp':
          raw['packet_encoding'] = 'xudp';
        case 'packet':
          raw['packet_encoding'] = 'packetaddr';
      }
      return _clashFinish(raw, name, usedTags);
    case 'trojan':
      if (!hasNetwork) return null;
      final raw = <String, dynamic>{
        'type': 'trojan',
        'server': server,
        'server_port': port,
        'password': _clashStr(e, 'password'),
        'tls': _clashTls(e),
      };
      final transport = _clashTransport(e);
      if (transport != null) raw['transport'] = transport;
      return _clashFinish(raw, name, usedTags);
    case 'hysteria2':
      final raw = <String, dynamic>{
        'type': 'hysteria2',
        'server': server,
        'server_port': port,
        'password': _clashStr(e, 'password'),
        'tls': _clashTls(e),
      };
      final obfs = _clashStr(e, 'obfs');
      if (obfs.isNotEmpty) {
        // sing-box hysteria2 only defines the salamander obfuscator.
        if (obfs != 'salamander') return null;
        raw['obfs'] = {
          'type': obfs,
          if (_clashStr(e, 'obfs-password').isNotEmpty)
            'password': _clashStr(e, 'obfs-password'),
        };
      }
      final up = _clashMbps(e['up']);
      if (up > 0) raw['up_mbps'] = up;
      final down = _clashMbps(e['down']);
      if (down > 0) raw['down_mbps'] = down;
      final ports = _clashStrList(e, 'ports');
      if (ports.isNotEmpty) raw['server_ports'] = ports;
      if (_clashStr(e, 'hop-interval').isNotEmpty) {
        raw['hop_interval'] = _clashStr(e, 'hop-interval');
      }
      return _clashFinish(raw, name, usedTags);
    case 'hysteria':
      final raw = <String, dynamic>{
        'type': 'hysteria',
        'server': server,
        'server_port': port,
        'tls': _clashTls(e),
      };
      final auth = _clashStr(e, 'auth-str').isNotEmpty
          ? _clashStr(e, 'auth-str')
          : _clashStr(e, 'auth_str');
      if (auth.isNotEmpty) raw['auth_str'] = auth;
      if (_clashStr(e, 'obfs').isNotEmpty) {
        raw['obfs'] = _clashStr(e, 'obfs');
      }
      if (_clashStr(e, 'protocol').isNotEmpty) {
        raw['protocol'] = _clashStr(e, 'protocol');
      }
      final up = _clashMbps(e['up']);
      if (up > 0) raw['up_mbps'] = up;
      final down = _clashMbps(e['down']);
      if (down > 0) raw['down_mbps'] = down;
      return _clashFinish(raw, name, usedTags);
    case 'tuic':
      final tls = _clashTls(e);
      if (_clashBool(e, 'disable-sni')) tls.remove('server_name');
      final raw = <String, dynamic>{
        'type': 'tuic',
        'server': server,
        'server_port': port,
        'uuid': _clashStr(e, 'uuid'),
        'password': _clashStr(e, 'password'),
        'tls': tls,
        if (_clashStr(e, 'congestion-controller').isNotEmpty)
          'congestion_control': _clashStr(e, 'congestion-controller'),
        if (_clashStr(e, 'udp-relay-mode').isNotEmpty)
          'udp_relay_mode': _clashStr(e, 'udp-relay-mode'),
        if (e.containsKey('zero-rtt-handshake'))
          'zero_rtt_handshake': _clashBool(e, 'zero-rtt-handshake'),
        if (_clashStr(e, 'heartbeat').isNotEmpty)
          'heartbeat': _clashStr(e, 'heartbeat'),
      };
      return _clashFinish(raw, name, usedTags);
    case 'wireguard':
      return _clashWireguard(e, name, usedTags);
    case 'socks5':
      // A TLS-wrapped socks5 has no plain sing-box socks form.
      if (_clashBool(e, 'tls')) return null;
      final raw = <String, dynamic>{
        'type': 'socks',
        'server': server,
        'server_port': port,
        if (_clashStr(e, 'username').isNotEmpty)
          'username': _clashStr(e, 'username'),
        if (_clashStr(e, 'password').isNotEmpty)
          'password': _clashStr(e, 'password'),
      };
      return _clashFinish(raw, name, usedTags);
    case 'http':
      final raw = <String, dynamic>{
        'type': 'http',
        'server': server,
        'server_port': port,
        if (_clashStr(e, 'username').isNotEmpty)
          'username': _clashStr(e, 'username'),
        if (_clashStr(e, 'password').isNotEmpty)
          'password': _clashStr(e, 'password'),
        if (_clashBool(e, 'tls')) 'tls': _clashTls(e),
      };
      return _clashFinish(raw, name, usedTags);
    case 'anytls':
      final raw = <String, dynamic>{
        'type': 'anytls',
        'server': server,
        'server_port': port,
        'password': _clashStr(e, 'password'),
        'tls': _clashTls(e),
        if (_clashStr(e, 'idle-session-check-interval').isNotEmpty)
          'idle_session_check_interval':
              _clashStr(e, 'idle-session-check-interval'),
        if (_clashStr(e, 'idle-session-timeout').isNotEmpty)
          'idle_session_timeout': _clashStr(e, 'idle-session-timeout'),
        if (_clashInt(e, 'min-idle-session') > 0)
          'min_idle_session': _clashInt(e, 'min-idle-session'),
      };
      return _clashFinish(raw, name, usedTags);
    default:
      // ssr (removed from sing-box), snell, mieru, ... have no core form.
      return null;
  }
}

ProxyConfig? _clashSs(Map<String, dynamic> e, String name, String server, int port, Set<String> usedTags) {
  final raw = <String, dynamic>{
    'type': 'shadowsocks',
    'server': server,
    'server_port': port,
    'method': _clashStr(e, 'cipher'),
    'password': _clashStr(e, 'password'),
  };
  final plugin = _clashStr(e, 'plugin');
  if (plugin.isNotEmpty) {
    final mapped = _clashSsPlugin(plugin, e['plugin-opts']);
    if (mapped == null) return null;
    raw['plugin'] = mapped.$1;
    raw['plugin_opts'] = mapped.$2;
  }
  if (_clashBool(e, 'udp-over-tcp')) {
    raw['udp_over_tcp'] = {'enabled': true, 'version': 2};
  }
  return _clashFinish(raw, name, usedTags);
}

/// mihomo ss plugin -> (sing-box plugin name, plugin_opts string), or
/// null when the plugin has no sing-box equivalent.
(String, String)? _clashSsPlugin(String plugin, dynamic optsRaw) {
  final opts = <String, String>{};
  if (optsRaw is Map) {
    optsRaw.forEach((k, v) => opts[k.toString()] = v.toString());
  } else if (optsRaw is String) {
    for (final part in optsRaw.split(';')) {
      final kv = part.split('=');
      if (kv.length == 2) opts[kv[0].trim()] = kv[1].trim();
    }
  }
  String joinOpts(List<String> parts) =>
      parts.where((p) => p.isNotEmpty).join(';');
  switch (plugin) {
    case 'obfs':
      return (
        'obfs-local',
        joinOpts([
          'obfs=${opts['mode'] ?? 'http'}',
          if (opts['host'] != null) 'obfs-host=${opts['host']}',
        ]),
      );
    case 'v2ray-plugin':
      return (
        'v2ray-plugin',
        joinOpts([
          'mode=${opts['mode'] ?? 'websocket'}',
          if (opts['host'] != null) 'host=${opts['host']}',
          if (opts['path'] != null) 'path=${opts['path']}',
          if (opts['tls'] == 'true') 'tls',
          if (opts['mux'] == 'true') 'mux',
        ]),
      );
    case 'shadow-tls':
      return (
        'shadow-tls',
        joinOpts([
          if (opts['host'] != null) 'host=${opts['host']}',
          if (opts['password'] != null) 'password=${opts['password']}',
          if (opts['version'] != null) 'version=${opts['version']}',
        ]),
      );
  }
  return null;
}

/// A mihomo wireguard proxy becomes the same sing-box endpoint shape a
/// .conf import produces (see [_wireguardEndpointToProxy]); the clash
/// `name` rides along as the endpoint tag so the node keeps its display
/// name instead of a synthesised hash.
ProxyConfig? _clashWireguard(
  Map<String, dynamic> e,
  String name,
  Set<String> usedTags,
) {
  final addresses = <String>[];
  if (_clashStr(e, 'ip').isNotEmpty) addresses.add(_clashStr(e, 'ip'));
  if (_clashStr(e, 'ipv6').isNotEmpty) {
    addresses.add(_clashStr(e, 'ipv6'));
  }
  final allowedIps = _clashStrList(e, 'allowed-ips');
  final reserved = <int>[];
  final reservedRaw = e['reserved'];
  if (reservedRaw is List) {
    for (final v in reservedRaw) {
      final n = v is num ? v.toInt() : int.tryParse('$v');
      if (n != null) reserved.add(n);
    }
  } else if (reservedRaw is String) {
    for (final part in reservedRaw.split(',')) {
      final n = int.tryParse(part.trim());
      if (n != null) reserved.add(n);
    }
  }
  final peer = <String, dynamic>{
    'address': _clashStr(e, 'server'),
    'port': _clashInt(e, 'port'),
    'public_key': _clashStr(e, 'public-key'),
    if (_clashStr(e, 'pre-shared-key').isNotEmpty)
      'pre_shared_key': _clashStr(e, 'pre-shared-key'),
    'allowed_ips': allowedIps.isEmpty
        ? ['0.0.0.0/0', '::/0']
        : allowedIps,
    if (_clashInt(e, 'keepalive') > 0)
      'persistent_keepalive_interval': _clashInt(e, 'keepalive'),
    if (reserved.isNotEmpty) 'reserved': reserved,
  };
  final endpoint = <String, dynamic>{
    'type': 'wireguard',
    'address': addresses,
    'private_key': _clashStr(e, 'private-key'),
    if (_clashInt(e, 'mtu') > 0) 'mtu': _clashInt(e, 'mtu'),
    'peers': [peer],
  };
  if (name.isNotEmpty) endpoint['tag'] = name;
  return _wireguardEndpointToProxy(endpoint, usedTags);
}
