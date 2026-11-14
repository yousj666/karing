// Reconstructed for the Yousj Enhanced fork (upstream file missing).
//
// API pinned from call sites:
//   * home_screen.dart: EmojiUtils.countryCodeToEmoji(code) renders a
//     two-letter country code as its flag emoji (regional indicators).

class EmojiUtils {
  /// "US" -> 🇺🇸. Returns the input unchanged when it is not a
  /// two-letter ASCII code.
  static String countryCodeToEmoji(String countryCode) {
    final code = countryCode.trim().toUpperCase();
    if (code.length != 2) {
      return countryCode;
    }
    final first = code.codeUnitAt(0);
    final second = code.codeUnitAt(1);
    if (first < 0x41 || first > 0x5a || second < 0x41 || second > 0x5a) {
      return countryCode;
    }
    // Regional indicator symbols start at U+1F1E6 for 'A'.
    return String.fromCharCodes([
      0x1f1e6 + (first - 0x41),
      0x1f1e6 + (second - 0x41),
    ]);
  }
}
