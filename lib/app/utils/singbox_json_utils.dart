// Reconstructed for the Yousj Enhanced fork (upstream file missing).
//
// API pinned from call sites (about_screen.dart:574-582, the "import
// sing-box JSON profile" flow):
//   TransExceptionAndUnsupport eu = TransExceptionAndUnsupport();
//   var cresult = SingboxJsonUtils.tryConvert(
//       content, proxyItem, rulesetItems, null, eu);
//   if (cresult.error != null) { ...show cresult.error!.message... }
// — converts a sing-box JSON config into the app model: proxy outbounds
// become ProxyConfig entries on [proxyItem]; route rule-sets become
// ServerDiversionGroupRuleSetItem entries; structural/unsupported
// outbound types are collected into [eu] instead of being dropped
// silently.
//
// This is the sing-box-JSON sibling of AutoConfUtils.tryConvert (which
// handles subscription text / Clash YAML notations).

import 'dart:convert';

import 'package:karing/app/runtime/return_result.dart';
import 'package:vpn_service/state.dart';

/// Outbound types that carry a server endpoint and become ProxyConfigs.
const Set<String> kSingboxProxyTypes = {
  'shadowsocks',
  'shadowsocksr',
  'shadowtls',
  'vmess',
  'vless',
  'trojan',
  'socks',
  'http',
  'hysteria',
  'hysteria2',
  'tuic',
  'ssh',
  'anytls',
  'naive',
  'snell',
  'mieru',
  'sudoku',
  'trusttunnel',
  'masque',
  'openvpn-client',
};

/// Structural types that are valid sing-box but not servers.
const Set<String> kSingboxStructuralTypes = {
  'direct',
  'block',
  'dns',
  'selector',
  'urltest',
  'tor',
  'tailscale',
};

class TransExceptionAndUnsupport {
  /// Tags/types that could not be converted.
  List<String> unsupported = [];

  String get message => unsupported.join(', ');
}

class SingboxJsonUtils {
  static ReturnResult<bool> tryConvert(
    String content,
    ServerConfigGroupItem proxyItem,
    List<ServerDiversionGroupRuleSetItem> rulesetItems,
    String? remark,
    TransExceptionAndUnsupport eu,
  ) {
    dynamic decoded;
    try {
      decoded = jsonDecode(content);
    } catch (err) {
      return ReturnResult(error: ReturnResultError(err.toString()));
    }
    if (decoded is! Map<String, dynamic>) {
      return ReturnResult(
        error: ReturnResultError('invalid sing-box json: root is not an object'),
      );
    }

    if (remark != null && remark.isNotEmpty) {
      proxyItem.remark = remark;
    }

    void convertOutbound(Map<String, dynamic> outbound) {
      final type = outbound['type']?.toString() ?? '';
      final tag = outbound['tag']?.toString() ?? '';
      if (kSingboxProxyTypes.contains(type)) {
        final server = ProxyConfig();
        server.type = type;
        server.tag = tag;
        server.groupid = proxyItem.groupid;
        server.index = proxyItem.servers.length;
        server.server = outbound['server']?.toString() ?? '';
        final port = outbound['server_port'];
        server.serverport = port is num
            ? port.toInt()
            : (int.tryParse(port?.toString() ?? '') ?? 0);
        server.raw = outbound;
        proxyItem.servers.add(server);
      } else if (kSingboxStructuralTypes.contains(type)) {
        // Structural outbounds (selectors, urltest groups, ...) have no
        // server to import; note them so the caller can warn.
        if (type == 'selector' || type == 'urltest') {
          eu.unsupported.add('$type:$tag');
        }
      } else if (type.isNotEmpty) {
        eu.unsupported.add('$type:$tag');
      }
    }

    final outbounds = decoded['outbounds'];
    if (outbounds is List) {
      for (final entry in outbounds) {
        if (entry is Map<String, dynamic>) {
          convertOutbound(entry);
        }
      }
    }
    // WireGuard peers live under "endpoints" in sing-box >= 1.11.
    final endpoints = decoded['endpoints'];
    if (endpoints is List) {
      for (final entry in endpoints) {
        if (entry is Map<String, dynamic>) {
          if (entry['type'] == 'wireguard') {
            final server = ProxyConfig();
            server.type = 'wireguard';
            server.tag = entry['tag']?.toString() ?? '';
            server.groupid = proxyItem.groupid;
            server.index = proxyItem.servers.length;
            final peers = entry['peers'];
            if (peers is List && peers.isNotEmpty && peers.first is Map) {
              final peer = peers.first as Map;
              server.server = peer['address']?.toString() ?? '';
              final port = peer['port'];
              server.serverport = port is num
                  ? port.toInt()
                  : (int.tryParse(port?.toString() ?? '') ?? 0);
            }
            server.raw = entry;
            proxyItem.servers.add(server);
          } else {
            eu.unsupported.add('${entry['type']}:${entry['tag']}');
          }
        }
      }
    }

    final route = decoded['route'];
    if (route is Map<String, dynamic>) {
      final ruleSets = route['rule_set'];
      if (ruleSets is List) {
        for (final entry in ruleSets) {
          if (entry is Map<String, dynamic>) {
            final item = ServerDiversionGroupRuleSetItem();
            item.type = entry['type']?.toString() ?? '';
            item.tag = entry['tag']?.toString() ?? '';
            item.format = entry['format']?.toString() ?? '';
            item.url = entry['url']?.toString();
            rulesetItems.add(item);
          }
        }
      }
    }

    if (proxyItem.servers.isEmpty) {
      return ReturnResult(
        error: ReturnResultError('no proxy servers found in sing-box json'),
      );
    }
    return ReturnResult(data: true);
  }
}
