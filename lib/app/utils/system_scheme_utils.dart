// Reconstructed for the Yousj Enhanced fork (2026-11-14) from call sites:
//  - getKaringScheme()/getClashScheme()/getSingboxScheme() -> scheme names
//    used with Uri.isScheme (add_profile / scheme_handler)
//  - getXScheWith() -> "scheme://" prefixes for startsWith checks
//    (main.dart / my_app.dart argument sniffing)
//  - register(scheme) -> Future<String?> and unregister(scheme) -> String?
//    (error string or null); isRegistered(scheme) -> bool
//    (settings switch + home_screen startup, Windows/Linux only)
//
// Registration is per-user: Windows writes HKCU\Software\Classes via
// reg.exe; Linux drops an x-scheme-handler .desktop file and sets it as
// the xdg-mime default. macOS schemes come from Info.plist, so register
// is a no-op success there.

import 'dart:io';

class SystemSchemeUtils {
  SystemSchemeUtils._();

  static String getKaringScheme() => 'karing';
  static String getClashScheme() => 'clash';
  static String getSingboxScheme() => 'sing-box';

  static String getKaringSchemeWith() => '${getKaringScheme()}://';
  static String getClashSchemeWith() => '${getClashScheme()}://';
  static String getSingboxSchemeWith() => '${getSingboxScheme()}://';

  static final Set<String> _registeredFallback = {};

  static bool isRegistered(String scheme) {
    if (Platform.isWindows) {
      try {
        final result = Process.runSync('reg', [
          'query',
          'HKCU\\Software\\Classes\\$scheme\\shell\\open\\command',
          '/ve',
        ]);
        return result.exitCode == 0 &&
            result.stdout.toString().contains(Platform.resolvedExecutable);
      } catch (_) {
        return false;
      }
    }
    if (Platform.isLinux) {
      return File(_linuxDesktopPath(scheme)).existsSync();
    }
    return _registeredFallback.contains(scheme);
  }

  static Future<String?> register(String scheme) async {
    try {
      if (Platform.isWindows) {
        final exe = Platform.resolvedExecutable;
        final base = 'HKCU\\Software\\Classes\\$scheme';
        var result = await Process.run('reg', [
          'add', base, '/ve', '/d', 'URL:$scheme protocol', '/f',
        ]);
        if (result.exitCode != 0) {
          return result.stderr.toString();
        }
        await Process.run('reg', [
          'add', base, '/v', 'URL Protocol', '/d', '', '/f',
        ]);
        result = await Process.run('reg', [
          'add', '$base\\shell\\open\\command', '/ve', '/d', '"$exe" "%1"', '/f',
        ]);
        if (result.exitCode != 0) {
          return result.stderr.toString();
        }
        return null;
      }
      if (Platform.isLinux) {
        final file = File(_linuxDesktopPath(scheme));
        await file.parent.create(recursive: true);
        await file.writeAsString(
          '[Desktop Entry]\n'
          'Type=Application\n'
          'Name=Karing scheme handler ($scheme)\n'
          'Exec=${Platform.resolvedExecutable} %u\n'
          'MimeType=x-scheme-handler/$scheme;\n'
          'NoDisplay=true\n',
        );
        await Process.run('xdg-mime', [
          'default',
          _linuxDesktopName(scheme),
          'x-scheme-handler/$scheme',
        ]);
        return null;
      }
      _registeredFallback.add(scheme);
      return null;
    } catch (err) {
      return err.toString();
    }
  }

  static String? unregister(String scheme) {
    try {
      if (Platform.isWindows) {
        final result = Process.runSync('reg', [
          'delete',
          'HKCU\\Software\\Classes\\$scheme',
          '/f',
        ]);
        if (result.exitCode != 0) {
          return result.stderr.toString();
        }
        return null;
      }
      if (Platform.isLinux) {
        final file = File(_linuxDesktopPath(scheme));
        if (file.existsSync()) {
          file.deleteSync();
        }
        return null;
      }
      _registeredFallback.remove(scheme);
      return null;
    } catch (err) {
      return err.toString();
    }
  }

  static String _linuxDesktopName(String scheme) =>
      'karing-scheme-$scheme.desktop';

  static String _linuxDesktopPath(String scheme) {
    final home = Platform.environment['HOME'] ?? '';
    return '$home/.local/share/applications/${_linuxDesktopName(scheme)}';
  }
}
