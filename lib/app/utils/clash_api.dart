// Reconstructed for the Yousj Enhanced fork (2026-11-14) from call sites.
//
// Client for the core's Clash-style HTTP API on 127.0.0.1:<controlPort>
// (sing-box experimental.clash_api plus Karing core extensions). Signatures
// and result shapes are pinned by the call sites:
//  - dnsQuery(port, DNSQueryRequest) -> (status, body); the caller decodes
//    the body into DNSQueryResponse (defined here; the request type lives
//    in singbox_dns.dart)
//  - dnsQueryWithDefaultRouter(port, domain, strategy) -> (status, body)
//  - getDelay(port, tag, timeoutSeconds, {targetUrl}) -> delay as String
//    (server_manager feeds it straight into updateByDelay(String, ...))
//  - getHttpRequestByProxy(port, tag, url) -> HttpRequestResponse (.body)
//  - getGroupDelayHistory(port) -> (status, body with a "history" map)
//  - outboundQuery(port, domain, ip) -> (status, body)
//  - getRemoteRulesetsCount(port) -> Map<String, int>
//  - getRemoteRulesetsStates(port) ->
//      (existing rulesets -> updated-at, fetch errors by tag)
//  - getCurrentServerForUrltest(tag, port) -> CurrentServerForUrltest
//  - getConnectionsUrl / getLogsUrl -> websocket URLs (async: the secret
//    lookup is async)
// Endpoint paths follow the clash API conventions; the Karing-extension
// endpoints (rulesets, outbound query, per-proxy request) are best-effort
// reconstructions marked [?]. The API secret is generated once per process
// here; the R3/R4 phases must wire it into the generated core config
// (experimental.clash_api.secret) so the core accepts these calls.

import 'dart:convert';
import 'dart:io';

import 'package:karing/app/runtime/return_result.dart';
import 'package:karing/app/utils/singbox_dns.dart';
import 'package:tuple/tuple.dart';
import 'package:uuid/uuid.dart';

/// Response of a proxied HTTP request performed by the core
/// (ClashApi.getHttpRequestByProxy).
class HttpRequestResponse {
  int statusCode = 0;
  String body = '';
  Map<String, String> headers = {};
}

/// Decoded body of ClashApi.dnsQuery (server_manager.testDNSConnectLatency
/// reads .err / .latency).
class DNSQueryResponse {
  String? err;
  String latency = '';
  List<dynamic> answers = [];

  void fromJson(Map<String, dynamic>? map) {
    if (map == null) {
      return;
    }
    err = (map['err'] ?? map['error'])?.toString();
    latency = (map['latency'] ?? '').toString();
    final rawAnswers = map['answers'] ?? map['Answer'];
    if (rawAnswers is List) {
      answers = rawAnswers;
    }
  }
}

class CurrentServerForUrltestHistory {
  int delay = 0;
  String error = '';

  void clear() {
    delay = 0;
    error = '';
  }

  void fromJson(dynamic value) {
    if (value is List && value.isNotEmpty) {
      final last = value.last;
      if (last is Map) {
        delay = (last['delay'] as num?)?.toInt() ?? 0;
        error = (last['error'] ?? '').toString();
      }
    } else if (value is Map) {
      delay = (value['delay'] as num?)?.toInt() ?? 0;
      error = (value['error'] ?? '').toString();
    }
  }
}

/// The urltest group's current selection + last delay measurement
/// (home_screen keeps one as UI state; ClashApi.getCurrentServerForUrltest
/// refreshes it from the core).
class CurrentServerForUrltest {
  String now = '';
  CurrentServerForUrltestHistory history = CurrentServerForUrltestHistory();

  void clear() {
    now = '';
    history.clear();
  }

  void fromJson(Map<String, dynamic>? map) {
    if (map == null) {
      return;
    }
    now = (map['now'] ?? '').toString();
    history.fromJson(map['history']);
  }
}

class ClashApi {
  ClashApi._();

  static String? _secret;

