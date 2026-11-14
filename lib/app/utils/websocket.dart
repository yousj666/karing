// Reconstructed for the Yousj Enhanced fork (upstream file missing).
//
// API pinned from call sites (net_check_screen.dart,
// net_connections_screen.dart, home_tvos_screen.dart):
//   Websocket(
//     url: <String>,                       // ws:// or wss:// URL
//     userAgent: await HttpUtils.getUserAgent(),
//     proxy: "PROXY 127.0.0.1:<port>" | null,   // optional HTTP proxy
//     onMessage: (String message) {...},
//     onDone: () {...},
//     onError: (err) {...},
//   )
//   await ws.connect(); await ws.disconnect();

import 'dart:async';
import 'dart:io';

class Websocket {
  Websocket({
    required this.url,
    this.userAgent,
    this.proxy,
    this.onMessage,
    this.onDone,
    this.onError,
  });

  final String url;
  final String? userAgent;

  /// Proxy directive in curl form, e.g. "PROXY 127.0.0.1:7890" or "DIRECT".
  final String? proxy;
  final void Function(String message)? onMessage;
  final void Function()? onDone;
  final void Function(dynamic error)? onError;

  WebSocket? _socket;
  StreamSubscription<dynamic>? _subscription;
  bool _closedByUser = false;

  Future<void> connect() async {
    _closedByUser = false;
    HttpClient? httpClient;
    if (proxy != null && proxy!.isNotEmpty) {
      final directive = proxy!;
      httpClient = HttpClient()..findProxy = (_) => directive;
    }
    final socket = await WebSocket.connect(
      url,
      headers: userAgent != null ? {'User-Agent': userAgent} : null,
      compression: CompressionOptions.compressionDefault,
      customClient: httpClient,
    );
    _socket = socket;
    _subscription = socket.listen(
      (dynamic data) {
        if (data is String) {
          onMessage?.call(data);
        } else if (data is List<int>) {
          onMessage?.call(String.fromCharCodes(data));
        }
      },
      onDone: () {
        if (!_closedByUser) {
          onDone?.call();
        }
      },
      onError: (dynamic err) {
        onError?.call(err);
      },
    );
  }

  Future<void> disconnect() async {
    _closedByUser = true;
    await _subscription?.cancel();
    _subscription = null;
    try {
      await _socket?.close();
    } catch (_) {}
    _socket = null;
  }
}
