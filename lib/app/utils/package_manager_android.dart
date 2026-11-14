// Reconstructed for the Yousj Enhanced fork (2026-11-14) from call sites
// (packageid_multi_select_android_screen, net_connections_screen):
//  - getInstalledPackages({onValid}) -> List<PackageInfoEx>
//  - getInstalledPackageIcon(packages, packageName) -> Future<Image?>
//  - sortByName — List.sort comparator over PackageInfoEx
//  - kAndroidFlagSystem — ApplicationInfo.FLAG_SYSTEM (1)
//  - kRemoved — display name for no-longer-installed entries
// PackageInfoEx wraps the platform PackageInfo (package:
// android_package_manager) with a display name and lazy icon bytes.
// PackageInfoImpl below is a package-name-only PackageInfo (the platform
// package's own impl class is not exported); it is what the multi-select
// screen constructs for removed packages: PackageInfoImpl(papp).

import 'dart:io';
import 'dart:typed_data';

import 'package:android_package_manager/android_package_manager.dart';
import 'package:flutter/widgets.dart' as widgets;

class PackageInfoImpl extends PackageInfo {
  PackageInfoImpl(String packageName)
      : super(
          packageName: packageName,
          installLocation: AndroidInstallLocation.auto,
        );
}

class PackageInfoEx {
  /// The package's own info object (call sites read `.info.packageName`
  /// unconditionally; entries are only created for resolved packages).
  late PackageInfo info;
  String name = '';
  Uint8List? icon;
}

class PackageManagerAndroid {
  PackageManagerAndroid._();

  /// ApplicationInfo.FLAG_SYSTEM.
  static const int kAndroidFlagSystem = 1;

  static const String kRemoved = 'Removed';

  static int sortByName(PackageInfoEx a, PackageInfoEx b) {
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  }

  static Future<List<PackageInfoEx>> getInstalledPackages({
    bool Function(PackageInfo info)? onValid,
  }) async {
    final result = <PackageInfoEx>[];
    if (!Platform.isAndroid) {
      return result;
    }
    try {
      final pm = AndroidPackageManager();
      final packages = await pm.getInstalledPackages();
      if (packages == null) {
        return result;
      }
      for (final info in packages) {
        if (onValid != null && !onValid(info)) {
          continue;
        }
        final ex = PackageInfoEx();
        ex.info = info;
        var label = info.packageName ?? '';
        try {
          final fetched = await pm.getApplicationLabel(
            packageName: info.packageName ?? '',
          );
          if (fetched != null && fetched.isNotEmpty) {
            label = fetched;
          }
        } catch (_) {}
        ex.name = label;
        result.add(ex);
      }
    } catch (_) {}
    return result;
  }

  /// The app icon as a widget Image, loading (and caching into the
  /// PackageInfoEx entry) the PNG bytes on first use.
  static Future<widgets.Image?> getInstalledPackageIcon(
    List<PackageInfoEx> packages,
    String packageName,
  ) async {
    if (!Platform.isAndroid) {
      return null;
    }
    try {
      PackageInfoEx? entry;
      for (final ex in packages) {
        if (ex.info?.packageName == packageName) {
          entry = ex;
          break;
        }
      }
      var bytes = entry?.icon;
      if (bytes == null) {
        bytes = await AndroidPackageManager().getApplicationIcon(
          packageName: packageName,
        );
        if (bytes != null && entry != null) {
          entry.icon = bytes;
        }
      }
      if (bytes == null) {
        return null;
      }
      return widgets.Image.memory(bytes);
    } catch (_) {
      return null;
    }
  }
}
