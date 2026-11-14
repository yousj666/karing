// Reconstructed for the Yousj Enhanced fork (upstream file missing).
//
// API pinned from call sites (my_app.dart, home_screen.dart):
//   MoveToBackgroundUtils.moveToBackground();
//   MoveToBackgroundUtils.moveToBackground(
//       duration: const Duration(milliseconds: 300));
// Statement calls after quick-action connect/disconnect: the app asks the
// platform to move the task to the background once the shortcut action
// completes.

import 'package:flutter/services.dart';

class MoveToBackgroundUtils {
  static const MethodChannel _channel = MethodChannel(
    'karing/move_to_background',
  );

  /// Ask the platform to background the app, optionally after [duration].
  /// Failures (desktop platforms, missing handler) are ignored: the call
  /// is a UX nicety after shortcut actions, never essential.
  static Future<void> moveToBackground({Duration? duration}) async {
    if (duration != null && duration > Duration.zero) {
      await Future.delayed(duration);
    }
    try {
      await _channel.invokeMethod('moveToBackground');
    } catch (_) {
      // No platform handler (e.g. desktop): nothing to do.
    }
  }
}
