// Reconstructed for the Yousj Enhanced fork (2026-11-14) from call sites.
//
// Request helpers are built on dart:io HttpClient and route through the
// app's local proxy ports (mixed rule/direct ports) when a port is given:
//  - httpGetRequest(url, proxyPort, userAgent, timeout, headers, xhwid,
//      {checkStatuscode, noResponseBody}) -> (statusCode, body)
//    Positional args 5/6 are null at every surviving call site; they are
//    typed as extra headers / x-hwid by analogy with httpHeadRequest. [?]
//  - httpPostRequest(url, proxyPort, headers, body, timeout, userAgent,
//      xhwid, followRedirects, {checkStatuscode}) -> (statusCode, body)
//    Trailing args are likewise null at every call site. [?]
//  - httpHeadRequest(Uri, proxyPort, userAgent, xhwid, timeout)
//      -> (statusCode, HttpHeaders)   (server_manager.reloadTraffic)
//  - httpDownload(Uri, savePath, proxyPort, userAgent, resume, timeout)
//      -> HttpHeaders                (LAN sync / backup download)
//  - httpUpload(Uri, filePath, proxyPort, userAgent) -> error?
//  - httpGetTitle(url, userAgent) -> page <title>
// The getUserAgents* family manages the "compatible UA" catalogue: full
// client UA strings the user can attach to subscription fetches so that
// UA-gated providers accept them (group_helper.showUserAgent dialog).

import 'dart:convert';
import 'dart:io';

import 'package:karing/app/runtime/return_result.dart';
import 'package:karing/app/utils/app_utils.dart';
import 'package:path/path.dart' as path;
import 'package:tuple/tuple.dart';

class HttpUtils {
  HttpUtils._();

  static HttpClient _newClient(int? proxyPort) {
    final client = HttpClient();
    if (proxyPort != null && proxyPort > 0) {
      client.findProxy = (uri) => 'PROXY 127.0.0.1:$proxyPort';
    }
    return client;
  }

  static void _applyHeaders(
    HttpClientRequest request,
    String? userAgent,
    Map<String, String>? headers,
    String? xhwid,
  ) {
    if (userAgent != null && userAgent.isNotEmpty) {
      request.headers.set(HttpHeaders.userAgentHeader, userAgent);
    }
    if (headers != null) {
      headers.forEach((key, value) {
        request.headers.set(key, value);
      });
    }
    if (xhwid != null && xhwid.isNotEmpty) {
      request.headers.set('x-hwid', xhwid);
    }
  }

  static Future<ReturnResult<Tuple2<int, String>>> _request(
    String method,
    String url,
    int? proxyPort,
    String? userAgent,
    Map<String, String>? headers,
    String? xhwid,
    String? body,
    Duration? timeout, {
    bool checkStatuscode = true,
    bool noResponseBody = false,
    bool followRedirects = true,
  }) async {
    Future<ReturnResult<Tuple2<int, String>>> run() async {
      final client = _newClient(proxyPort);
      try {
        final uri = Uri.parse(url);
        final request = method == 'POST'
            ? await client.postUrl(uri)
            : await client.getUrl(uri);
        request.followRedirects = followRedirects;
        _applyHeaders(request, userAgent, headers, xhwid);
        if (body != null) {
          request.write(body);
        }
        final response = await request.close();
        var text = '';
        if (noResponseBody) {
          await response.drain<void>().catchError((_) {});
        } else {
          text = await response.transform(utf8.decoder).join();
        }
        if (checkStatuscode && response.statusCode != 200) {
          return ReturnResult<Tuple2<int, String>>(
            error: ReturnResultError('http statusCode:${response.statusCode}'),
          );
        }
        return ReturnResult<Tuple2<int, String>>(
          data: Tuple2(response.statusCode, text),
        );
      } catch (err) {
        return ReturnResult<Tuple2<int, String>>(
          error: ReturnResultError(err.toString()),
        );
      } finally {
        client.close(force: true);
      }
    }

    if (timeout == null) {
      return run();
    }
    return run().timeout(
      timeout,
      onTimeout: () => ReturnResult<Tuple2<int, String>>(
        error: ReturnResultError('http timeout'),
      ),
    );
  }

