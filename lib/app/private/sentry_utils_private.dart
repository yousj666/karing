// Reconstructed for the Yousj Enhanced fork (upstream file missing —
// upstream keeps the Sentry DSN in a private file by design).
//
// API pinned from call sites:
//   * main.dart:53: `await SentryUtilsPrivate.init(SettingConfig.kMaxDays.inDays)`
//     — runs before the app starts when the user has not disabled
//     app-improvement data.
//
// This fork ships without the upstream DSN: with no DSN configured,
// init() is a no-op and Sentry calls elsewhere (sentry_utils.dart)
// quietly do nothing. Supply a DSN at build time with
// --dart-define=KARING_SENTRY_DSN=<dsn> to enable reporting.

import 'package:sentry_flutter/sentry_flutter.dart';

class SentryUtilsPrivate {
  static const String _dsn = String.fromEnvironment(
    'KARING_SENTRY_DSN',
    defaultValue: '',
  );

  static Future<void> init(int maxDays) async {
    if (_dsn.isEmpty) {
      return;
    }
    await SentryFlutter.init((options) {
      options.dsn = _dsn;
      options.sendDefaultPii = false;
    });
  }
}
