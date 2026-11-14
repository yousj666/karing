// Reconstructed for the Yousj Enhanced fork (2026-11-14) from call sites:
//  - getString() -> Future<String> (auto_update_manager, remote_config,
//    about_screen): the install-channel string for this install — the
//    store referrer on Android/iOS via flutter_install_referrer, falling
//    back to the build channel elsewhere / on failure.
//  - getBuildChannelName() -> String (sync): the channel baked in at
//    build time [RECONSTRUCTION CHOICE: KARING_CHANNEL env, default
//    'official'].

import 'dart:io';

import 'package:flutter_install_referrer/flutter_install_referrer.dart';

class InstallReferrerUtils {
  InstallReferrerUtils._();

  static String getBuildChannelName() {
    return const String.fromEnvironment(
      'KARING_CHANNEL',
      defaultValue: 'official',
    );
  }

  static Future<String> getString() async {
    try {
      if (Platform.isAndroid || Platform.isIOS) {
        final app = await InstallReferrer.referrer;
        return app.referrer.name;
      }
    } catch (_) {}
    return getBuildChannelName();
  }
}
