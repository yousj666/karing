// Reconstructed for the Yousj Enhanced fork (2026-11-14) from call sites:
// validators (isIpv4/isIpv6/isDomain/isIpv4WithMask/isIpv6WithMask) are
// pure string checks used by setting_manager and the diversion editor;
// getInterfaces() feeds the LAN-sync and net-interfaces screens via the
// NetInterfacesInfo model below; getAvaliablePort* reserve local ports
// for the LAN sync server and the proxy cluster; getOutletIp resolves the
// egress IP through the local proxy port; dnsLookup and
// testConnectLatency back the net-check screen.

import 'dart:convert';
import 'dart:io';

import 'package:karing/app/runtime/return_result.dart';
import 'package:tuple/tuple.dart';

/// Egress-IP lookup result (home screen's outlet-IP card renders
/// `countryCode` as a flag emoji plus `ip`).
class OutletIpInfo {
  OutletIpInfo({this.ip = '', this.countryCode = ''});

  String ip;
  String countryCode;
}

/// One address of one network interface (flattened NetworkInterface).
class NetInterfacesInfo {
  NetInterfacesInfo({required this.name, required this.address, required this.type});

  String name;
  String address;
  InternetAddressType type;
}

class NetworkUtils {
  NetworkUtils._();

  static bool isIpv4(String value) {
    final parts = value.split('.');
    if (parts.length != 4) {
      return false;
    }
    for (final part in parts) {
      if (part.isEmpty || part.length > 3) {
        return false;
      }
      final n = int.tryParse(part);
      if (n == null || n < 0 || n > 255 || n.toString() != part) {
        return false;
      }
    }
    return true;
  }

  static bool isIpv6(String value) {
    final addr = InternetAddress.tryParse(value);
    return addr != null && addr.type == InternetAddressType.IPv6;
  }

  static bool isIpv4WithMask(String value) {
    final parts = value.split('/');
    if (parts.length != 2) {
      return false;
    }
    final prefix = int.tryParse(parts[1]);
    return isIpv4(parts[0]) && prefix != null && prefix >= 0 && prefix <= 32;
  }

  static bool isIpv6WithMask(String value) {
    final parts = value.split('/');
    if (parts.length != 2) {
      return false;
    }
    final prefix = int.tryParse(parts[1]);
    return isIpv6(parts[0]) && prefix != null && prefix >= 0 && prefix <= 128;
  }

  static final RegExp _domainLabel = RegExp(r'^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$');

  /// Domain-name check. The second positional argument at the call sites is
  /// always `false`; it is accepted (and currently only relaxes the TLD
  /// requirement when true) for signature compatibility. [?]
  static bool isDomain(String value, [bool allowNoTld = false]) {
    var v = value.trim();
    if (v.isEmpty || v.length > 253) {
      return false;
    }
    if (isIpv4(v) || isIpv6(v)) {
      return false;
    }
    final labels = v.split('.');
    if (labels.length < 2 && !allowNoTld) {
      return false;
    }
    for (final label in labels) {
      if (label.isEmpty || label.length > 63 || !_domainLabel.hasMatch(label)) {
        return false;
      }
    }
    return true;
  }

  /// Extract the bare domain/host from user input that may carry a scheme,
  /// port, path or trailing dot. Null when nothing host-like remains.
  static String? getRealDomain(String value) {
    var v = value.trim();
    if (v.isEmpty) {
      return null;
    }
    if (v.contains('://')) {
      final uri = Uri.tryParse(v);
      if (uri == null || uri.host.isEmpty) {
        return null;
      }
      v = uri.host;
    } else {
      v = v.split('/').first;
      // strip :port (but keep bracketed IPv6 intact)
      if (!v.startsWith('[')) {
        final colon = v.lastIndexOf(':');
        if (colon > 0 && int.tryParse(v.substring(colon + 1)) != null) {
          v = v.substring(0, colon);
        }
      } else {
        final end = v.indexOf(']');
        if (end > 0) {
          v = v.substring(1, end);
        }
      }
    }
    if (v.endsWith('.')) {
      v = v.substring(0, v.length - 1);
    }
    return v.isEmpty ? null : v;
  }

