// Reconstructed for the Yousj Enhanced fork (upstream file missing).
//
// API pinned from call sites:
//   * main.dart:336, setting_screen.dart:1742, tv_mode_screen.dart:34:
//     `bool x = await DeviceUtils.disableOrientation()` — true on phones,
//     where main.dart then locks the app to portrait via
//     SystemChrome.setPreferredOrientations.

import 'dart:io';
import 'dart:ui' as ui;

class DeviceUtils {
  /// Whether the current device should have orientation changes disabled
  /// (phones: logical shortest side < 600dp). Tablets and desktop/TV
  /// form factors return false.
  static Future<bool> disableOrientation() async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      return false;
    }
    final views = ui.PlatformDispatcher.instance.views;
    if (views.isEmpty) {
      return false;
    }
    final view = views.first;
    final ratio = view.devicePixelRatio;
    if (ratio <= 0) {
      return false;
    }
    final logical = view.physicalSize / ratio;
    final shortest = logical.width < logical.height
        ? logical.width
        : logical.height;
    return shortest < 600;
  }
}
