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
// Clash YAML is recognised but NOT yet converted (returns an error
// instead of silently producing zero nodes). Unconvertible entries
// inside a supported format are skipped and counted in
// [AutoConfUtils.skippedUnconvertible], never fatal.
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
        uas.isNotEmpty ? uas.join(';') : 'Karing',
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
    if (content.contains('proxies:') && content.contains('proxy-groups:')) {
      // Recognised, but the clash YAML converter is not part of this
      // reconstruction phase. Fail loudly instead of yielding zero nodes.
      return ReturnResultError(
        'clash yaml conversion not yet reconstructed',
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
