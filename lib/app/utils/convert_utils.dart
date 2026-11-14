// Reconstructed for the Yousj Enhanced fork (2026-11-14) from call sites.
// Only one member is referenced in the surviving tree:
// getListStringFromDynamic(dynamic, bool, List<String>) -> List<String>
// (28 sites, mostly remote_config / remote_isp_config JSON parsing; the
// result is non-null-asserted at the call sites). The bool is `true` at
// every observed site; it enables splitting a string value on commas. [?]

class ConvertUtils {
  ConvertUtils._();

  static List<String> getListStringFromDynamic(
    dynamic value,
    bool splitString,
    List<String> defaultValue,
  ) {
    if (value == null) {
      return List<String>.from(defaultValue);
    }
    if (value is List) {
      return value
          .where((e) => e != null)
          .map((e) => e.toString())
          .toList();
    }
    if (value is String) {
      if (value.isEmpty) {
        return List<String>.from(defaultValue);
      }
      if (splitString) {
        return value
            .split(',')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList();
      }
      return [value];
    }
    return [value.toString()];
  }
}
