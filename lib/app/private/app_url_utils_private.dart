// Reconstructed for the Yousj Enhanced fork (upstream file missing —
// upstream keeps these backend endpoints in a private file by design).
//
// API pinned from call sites (board_provider_manager.dart,
// board_provider_notice_manager.dart):
//   final urlAndbody = BoardProviderPrivate.getBycodeUrlAndBody(
//       app: ..., version: ..., did: ..., code: name);
//   final urlAndbody = BoardProviderPrivate.getNotifyIntegrationUrlAndBody(
//       app: ..., version: ..., did: ..., url: "https://$domain", type: type);
//   final urlAndbody = BoardProviderPrivate.getNoticePushUrlAndBody(
//       app: ..., version: ..., did: ..., pid: providerId);
//   httpPostRequest(urlAndbody.item1, ..., urlAndbody.item3 /* body */)
//   — and on error, when urlAndbody.item2 is non-empty, the request is
//   retried against item2: Tuple3 = (primary URL, fallback URL, body).
//
// The endpoint paths below are this fork's reconstruction on the app's
// public dot-host; the request bodies carry exactly the fields the call
// sites pass in.

import 'dart:convert';

import 'package:tuple/tuple.dart';

class BoardProviderPrivate {
  static const String _base = 'https://dot.karing.app';

  static Tuple3<String, String, String> _make(
    String path,
    Map<String, dynamic> fields,
  ) {
    return Tuple3('$_base$path', '', jsonEncode(fields));
  }

  /// Exchange a provider code for the provider's board configuration.
  static Tuple3<String, String, String> getBycodeUrlAndBody({
    required String app,
    required String version,
    required String did,
    required String code,
  }) {
    return _make('/board/bycode', {
      'app': app,
      'version': version,
      'did': did,
      'code': code,
    });
  }

  /// Register a notification-integration endpoint for a provider domain.
  static Tuple3<String, String, String> getNotifyIntegrationUrlAndBody({
    required String app,
    required String version,
    required String did,
    required String url,
    required String type,
  }) {
    return _make('/board/notify_integration', {
      'app': app,
      'version': version,
      'did': did,
      'url': url,
      'type': type,
    });
  }

  /// Fetch the push-notice channel for one provider.
  static Tuple3<String, String, String> getNoticePushUrlAndBody({
    required String app,
    required String version,
    required String did,
    required String pid,
  }) {
    return _make('/board/notice_push', {
      'app': app,
      'version': version,
      'did': did,
      'pid': pid,
    });
  }
}
