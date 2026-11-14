// Reconstructed for the Yousj Enhanced fork (upstream file missing).
//
// API pinned from call sites:
//   * net_check_screen.dart:812:
//     `final routeTableResult = await SystemUtils.getRouteTable();`
//     — the result is wrapped as ReturnResult(data: routeTableResult)
//     for the net-check list, i.e. it is the route table as text.

import 'dart:io';

class SystemUtils {
  /// The system route table as text (route print / netstat -rn /
  /// ip route), or an empty string when it cannot be obtained.
  static Future<String> getRouteTable() async {
    try {
      ProcessResult result;
      if (Platform.isWindows) {
        result = await Process.run('route', ['print']);
      } else if (Platform.isLinux) {
        try {
          result = await Process.run('ip', ['route', 'show', 'table', 'all']);
          if (result.exitCode != 0) {
            result = await Process.run('netstat', ['-rn']);
          }
        } catch (_) {
          result = await Process.run('netstat', ['-rn']);
        }
      } else {
        // macOS and others
        result = await Process.run('netstat', ['-rn']);
      }
      final out = (result.stdout as String).trim();
      if (out.isNotEmpty) {
        return out;
      }
      return (result.stderr as String).trim();
    } catch (_) {
      return '';
    }
  }
}
