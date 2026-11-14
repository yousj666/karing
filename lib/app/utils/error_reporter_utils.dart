// Reconstructed for the Yousj Enhanced fork (upstream file missing).
//
// API pinned from call sites:
//   * home_screen.dart:377 `ErrorReporterUtils.register(() {...})` and
//     home_screen.dart:2483 `ErrorReporterUtils.register(null)` — registers
//     (or clears) the callback invoked when a storage-full condition is
//     detected.
//   * `ErrorReporterUtils.tryReportNoSpace(err.toString())` — statement
//     calls in fork_screens.dart, net_connections_screen.dart and
//     diversion_group_custom_screen.dart, always after a failed file write.

class ErrorReporterUtils {
  static void Function()? _onNoSpace;

  /// Register the storage-full handler (null clears it).
  static void register(void Function()? callback) {
    _onNoSpace = callback;
  }

  /// If [error] describes a "no space left on device" failure, notify the
  /// registered handler. Other errors are ignored.
  static void tryReportNoSpace(String error) {
    final lower = error.toLowerCase();
    final isNoSpace =
        lower.contains('no space left') ||
        lower.contains('errno = 28') ||
        lower.contains('errno=28') ||
        lower.contains('os error 28');
    if (isNoSpace) {
      _onNoSpace?.call();
    }
  }
}
