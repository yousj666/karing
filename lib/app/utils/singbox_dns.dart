// singbox_dns.dart — RECONSTRUCTED by the yousj-plus fork.
//
// The upstream Karing release does not ship this file (partial source
// release). It holds the DNS option classes used by
// ServerManager.testDNSConnectLatency (server_manager.dart:1145–1188) and
// conceptually by SingboxConfigBuilder.dns: parsed DNS server options, the
// domain-resolver descriptor, the batch option used in DNS query requests,
// and the DNSQueryRequest payload handed to ClashApi.dnsQuery.
//
// Shapes follow sing-box 1.12 DNS server options (type/tag/server/
// server_port/detour/domain_resolver). The batch class is a Karing-internal
// grouping (its `servers` are tags or URLs, per the call sites); it is not
// emitted into generated configs as-is.

import 'package:karing/app/runtime/return_result.dart';

/// Resolver used to resolve the domain name of another DNS server
/// (sing-box `domain_resolver`).
class SingboxDNSDomainResolver {
  String server;
  String strategy;

  SingboxDNSDomainResolver({required this.server, this.strategy = ''});

  Map<String, dynamic> toJson() => {
    'server': server,
    if (strategy.isNotEmpty) 'strategy': strategy,
  };
}

/// Base of everything that can sit in a DNS server list: it has a tag and
/// serialises to sing-box-flavoured JSON.
abstract class SingboxDNSOptions {
  String get tag;
  Map<String, dynamic> toJson();
}

/// One parsed DNS server (udp/tcp/tls/https/h3/quic/local/dhcp).
class SingboxDNSServerOptions implements SingboxDNSOptions {
  @override
  String tag;
  String type;
  String server;
  int serverPort;
  String? detour;
  SingboxDNSDomainResolver? domainResolver;

  /// For `dhcp` servers: the network interface name.
  String? interface;

  /// For `https`/`h3` servers: the URL path.
  String? path;

  SingboxDNSServerOptions({
    required this.tag,
    required this.type,
    this.server = '',
    this.serverPort = 0,
    this.detour,
    this.domainResolver,
    this.interface,
    this.path,
  });

  @override
  Map<String, dynamic> toJson() => {
    'type': type,
    'tag': tag,
    if (server.isNotEmpty) 'server': server,
    if (serverPort > 0) 'server_port': serverPort,
    if (detour != null && detour!.isNotEmpty) 'detour': detour,
    if (domainResolver != null) 'domain_resolver': domainResolver!.toJson(),
    if (interface != null && interface!.isNotEmpty) 'interface': interface,
    if (path != null && path!.isNotEmpty) 'path': path,
  };
}

/// Groups several servers (by tag or URL) under one tag for a DNS query
/// request (server_manager.dart:1176–1184).
class SingboxDNSServerBatchOptions implements SingboxDNSOptions {
  @override
  String tag;
  List<String> servers;

  SingboxDNSServerBatchOptions(this.tag, {required this.servers});

  @override
  Map<String, dynamic> toJson() => {'tag': tag, 'servers': servers};
}

/// Payload of a Clash-API DNS query (built in
/// ServerManager.testDNSConnectLatency, consumed by ClashApi.dnsQuery).
class DNSQueryRequest {
  List<SingboxDNSOptions> servers = [];
  String tag = '';
  String domain = '';
  String strategy = '';

  Map<String, dynamic> toJson() => {
    'servers': servers.map((e) => e.toJson()).toList(),
    'tag': tag,
    'domain': domain,
    'strategy': strategy,
  };
}

bool _isIpLiteral(String host) {
  if (host.contains(':')) {
    return true; // IPv6 literal
  }
  final parts = host.split('.');
  if (parts.length != 4) {
    return false;
  }
  return parts.every((p) => int.tryParse(p) != null);
}

/// FNV-1a 32-bit hash, used for stable server tags.
int _fnv1a(String s) {
  var hash = 0x811c9dc5;
  for (final unit in s.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash;
}

/// Parse a list of DNS URLs into sing-box DNS server options.
///
/// Accepted forms (cf. SettingConfigItemDNS.kDNSList): `local`, bare
/// hosts/IPs (udp), and `udp://`, `tcp://`, `tls://`, `https://`,
/// `h3://`, `quic://`, `dhcp://` URLs. [detour] (an outbound tag) is
/// applied to every parsed server; [resolver], when given, is attached as
/// `domain_resolver` to servers whose address is a domain name.
/// Returns an error result on the first unparsable entry.
ReturnResult<List<SingboxDNSOptions>> SingboxDNSTryParseList(
  List<String> urls,
  String? detour,
  SingboxDNSDomainResolver? resolver,
) {
  final ret = <SingboxDNSOptions>[];
  for (final url in urls) {
    final server = _parseOne(url, detour, resolver);
    if (server == null) {
      return ReturnResult(
        error: ReturnResultError('invalid dns url: $url', report: false),
      );
    }
    ret.add(server);
  }
  return ReturnResult(data: ret);
}

SingboxDNSServerOptions? _parseOne(
  String url,
  String? detour,
  SingboxDNSDomainResolver? resolver,
) {
  final tag = 'dns-${_fnv1a(url).toRadixString(16)}';
  if (url == 'local') {
    return SingboxDNSServerOptions(tag: tag, type: 'local', detour: detour);
  }
  var effective = url;
  if (!effective.contains('://')) {
    effective = 'udp://$effective';
  }
  final uri = Uri.tryParse(effective);
  if (uri == null) {
    return null;
  }
  final type = switch (uri.scheme) {
    'udp' => 'udp',
    'tcp' => 'tcp',
    'tls' => 'tls',
    'https' => 'https',
    'h3' => 'h3',
    'quic' => 'quic',
    'dhcp' => 'dhcp',
    _ => null,
  };
  if (type == null) {
    return null;
  }
  if (type == 'dhcp') {
    return SingboxDNSServerOptions(
      tag: tag,
      type: type,
      detour: detour,
      interface: uri.host,
    );
  }
  if (uri.host.isEmpty) {
    return null;
  }
  return SingboxDNSServerOptions(
    tag: tag,
    type: type,
    server: uri.host,
    serverPort: uri.hasPort ? uri.port : 0,
    detour: detour,
    domainResolver: (resolver != null && !_isIpLiteral(uri.host))
        ? resolver
        : null,
    path: (type == 'https' || type == 'h3') &&
            uri.path.isNotEmpty &&
            uri.path != '/'
        ? uri.path
        : null,
  );
}