  /// All interface addresses, non-loopback first. [filter]=true hides
  /// loopback/link-local noise (the net-interfaces screen's non-dev
  /// mode); [addressType] restricts to one address family.
  static Future<List<NetInterfacesInfo>> getInterfaces({
    bool filter = false,
    InternetAddressType? addressType,
  }) async {
    final result = <NetInterfacesInfo>[];
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: true,
        includeLinkLocal: true,
        type: addressType ?? InternetAddressType.any,
      );
      final loopback = <NetInterfacesInfo>[];
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          final info = NetInterfacesInfo(
            name: iface.name,
            address: addr.address,
            type: addr.type,
          );
          if (addr.isLoopback) {
            loopback.add(info);
          } else {
            result.add(info);
          }
        }
      }
      if (!filter) {
        result.addAll(loopback);
      }
    } catch (_) {}
    return result;
  }

  /// First candidate port that can be bound (the probe socket is closed
  /// before returning). 0 when none of the candidates is free.
  static Future<int> getAvaliablePort(List<int> ports) async {
    for (final port in ports) {
      if (port <= 0) {
        continue;
      }
      ServerSocket? socket;
      try {
        socket = await ServerSocket.bind(InternetAddress.anyIPv4, port);
        await socket.close();
        return port;
      } catch (_) {
        try {
          await socket?.close();
        } catch (_) {}
      }
    }
    return 0;
  }

  /// Like [getAvaliablePort] but the winning socket stays open and is added
  /// to [sockets], reserving the port for the caller (proxy cluster).
  static Future<int> getAvaliablePortNotCloseSocket(
    List<int> ports,
    List<ServerSocket> sockets,
  ) async {
    for (final port in ports) {
      if (port <= 0) {
        continue;
      }
      try {
        final socket = await ServerSocket.bind(InternetAddress.anyIPv4, port);
        sockets.add(socket);
        return port;
      } catch (_) {}
    }
    return 0;
  }

  /// Resolve [host] and return its addresses as strings, honouring the
  /// IPv6-preference flag (net-check screen).
  static Future<List<String>> dnsLookup(String host, bool preferIpv6) async {
    try {
      final addresses = await InternetAddress.lookup(host);
      final sorted = List<InternetAddress>.from(addresses);
      sorted.sort((a, b) {
        final av = a.type == InternetAddressType.IPv6 ? 0 : 1;
        final bv = b.type == InternetAddressType.IPv6 ? 0 : 1;
        return preferIpv6 ? av.compareTo(bv) : bv.compareTo(av);
      });
      return sorted.map((a) => a.address).toList();
    } catch (_) {
      return [];
    }
  }

  /// TCP connect latency probe (net-check screen): milliseconds to connect.
  static Future<ReturnResult<int>> testConnectLatency(
    String host,
    int port,
    Duration timeout,
  ) async {
    final watch = Stopwatch()..start();
    Socket? socket;
    try {
      socket = await Socket.connect(host, port, timeout: timeout);
      watch.stop();
      return ReturnResult<int>(data: watch.elapsedMilliseconds);
    } catch (err) {
      return ReturnResult<int>(error: ReturnResultError(err.toString()));
    } finally {
      try {
        await socket?.close();
      } catch (_) {}
    }
  }

  /// Egress IP (with geo info) as seen through the local proxy [port]:
  /// queries an IP-echo service via the proxy. The tuple's second item
  /// carries the raw response/error text. [I]
  static Future<Tuple2<OutletIpInfo?, String?>> getOutletIp(int port) async {
    HttpClient? client;
    try {
      client = HttpClient();
      client.findProxy = (uri) => 'PROXY 127.0.0.1:$port';
      client.connectionTimeout = const Duration(seconds: 5);
      final request = await client.getUrl(Uri.parse('https://ipinfo.io/json'));
      final response = await request.close();
      final body = await response.transform(const Utf8Decoder()).join();
      if (response.statusCode != 200) {
        return Tuple2(null, 'http ${response.statusCode}');
      }
      final map = jsonDecode(body) as Map<String, dynamic>;
      final info = OutletIpInfo(
        ip: (map['ip'] ?? '').toString(),
        countryCode: (map['country'] ?? '').toString(),
      );
      return Tuple2(info, body);
    } catch (err) {
      return Tuple2(null, err.toString());
    } finally {
      client?.close(force: true);
    }
  }
}
