// Reconstructed for the Yousj Enhanced fork (upstream file missing).
//
// API pinned from call sites
// (uwp_loopback_exemption_windows_screen.dart):
//   List<UWPMapping> data = await UWPUtils.getMappings();
//     — app entries with .name (sort/display) and .sid (the checked set
//       stores SIDs).
//   ReturnResult<Set<String>> result = await UWPUtils.getNetIsolation();
//     — SIDs currently loopback-exempted.
//   await UWPUtils.SetNetIsolation(setOfSids, addOrRemove);
//   UWPUtils.ClearNetIsolation() exists (referenced in a comment).
//
// Implementation: app list from PowerShell Get-AppxPackage; the app
// container SID for a package family name is derived through
// userenv!DeriveAppContainerSidFromAppContainerName (dart:ffi);
// exemptions are read/applied with CheckNetIsolation.exe.

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:karing/app/runtime/return_result.dart';

class UWPMapping {
  String name = '';
  String sid = '';
  String packageFamilyName = '';

  Map<String, dynamic> toJson() => {
    'name': name,
    'sid': sid,
    'package_family_name': packageFamilyName,
  };

  void fromJson(Map<String, dynamic>? map) {
    if (map == null) {
      return;
    }
    name = map['name'] ?? '';
    sid = map['sid'] ?? '';
    packageFamilyName = map['package_family_name'] ?? '';
  }

  static UWPMapping fromJsonStatic(Map<String, dynamic>? map) {
    final mapping = UWPMapping();
    mapping.fromJson(map);
    return mapping;
  }
}

typedef _DeriveSidNative =
    Int32 Function(Pointer<Utf16> name, Pointer<Pointer<Void>> sid);
typedef _DeriveSidDart =
    int Function(Pointer<Utf16> name, Pointer<Pointer<Void>> sid);
typedef _SidToStringNative =
    Int32 Function(Pointer<Void> sid, Pointer<Pointer<Utf16>> out);
typedef _SidToStringDart =
    int Function(Pointer<Void> sid, Pointer<Pointer<Utf16>> out);
typedef _LocalFreeNative = Pointer<Void> Function(Pointer<Void> mem);
typedef _LocalFreeDart = Pointer<Void> Function(Pointer<Void> mem);
typedef _FreeSidNative = Pointer<Void> Function(Pointer<Void> sid);
typedef _FreeSidDart = Pointer<Void> Function(Pointer<Void> sid);

class UWPUtils {
  /// Derive the app-container SID string for a package family name, or
  /// null when derivation fails.
  static String? _deriveSid(String packageFamilyName) {
    try {
      final userenv = DynamicLibrary.open('userenv.dll');
      final advapi = DynamicLibrary.open('advapi32.dll');
      final kernel = DynamicLibrary.open('kernel32.dll');
      final derive = userenv
          .lookupFunction<_DeriveSidNative, _DeriveSidDart>(
            'DeriveAppContainerSidFromAppContainerName',
          );
      final toString = advapi
          .lookupFunction<_SidToStringNative, _SidToStringDart>(
            'ConvertSidToStringSidW',
          );
      final freeSid = advapi.lookupFunction<_FreeSidNative, _FreeSidDart>(
        'FreeSid',
      );
      final localFree = kernel
          .lookupFunction<_LocalFreeNative, _LocalFreeDart>('LocalFree');

      final namePtr = packageFamilyName.toNativeUtf16();
      final sidPtr = calloc<Pointer<Void>>();
      try {
        final hr = derive(namePtr, sidPtr);
        if (hr != 0 || sidPtr.value == nullptr) {
          return null;
        }
        final outPtr = calloc<Pointer<Utf16>>();
        try {
          final ok = toString(sidPtr.value, outPtr);
          if (ok == 0 || outPtr.value == nullptr) {
            return null;
          }
          final sid = outPtr.value.toDartString();
          localFree(outPtr.value.cast());
          return sid;
        } finally {
          calloc.free(outPtr);
        }
      } finally {
        if (sidPtr.value != nullptr) {
          freeSid(sidPtr.value);
        }
        calloc.free(sidPtr);
        calloc.free(namePtr);
      }
    } catch (_) {
      return null;
    }
  }

  /// All installed AppX/UWP packages with their container SIDs.
  static Future<List<UWPMapping>> getMappings() async {
    final result = <UWPMapping>[];
    if (!Platform.isWindows) {
      return result;
    }
    try {
      final proc = await Process.run('powershell', [
        '-NoProfile',
        '-Command',
        'Get-AppxPackage | Select-Object Name,PackageFamilyName | ConvertTo-Json -Compress',
      ]);
      if (proc.exitCode != 0) {
        return result;
      }
      final decoded = jsonDecode(proc.stdout as String);
      final entries = decoded is List ? decoded : [decoded];
      for (final entry in entries) {
        if (entry is! Map) {
          continue;
        }
        final mapping = UWPMapping();
        mapping.name = entry['Name']?.toString() ?? '';
        mapping.packageFamilyName =
            entry['PackageFamilyName']?.toString() ?? '';
        if (mapping.packageFamilyName.isNotEmpty) {
          mapping.sid = _deriveSid(mapping.packageFamilyName) ?? '';
        }
        result.add(mapping);
      }
    } catch (_) {}
    result.sort((a, b) => a.name.compareTo(b.name));
    return result;
  }

  /// SIDs that currently hold a loopback exemption.
  static Future<ReturnResult<Set<String>>> getNetIsolation() async {
    try {
      if (!Platform.isWindows) {
        return ReturnResult(data: <String>{});
      }
      final proc = await Process.run('CheckNetIsolation.exe', [
        'LoopbackExempt',
        '-s',
      ]);
      final output = '${proc.stdout}\n${proc.stderr}';
      final sids = RegExp(
        r'S-1-15-\d+(?:-\d+)+',
      ).allMatches(output).map((m) => m.group(0)!).toSet();
      return ReturnResult(data: sids);
    } catch (err) {
      return ReturnResult(error: ReturnResultError(err.toString()));
    }
  }

  /// Add (add=true) or remove (add=false) loopback exemptions for SIDs.
  static Future<void> SetNetIsolation(Set<String> sids, bool add) async {
    if (!Platform.isWindows) {
      return;
    }
    for (final sid in sids) {
      try {
        await Process.run('CheckNetIsolation.exe', [
          'LoopbackExempt',
          add ? '-a' : '-d',
          '-s=$sid',
        ]);
      } catch (_) {}
    }
  }

  /// Remove all loopback exemptions.
  static Future<void> ClearNetIsolation() async {
    if (!Platform.isWindows) {
      return;
    }
    try {
      await Process.run('CheckNetIsolation.exe', ['LoopbackExempt', '-c']);
    } catch (_) {}
  }
}
