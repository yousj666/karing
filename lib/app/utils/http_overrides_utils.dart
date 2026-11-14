// Reconstructed for the Yousj Enhanced fork (upstream file missing).
//
// API pinned from call sites:
//   * main.dart:44: `HttpOverridesUtils.install()` — called before
//     anything else so every dart:io HttpClient in the app shares one
//     behavior. The reconstruction keeps stock dart:io behavior (the
//     hook exists so the fork has a single place to adjust client
//     creation for the TUN environment).

import 'dart:io';

class _AppHttpOverrides extends HttpOverrides {}

class HttpOverridesUtils {
  static void install() {
    HttpOverrides.global = _AppHttpOverrides();
  }
}
