// Reconstructed for the Yousj Enhanced fork (upstream file missing).
//
// API pinned from call sites:
//   * common_dialog.dart:68: when the core fails with a bbolt error on
//     Windows, the suggested remedy path calls
//     `WindowsTunFixUtils.removeDriver()` — removes the installed Wintun
//     driver package so the next start installs a clean one.

import 'dart:io';

class WindowsTunFixUtils {
  /// Delete Wintun driver packages (oem*.inf published by the Wintun
  /// provider) via pnputil. No-op off Windows or without matches.
  static Future<void> removeDriver() async {
    if (!Platform.isWindows) {
      return;
    }
    try {
      final result = await Process.run('pnputil', ['/enum-drivers']);
      if (result.exitCode != 0) {
        return;
      }
      final output = result.stdout as String;
      // pnputil output is stanza-based: "Published Name: oem42.inf"
      // followed by provider/class lines. Collect oem names whose
      // stanza mentions Wintun.
      final stanzas = output.split(RegExp(r'\r?\n\r?\n'));
      for (final stanza in stanzas) {
        if (!stanza.toLowerCase().contains('wintun')) {
          continue;
        }
        final match = RegExp(
          r'(oem\d+\.inf)',
          caseSensitive: false,
        ).firstMatch(stanza);
        if (match != null) {
          await Process.run('pnputil', [
            '/delete-driver',
            match.group(1)!,
            '/uninstall',
            '/force',
          ]);
        }
      }
    } catch (_) {}
  }
}