  /// The Clash API secret. [?] Generated once per process in this
  /// reconstruction; R3/R4 must persist it and inject it into the core
  /// config so app and core agree.
  static Future<String> getSecret() async {
    _secret ??= const Uuid().v4();
    return _secret!;
  }

  static Future<ReturnResult<Tuple2<int, String>>> _api(
    int port,
    String method,
    String pathAndQuery, {
    Object? jsonBody,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final client = HttpClient();
    try {
      final secret = await getSecret();
      final uri = Uri.parse('http://127.0.0.1:$port$pathAndQuery');
      final request = await client.openUrl(method, uri).timeout(timeout);
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $secret');
      if (jsonBody != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(jsonBody));
      }
      final response = await request.close().timeout(timeout);
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(timeout);
      if (response.statusCode != 200) {
        return ReturnResult<Tuple2<int, String>>(
          error: ReturnResultError(
            body.isNotEmpty ? body : 'http statusCode:${response.statusCode}',
          ),
        );
      }
      return ReturnResult<Tuple2<int, String>>(
        data: Tuple2(response.statusCode, body),
      );
    } catch (err) {
      return ReturnResult<Tuple2<int, String>>(
        error: ReturnResultError(err.toString()),
      );
    } finally {
      client.close(force: true);
    }
  }

  static Future<ReturnResult<Tuple2<int, String>>> dnsQuery(
    int port,
    DNSQueryRequest req,
  ) {
    return _api(port, 'POST', '/dns/query', jsonBody: req.toJson());
  }

  static Future<ReturnResult<Tuple2<int, String>>> dnsQueryWithDefaultRouter(
    int port,
    String domain,
    String strategy,
  ) {
    final query = Uri(queryParameters: {
      'name': domain,
      'strategy': strategy,
    }).query;
    return _api(port, 'GET', '/dns/query?$query');
  }

  /// Delay of one outbound in milliseconds, as a string (empty on error
  /// is reported through the error channel instead).
  static Future<ReturnResult<String>> getDelay(
    int port,
    String tag,
    int timeoutSeconds, {
    String? targetUrl,
  }) async {
    final query = Uri(queryParameters: {
      if (targetUrl != null) 'url': targetUrl,
      'timeout': '${timeoutSeconds * 1000}',
    }).query;
    final result = await _api(
      port,
      'GET',
      '/proxies/${Uri.encodeComponent(tag)}/delay?$query',
      timeout: Duration(seconds: timeoutSeconds + 5),
    );
    if (result.error != null) {
      return ReturnResult<String>(error: result.error);
    }
    try {
      final map = jsonDecode(result.data!.item2) as Map<String, dynamic>;
      final delay = (map['delay'] as num?)?.toInt();
      if (delay == null) {
        return ReturnResult<String>(
          error: ReturnResultError('invalid delay response'),
        );
      }
      return ReturnResult<String>(data: delay.toString());
    } catch (err) {
      return ReturnResult<String>(error: ReturnResultError(err.toString()));
    }
  }

  /// Ask the core to fetch [url] through outbound [tag] (used to resolve
  /// the outlet IP of a node). [?]
  static Future<ReturnResult<HttpRequestResponse>> getHttpRequestByProxy(
    int port,
    String tag,
    String url,
  ) async {
    final result = await _api(
      port,
      'POST',
      '/proxies/${Uri.encodeComponent(tag)}/request',
      jsonBody: {'url': url},
    );
    if (result.error != null) {
      return ReturnResult<HttpRequestResponse>(error: result.error);
    }
    final response = HttpRequestResponse();
    try {
      final map = jsonDecode(result.data!.item2) as Map<String, dynamic>;
      response.statusCode = (map['status_code'] as num?)?.toInt() ?? 200;
      response.body = (map['body'] ?? '').toString();
    } catch (_) {
      // Non-JSON extension payloads are the raw body.
      response.statusCode = result.data!.item1;
      response.body = result.data!.item2;
    }
    return ReturnResult<HttpRequestResponse>(data: response);
  }

  static Future<ReturnResult<Tuple2<int, String>>> getGroupDelayHistory(
    int port,
  ) {
    return _api(port, 'GET', '/group/history');
  }

