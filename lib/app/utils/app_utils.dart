// Reconstructed for the Yousj Enhanced fork (2026-11-14) from call sites:
//  - getName()    — display name (tray tooltip, AppBar titles, cache subdir)
//  - getId()      — application id, compared against Android package names
//                   and the macOS bundle identifier at several call sites
//  - getGroupId() — Apple app group, matches the value baked into the
//                   Runner/karingService entitlements
//                   (group.com.nebula.karing)
//  - getBuildinVersion() — sync version string compiled into the app;
//                   main.dart requires four dot-separated parts and equality
//                   with getPackgetVersion()
//  - getPackgetVersion() — awaited; version reported by the platform
//                   package (package_info_plus), formatted to match
//  - getTermsOfServiceUrl() — opened from the about / user-agreement screens
//
// NOTE (fork rebrand): these are upstream identity values. Renaming the app
// to Yousj Enhanced changes this file together with the platform manifests
// and entitlements — it is intentionally not done inside this reconstruction.

import 'package:package_info_plus/package_info_plus.dart';

class AppUtils {
  AppUtils._();

  static String getName() {
    return 'Karing';
  }

  static String getId() {
    return 'com.nebula.karing';
  }

  static String getGroupId() {
    return 'group.com.nebula.karing';
  }

  /// Version baked into the binary at build time. [RECONSTRUCTION CHOICE:
  /// the release pipeline injects KARING_BUILD_VERSION; the default matches
  /// pubspec `version: 1.2.26+2931` in dotted-quad form.]
  static String getBuildinVersion() {
    return const String.fromEnvironment(
      'KARING_BUILD_VERSION',
      defaultValue: '1.2.26.2931',
    );
  }

  /// Version of the installed package, formatted as
  /// `<version>.<buildNumber>` to line up with [getBuildinVersion].
  static Future<String> getPackgetVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (info.buildNumber.isNotEmpty) {
        return '${info.version}.${info.buildNumber}';
      }
      return info.version;
    } catch (_) {
      return '';
    }
  }

  static String getTermsOfServiceUrl() {
    return 'https://karing.app/terms';
  }
}
