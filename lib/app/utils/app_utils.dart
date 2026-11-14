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
// NOTE (fork rebrand): this fork ships as "Yousj Enhanced" with application
// id cc.yousj.enhanced (platform manifests changed in the same step), so it
// installs side by side with the original app. The Apple app-group id below
// still uses the upstream group; Apple targets are not built yet.

import 'package:package_info_plus/package_info_plus.dart';

class AppUtils {
  AppUtils._();

  static String getName() {
    return 'Yousj Enhanced';
  }

  static String getId() {
    return 'cc.yousj.enhanced';
  }

  static String getGroupId() {
    return 'group.com.nebula.karing';
  }

  /// Version baked into the binary at build time. [The release pipeline
  /// injects KARING_BUILD_VERSION derived from pubspec (X.Y.Z+B -> X.Y.Z.B);
  /// the default below is only a safety net for non-CI builds and matches
  /// pubspec `version: 1.0.5+5` in dotted-quad form.]
  static String getBuildinVersion() {
    return const String.fromEnvironment(
      'KARING_BUILD_VERSION',
      defaultValue: '1.0.5.5',
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
