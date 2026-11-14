// Reconstructed for the Yousj Enhanced fork (upstream file missing).
//
// API pinned from call sites (home_screen.dart, home_tvos_screen.dart):
//   "${err.toString()}\n\n${StackTraceUtils.trim(stacktrace)}"
// — trims a stack trace down to a bounded number of frames for error
// dialogs and logs.

class StackTraceUtils {
  /// Maximum number of frames kept by [trim].
  static const int maxFrames = 25;

  static String trim(StackTrace stackTrace) {
    final lines = stackTrace
        .toString()
        .split('\n')
        .where((line) => line.trim().isNotEmpty)
        .toList();
    if (lines.length <= maxFrames) {
      return lines.join('\n');
    }
    return lines.take(maxFrames).join('\n');
  }
}