  static Future<ReturnResult<Tuple2<int, String>>> httpGetRequest(
    String url,
    int? proxyPort,
    String? userAgent,
    Duration? timeout,
    Map<String, String>? headers,
    String? xhwid, {
    bool checkStatuscode = true,
    bool noResponseBody = false,
  }) {
    return _request(
      'GET',
      url,
      proxyPort,
      userAgent,
      headers,
      xhwid,
      null,
      timeout,
      checkStatuscode: checkStatuscode,
      noResponseBody: noResponseBody,
    );
  }

  static Future<ReturnResult<Tuple2<int, String>>> httpPostRequest(
    String url,
    int? proxyPort,
    Map<String, String>? headers,
    String body,
    Duration? timeout,
    String? userAgent,
    String? xhwid,
    bool? followRedirects, {
    bool checkStatuscode = true,
  }) {
    return _request(
      'POST',
      url,
      proxyPort,
      userAgent,
      headers,
      xhwid,
      body,
      timeout,
      checkStatuscode: checkStatuscode,
      followRedirects: followRedirects ?? true,
    );
  }

  static Future<ReturnResult<Tuple2<int, HttpHeaders>>> httpHeadRequest(
    Uri url,
    int? proxyPort,
    String? userAgent,
    bool? xhwid,
    Duration? timeout,
  ) async {
    Future<ReturnResult<Tuple2<int, HttpHeaders>>> run() async {
      final client = _newClient(proxyPort);
      try {
        final request = await client.headUrl(url);
        _applyHeaders(request, userAgent, null, xhwid);
        final response = await request.close();
        await response.drain<void>().catchError((_) {});
        return ReturnResult<Tuple2<int, HttpHeaders>>(
          data: Tuple2(response.statusCode, response.headers),
        );
      } catch (err) {
        return ReturnResult<Tuple2<int, HttpHeaders>>(
          error: ReturnResultError(err.toString()),
        );
      } finally {
        client.close(force: true);
      }
    }

    if (timeout == null) {
      return run();
    }
    return run().timeout(
      timeout,
      onTimeout: () => ReturnResult<Tuple2<int, HttpHeaders>>(
        error: ReturnResultError('http timeout'),
      ),
    );
  }

  /// Download [url] into [savePath]; returns the response headers so the
  /// caller can read e.g. content-disposition. [resume] appends to an
  /// existing partial file via a Range request when possible.
  static Future<ReturnResult<HttpHeaders>> httpDownload(
    Uri url,
    String savePath,
    int? proxyPort,
    String? userAgent,
    bool resume,
    Duration? timeout,
  ) async {
    Future<ReturnResult<HttpHeaders>> run() async {
      final client = _newClient(proxyPort);
      IOSink? sink;
      try {
        final request = await client.getUrl(url);
        _applyHeaders(request, userAgent, null, null);
        var append = false;
        if (resume) {
          final existing = File(savePath);
          if (await existing.exists()) {
            final length = await existing.length();
            if (length > 0) {
              request.headers.set(HttpHeaders.rangeHeader, 'bytes=$length-');
              append = true;
            }
          }
        }
        final response = await request.close();
        if (response.statusCode != 200 && response.statusCode != 206) {
          await response.drain<void>().catchError((_) {});
          return ReturnResult<HttpHeaders>(
            error: ReturnResultError('http statusCode:${response.statusCode}'),
          );
        }
        if (append && response.statusCode != 206) {
          append = false;
        }
        sink = File(savePath).openWrite(
          mode: append ? FileMode.append : FileMode.write,
        );
        await response.pipe(sink);
        await sink.flush();
        return ReturnResult<HttpHeaders>(data: response.headers);
      } catch (err) {
        return ReturnResult<HttpHeaders>(
          error: ReturnResultError(err.toString()),
        );
      } finally {
        try {
          await sink?.close();
        } catch (_) {}
        client.close(force: true);
      }
    }

    if (timeout == null) {
      return run();
    }
    return run().timeout(
      timeout,
      onTimeout: () => ReturnResult<HttpHeaders>(
        error: ReturnResultError('http timeout'),
      ),
    );
  }

