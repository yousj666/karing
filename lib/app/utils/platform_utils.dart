// Reconstructed for the Yousj Enhanced fork (2026-11-14) from call sites:
// `PlatformUtils.isPC()` / `isMobile()` are bool-returning methods (62 call
// sites), and `android`/`ios`/`windows`/`macos`/`linux` are string constants
// compared against `dart:io`'s `Platform.operatingSystem`
// (home_screen_widgets.dart: `[PlatformUtils.android].contains(
// Platform.operatingSystem)`), so they carry exactly the dart:io values.

import 'dart:io';

class PlatformUtils {
  PlatformUtils._();

  static const String android = 'android';
  static const String ios = 'ios';
  static const String windows = 'windows';
  static const String macos = 'macos';
  static const String linux = 'linux';
  static const String fuchsia = 'fuchsia';

  /// Desktop platforms (windows / macos / linux).
  static bool isPC() {
    return Platform.isWindows || Platform.isMacOS || Platform.isLinux;
  }

  /// Handheld platforms (android / ios).
  static bool isMobile() {
    return Platform.isAndroid || Platform.isIOS;
  }
}