  /// Which rule/outbound a (domain, ip) pair would take. [?]
  static Future<ReturnResult<Tuple2<int, String>>> outboundQuery(
    int port,
    String domain,
    String ip,
  ) {
    final query = Uri(queryParameters: {'domain': domain, 'ip': ip}).query;
    return _api(port, 'GET', '/rules/outbound?$query');
  }

  /// tag -> download state (0 = not downloaded) for remote rule-sets. [?]
  static Future<ReturnResult<Map<String, int>>> getRemoteRulesetsCount(
    int port,
  ) async {
    final result = await _api(port, 'GET', '/rulesets/count');
    if (result.error != null) {
      return ReturnResult<Map<String, int>>(error: result.error);
    }
    try {
      final map = jsonDecode(result.data!.item2) as Map<String, dynamic>;
      return ReturnResult<Map<String, int>>(
        data: map.map((k, v) => MapEntry(k, (v as num?)?.toInt() ?? 0)),
      );
    } catch (err) {
      return ReturnResult<Map<String, int>>(
        error: ReturnResultError(err.toString()),
      );
    }
  }

  /// (existing rulesets -> last-updated, fetch errors by tag). [?]
  static Future<ReturnResult<Tuple2<Map<String, DateTime>, Map<String, String>>>>
      getRemoteRulesetsStates(int port) async {
    final result = await _api(port, 'GET', '/rulesets');
    if (result.error != null) {
      return ReturnResult(error: result.error);
    }
    try {
      final map = jsonDecode(result.data!.item2) as Map<String, dynamic>;
      final exist = <String, DateTime>{};
      final rawExist = map['exist'];
      if (rawExist is Map) {
        rawExist.forEach((key, value) {
          final parsed = DateTime.tryParse(value.toString());
          if (parsed != null) {
            exist[key.toString()] = parsed;
          }
        });
      }
      final errors = <String, String>{};
      final rawErrors = map['errors'];
      if (rawErrors is Map) {
        rawErrors.forEach((key, value) {
          errors[key.toString()] = value.toString();
        });
      }
      return ReturnResult(data: Tuple2(exist, errors));
    } catch (err) {
      return ReturnResult(error: ReturnResultError(err.toString()));
    }
  }

  static Future<ReturnResult<CurrentServerForUrltest>>
      getCurrentServerForUrltest(String tag, int port) async {
    final result = await _api(
      port,
      'GET',
      '/proxies/${Uri.encodeComponent(tag)}',
    );
    if (result.error != null) {
      return ReturnResult<CurrentServerForUrltest>(error: result.error);
    }
    try {
      final data = CurrentServerForUrltest();
      data.fromJson(jsonDecode(result.data!.item2) as Map<String, dynamic>);
      return ReturnResult<CurrentServerForUrltest>(data: data);
    } catch (err) {
      return ReturnResult<CurrentServerForUrltest>(
        error: ReturnResultError(err.toString()),
      );
    }
  }

  /// Trigger a fresh urltest round in the core.
  static Future<ReturnResultError?> updateUrltestCheck(int port) async {
    final result = await _api(port, 'GET', '/group/urltest/check');
    return result.error;
  }

  /// Close all active connections (clash DELETE /connections).
  static Future<void> resetOutboundConnections(int port) async {
    await _api(port, 'DELETE', '/connections');
  }

  /// Reset core networking state (extension endpoint). [?]
  static Future<void> resetNetwork(int port) async {
    await _api(port, 'POST', '/network/reset');
  }

  static Future<String> getConnectionsUrl(
    int port, {
    bool noConnections = false,
  }) async {
    final secret = await getSecret();
    var url = 'ws://127.0.0.1:$port/connections?token=$secret';
    if (noConnections) {
      url += '&noConnections=true';
    }
    return url;
  }

  static Future<String> getLogsUrl(int port, String level) async {
    final secret = await getSecret();
    return 'ws://127.0.0.1:$port/logs?level=$level&token=$secret';
  }
}