  /// Upload a file as multipart/form-data (LAN sync peer transfer).
  static Future<ReturnResultError?> httpUpload(
    Uri url,
    String filePath,
    int? proxyPort,
    String? userAgent,
  ) async {
    final client = _newClient(proxyPort);
    try {
      final file = File(filePath);
      if (!await file.exists()) {
        return ReturnResultError('file not exist: $filePath');
      }
      const boundary = '----karing-upload-boundary';
      final request = await client.postUrl(url);
      _applyHeaders(request, userAgent, null, null);
      request.headers.contentType = ContentType(
        'multipart',
        'form-data',
        parameters: {'boundary': boundary},
      );
      request.write(
        '--$boundary\r\n'
        'Content-Disposition: form-data; name="file"; filename="${path.basename(filePath)}"\r\n'
        'Content-Type: application/octet-stream\r\n\r\n',
      );
      await request.addStream(file.openRead());
      request.write('\r\n--$boundary--\r\n');
      final response = await request.close();
      await response.drain<void>().catchError((_) {});
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return null;
      }
      return ReturnResultError('http statusCode:${response.statusCode}');
    } catch (err) {
      return ReturnResultError(err.toString());
    } finally {
      client.close(force: true);
    }
  }

  /// Fetch a page and extract its <title> (used to auto-name profiles).
  static Future<ReturnResult<String>> httpGetTitle(
    String url,
    String? userAgent,
  ) async {
    final result = await httpGetRequest(
      url,
      null,
      userAgent,
      const Duration(seconds: 10),
      null,
      null,
    );
    if (result.error != null) {
      return ReturnResult<String>(error: result.error);
    }
    final match = RegExp(
      r'<title[^>]*>(.*?)</title>',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(result.data!.item2);
    if (match == null) {
      return ReturnResult<String>(error: ReturnResultError('no title'));
    }
    var title = match.group(1)!.trim();
    title = title
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'");
    return ReturnResult<String>(data: title);
  }

  // ---------------------------------------------------------------------------
  // Compatible user agents
  // ---------------------------------------------------------------------------

  /// The catalogue of client UA strings offered in the UI. Selecting some
  /// of them makes UA-gated subscription endpoints accept the fetch.
  /// [RECONSTRUCTION CHOICE: representative client UA strings; the rest of
  /// the app treats them as opaque tokens.]
  static List<String> getUserAgents() {
    return [
      'ClashMetaForAndroid/2.11.3.Meta',
      'clash-verge/v2.1.0',
      'sing-box/1.12.0',
      'v2rayNG/1.9.5',
      'Shadowrocket/2.2.60',
      'Quantumult X/1.5.3',
      'Surge/5.10.0',
      'Stash/2.7.0',
      'NekoBoxForAndroid/1.3.1',
      'HiddifyNext/1.1.0',
    ];
  }

  /// String form of a compatible-UA selection (what gets appended to the
  /// app's own UA / stored back onto the profile).
  static String getUserAgentsByUaString(List<String> userAgents) {
    return userAgents.join(';');
  }

  /// Compact display form of a selection (settings rows).
  static String getUserAgentsByUaStringShort(List<String> userAgents) {
    return userAgents.join(', ');
  }

  /// Normalise a stored selection against the catalogue (catalogue order).
  /// When [includeCustom] is true, entries outside the catalogue are kept
  /// (appended at the end). [I]
  static List<String> getUserAgentsByUa(
    List<String> userAgents,
    bool includeCustom,
  ) {
    final catalog = getUserAgents();
    final result = <String>[];
    for (final ua in catalog) {
      if (userAgents.contains(ua)) {
        result.add(ua);
      }
    }
    if (includeCustom) {
      for (final ua in userAgents) {
        if (!result.contains(ua)) {
          result.add(ua);
        }
      }
    }
    return result;
  }

  /// Label/token for the "append UA" toggle in the UA dialog.
  static String getUserAgentAppend() {
    return 'append';
  }

  /// The app's own request UA, optionally with a compatible-UA string
  /// appended (see getUserAgentsByUaString).
  static Future<String> getUserAgent({String? compatible}) async {
    final base = '${AppUtils.getName()}/${AppUtils.getBuildinVersion()}';
    if (compatible == null || compatible.isEmpty) {
      return base;
    }
    return '$base $compatible';
  }
}
