// Reconstructed for the Yousj Enhanced fork (2026-11-14) from call sites:
//  - loadUrl(url, {mode}) -> Future<ReturnResultError?> — external opening
//    via url_launcher (webview_helper expects an error-or-null result)
//  - reorganizationUrlWithAnchor(url, {anchor}) -> Future<String> — FAQ /
//    help deep links: rewrites the URL fragment to the given anchor
//    (common_dialog passes an error-string hash so the FAQ page lands on
//    the matching section)
//  - reorganizationUrl(url, param) -> String? — merges a query parameter
//    ("_from_=karing") into a provider site URL (my_profiles_screen)
//  - closeWebview() — dismisses the shared in-app webview (scheme_handler)

import 'package:karing/app/runtime/return_result.dart';
import 'package:url_launcher/url_launcher.dart';

class UrlLauncherUtils {
  UrlLauncherUtils._();

  /// Registered by the in-app webview layer so [closeWebview] can dismiss
  /// it; null until then.
  static void Function()? webviewCloseHandler;

  static Future<ReturnResultError?> loadUrl(
    String url, {
    LaunchMode mode = LaunchMode.platformDefault,
  }) async {
    try {
      final uri = Uri.tryParse(url);
      if (uri == null) {
        return ReturnResultError('invalid url: $url');
      }
      final ok = await launchUrl(uri, mode: mode);
      if (!ok) {
        return ReturnResultError('could not launch: $url');
      }
      return null;
    } catch (err) {
      return ReturnResultError(err.toString());
    }
  }

  static Future<String> reorganizationUrlWithAnchor(
    String url, {
    String? anchor,
  }) async {
    var result = url.trim();
    if (!result.contains('://') && result.contains('.')) {
      result = 'https://$result';
    }
    if (anchor != null) {
      final uri = Uri.tryParse(result);
      if (uri != null) {
        result = uri.replace(fragment: anchor).toString();
      }
    }
    return result;
  }

  static String? reorganizationUrl(String url, String param) {
    try {
      final uri = Uri.tryParse(url.trim());
      if (uri == null || uri.host.isEmpty) {
        return null;
      }
      final params = Map<String, String>.from(uri.queryParameters);
      final eq = param.indexOf('=');
      if (eq > 0) {
        params[param.substring(0, eq)] = param.substring(eq + 1);
      } else if (param.isNotEmpty) {
        params[param] = '';
      }
      return uri.replace(queryParameters: params).toString();
    } catch (_) {
      return null;
    }
  }

  static void closeWebview() {
    try {
      webviewCloseHandler?.call();
    } catch (_) {}
  }
}
