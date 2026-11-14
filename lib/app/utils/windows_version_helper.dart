// Reconstructed for the Yousj Enhanced fork (2026-11-14) from call sites:
// singleton (windows_version_helper.dart upstream) exposing
//  - majorVersion: int — main.dart warns when 0 < major < 10
//  - isWindows10RS5OrGreater: bool — gates UI that needs Windows 10
//    version 1809 (RS5, build 17763) or newer
// Values are parsed from Platform.operatingSystemVersion, whose Windows
// form looks like: "Windows 10 Pro" 10.0 (Build 22631).

import 'dart:io';

class VersionHelper {
  VersionHelper._();

  static final VersionHelper instance = VersionHelper._();

  /// Windows 10 RS5 (1809) build number.
  static const int _rs5Build = 17763;

  int? _majorVersion;
  int? _buildNumber;

  void _parse() {
    if (_majorVersion != null) {
      return;
    }
    _majorVersion = 0;
    _buildNumber = 0;
    if (!Platform.isWindows) {
      return;
    }
    final version = Platform.operatingSystemVersion;
    final majorMatch = RegExp(r'(\d+)\.\d+').firstMatch(version);
    if (majorMatch != null) {
      _majorVersion = int.tryParse(majorMatch.group(1)!) ?? 0;
    }
    final buildMatch = RegExp(r'[Bb]uild\s+(\d+)').firstMatch(version);
    if (buildMatch != null) {
      _buildNumber = int.tryParse(buildMatch.group(1)!) ?? 0;
    }
  }

  int get majorVersion {
    _parse();
    return _majorVersion!;
  }

  int get buildNumber {
    _parse();
    return _buildNumber!;
  }

  bool get isWindows10RS5OrGreater {
    if (!Platform.isWindows) {
      return false;
    }
    _parse();
    if (_majorVersion! > 10) {
      return true;
    }
    return _majorVersion == 10 && _buildNumber! >= _rs5Build;
  }
}
