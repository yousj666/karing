// Reconstructed for the Yousj Enhanced fork (upstream file missing).
//
// API pinned from call sites (settings_screen.dart, group_helper.dart):
//   * `VersionCompareUtils.compareVersion(a, b)` — int compared against 0
//     (negative: a < b; zero: equal; positive: a > b).
//   * `VersionCompareUtils.compareVersionWithLength(a, b, 2)` — same, but
//     only the first N version segments are compared (group_helper.dart
//     uses it to compare core versions by major.minor only).

class VersionCompareUtils {
  static List<int> _parse(String version) {
    final result = <int>[];
    for (final part in version.trim().split('.')) {
      // Tolerate suffixes like "2931-beta": keep the leading number.
      final digits = StringBuffer();
      for (final unit in part.codeUnits) {
        if (unit >= 0x30 && unit <= 0x39) {
          digits.writeCharCode(unit);
        } else {
          break;
        }
      }
      result.add(digits.isEmpty ? 0 : int.parse(digits.toString()));
    }
    return result;
  }

  static int _compareLists(List<int> a, List<int> b, int? length) {
    final n = length ?? (a.length > b.length ? a.length : b.length);
    for (int i = 0; i < n; i++) {
      final av = i < a.length ? a[i] : 0;
      final bv = i < b.length ? b[i] : 0;
      if (av != bv) {
        return av < bv ? -1 : 1;
      }
    }
    return 0;
  }

  static int compareVersion(String a, String b) {
    return _compareLists(_parse(a), _parse(b), null);
  }

  static int compareVersionWithLength(String a, String b, int length) {
    return _compareLists(_parse(a), _parse(b), length);
  }
}
