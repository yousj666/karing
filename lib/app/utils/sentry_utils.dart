// Reconstructed for the Yousj Enhanced fork (2026-11-14) from call sites:
//  - captureException(tag, args, exception, stackTrace) — main.dart's
//    top-level error trap and dialog_utils' exception dialog; fire and
//    forget, never throws.
//  - getOvserver() (upstream spelling) — the Sentry NavigatorObserver
//    registered in my_app.dart.
//  - feedback(text) — feedback_screen submit. [RECONSTRUCTION CHOICE:
//    sent as a tagged Sentry message; the hosted user-feedback widget
//    flow can replace this without touching call sites.]

import 'package:flutter/widgets.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

class SentryUtils {
  SentryUtils._();

  static Future<void> captureException(
    String tag,
    List<dynamic> args,
    Object exception,
    StackTrace? stackTrace,
  ) async {
    try {
      await Sentry.captureException(
        exception,
        stackTrace: stackTrace,
        withScope: (scope) {
          scope.setTag('karing.scope', tag);
          if (args.isNotEmpty) {
            scope.setContexts('args', {'value': args.toString()});
          }
        },
      );
    } catch (_) {}
  }

  static NavigatorObserver getOvserver() {
    return SentryNavigatorObserver();
  }

  static Future<void> feedback(String text) async {
    try {
      await Sentry.captureMessage(
        text,
        level: SentryLevel.info,
        withScope: (scope) {
          scope.setTag('karing.scope', 'feedback');
        },
      );
    } catch (_) {}
  }
}
