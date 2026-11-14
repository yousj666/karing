// Reconstructed for the Yousj Enhanced fork (upstream file missing).
//
// API pinned from call sites:
//   * my_app.dart:95: launch arguments are scanned for
//     `element == AppArgs.launchStartup` to detect a login/startup
//     launch (the app is registered for autostart with this flag).

class AppArgs {
  /// Argument passed when the app is started by the OS login items /
  /// autostart registration.
  static const String launchStartup = '--launch-startup';
}
