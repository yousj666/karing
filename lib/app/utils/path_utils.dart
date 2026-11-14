// Reconstructed for the Yousj Enhanced fork (2026-11-14).
//
// Upstream Karing ships a partial source tree; this file was rebuilt from
// call sites in the surviving code (grep is ground truth for every member
// below). Behavioural choices that could not be observed from call sites
// (exact on-disk file names, directory layout) are documented inline and
// marked [RECONSTRUCTION CHOICE].

import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

class PathUtils {
  PathUtils._();

  static bool _isPC() =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  static String _exeDir() => path.dirname(Platform.resolvedExecutable);

  /// True when the app runs in portable mode: a `profiles` folder sitting
  /// next to the executable (see the portableModeDisableTips string in the
  /// i18n tables: "delete the folder [profiles] in the same directory as
  /// [karing.exe]").
  static bool portableMode() {
    if (!_isPC()) {
      return false;
    }
    try {
      return Directory(profileDirForPortableMode()).existsSync();
    } catch (_) {
      return false;
    }
  }

  /// `<exe dir>/profiles` — the portable-mode profile directory.
  static String profileDirForPortableMode() {
    return path.join(_exeDir(), 'profiles');
  }

  /// Root directory holding all of the app's profile/config files.
  static Future<String> profileDir() async {
    if (_isPC() && portableMode()) {
      return profileDirForPortableMode();
    }
    try {
      final dir = await getApplicationSupportDirectory();
      return dir.path;
    } catch (_) {
      return '';
    }
  }

  /// Root of the app's data files under the profile directory. Used by the
  /// settings screen's clear-data flow. [RECONSTRUCTION CHOICE: the profile
  /// directory itself.]
  static Future<String> profileDataDir() async {
    return profileDir();
  }

  /// Scratch/download directory (auto-update payloads, exports, shares).
  static Future<String> cacheDir() async {
    try {
      final dir = await getTemporaryDirectory();
      return dir.path;
    } catch (_) {
      return '';
    }
  }

  /// Directory holding the auto-backup zip archives: `<profile>/backup`.
  static Future<String> backupDir() async {
    return path.join(await profileDir(), 'backup');
  }

  /// WebView2 user-data folder on Windows: `<cache>/webview`.
  static Future<String> webviewCacheDir() async {
    return path.join(await cacheDir(), 'webview');
  }

  /// File name the app executable is expected to have (startup integrity
  /// check in main.dart compares it against the resolved executable).
  static String getExeName() {
    return Platform.isWindows ? 'karing.exe' : 'karing';
  }

  /// File name of the bundled core service executable
  /// (`bind/<platform>/core/karingService`).
  static String serviceExeName() {
    return Platform.isWindows ? 'karingService.exe' : 'karingService';
  }

  /// Absolute path of the service executable shipped next to the app.
  static String serviceExePath() {
    return path.join(_exeDir(), serviceExeName());
  }

  /// Directory containing Flutter's bundled assets (next to the exe on
  /// desktop builds).
  static String flutterAssetsDir() {
    if (Platform.isMacOS) {
      // <App>.app/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets
      return path.join(
        _exeDir(),
        '..',
        'Frameworks',
        'App.framework',
        'Versions',
        'A',
        'Resources',
        'flutter_assets',
      );
    }
    return path.join(_exeDir(), 'data', 'flutter_assets');
  }

  // ---------------------------------------------------------------------------
  // File names ([RECONSTRUCTION CHOICE] values — stable, descriptive names in
  // upstream style; the viewers/backup flows only rely on them being constant)
  // ---------------------------------------------------------------------------

  static String logFileName() => 'karing.log';
  static String serviceLogFileName() => 'service.log';
  static String serviceStdErrorFileName() => 'service_stderr.log';
  static String serviceCoreConfigFileName() => 'config.json';
  static String serviceConfigFileName() => 'service.json';
  static String subscribeFileName() => 'subscribe.json';
  static String subscribeUseFileName() => 'subscribe_use.json';
  static String diversionGroupFileName() => 'diversion_group.json';
  static String settingFileName() => 'setting.json';
  static String cloudflareWarpFileName() => 'cloudflare_warp.json';
  static String remoteConfigFileName() => 'remote_config.json';
  static String remoteISPConfigFileName() => 'remote_isp_config.json';
  static String ispNoticeFileName() => 'isp_notice.json';
  static String autoUpdateFileName() => 'auto_update.json';
  static String noticeFileName() => 'notice.json';
  static String storageFileName() => 'storage.json';
  static String statisticsDBFileName() => 'statistics.db';
  static String cacheDBFileName() => 'cache.db';

  // ---------------------------------------------------------------------------
  // Absolute file paths (profile dir + file name)
  // ---------------------------------------------------------------------------

  static Future<String> _inProfile(String fileName) async {
    return path.join(await profileDir(), fileName);
  }

  static Future<String> serviceCoreConfigFilePath() =>
      _inProfile(serviceCoreConfigFileName());
  static Future<String> serviceStdErrorFilePath() =>
      _inProfile(serviceStdErrorFileName());
  static Future<String> subscribeFilePath() => _inProfile(subscribeFileName());
  static Future<String> subscribeUseFilePath() =>
      _inProfile(subscribeUseFileName());
  static Future<String> diversionGroupFilePath() =>
      _inProfile(diversionGroupFileName());
  static Future<String> settingFilePath() => _inProfile(settingFileName());
  static Future<String> remoteConfigFilePath() =>
      _inProfile(remoteConfigFileName());
  static Future<String> remoteISPConfigFilePath() =>
      _inProfile(remoteISPConfigFileName());
  static Future<String> autoUpdateFilePath() =>
      _inProfile(autoUpdateFileName());
  static Future<String> statisticsDBFilePath() =>
      _inProfile(statisticsDBFileName());
  static Future<String> cacheDBFilePath() => _inProfile(cacheDBFileName());
  static Future<String> noticeFilePath() => _inProfile(noticeFileName());

  /// Board/provider configuration file. [RECONSTRUCTION CHOICE name.]
  static Future<String> providersConfigFilePath() =>
      _inProfile('providers.json');

  /// Provider notice file. [RECONSTRUCTION CHOICE name.]
  static Future<String> providerNoticeFilePath() =>
      _inProfile('provider_notice.json');
}
