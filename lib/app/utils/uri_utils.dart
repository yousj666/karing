// Reconstructed for the Yousj Enhanced fork (upstream file missing).
//
// API pinned from call sites (add_profile_by_link_or_content_screen.dart,
// dns_settings_screen.dart):
//   Uri? uri = UriUtils.parseUrlFixIPV6(urlText);
// — like Uri.tryParse, but tolerant of unbracketed IPv6 literals in the
// authority ("http://2001:db8::1:8080/path"), which Uri.parse rejects or
// misparses.

class UriUtils {
  static Uri? parseUrlFixIPV6(String url) {
    final parsed = Uri.tryParse(url);
    if (parsed != null && parsed.hasScheme) {
      return parsed;
    }
    // Try to repair an unbracketed IPv6 host: scheme://<ipv6>[:port][/...]
    final schemeEnd = url.indexOf('://');
    if (schemeEnd <= 0) {
      return parsed;
    }
    final rest = url.substring(schemeEnd + 3);
    final pathStart = rest.indexOf('/');
    final authority = pathStart >= 0 ? rest.substring(0, pathStart) : rest;
    final tail = pathStart >= 0 ? rest.substring(pathStart) : '';
    if (authority.startsWith('[')) {
      return parsed;
    }
    // Split a trailing :port only when the authority has more than one
    // colon (an IPv6 literal); a single colon is a normal host:port.
    final colonCount = ':'.allMatches(authority).length;
    if (colonCount < 2) {
      return parsed;
    }
    String host = authority;
    String port = '';
    final lastColon = authority.lastIndexOf(':');
    final maybePort = authority.substring(lastColon + 1);
    if (int.tryParse(maybePort) != null) {
      host = authority.substring(0, lastColon);
      port = ':$maybePort';
    }
    final fixed = '${url.substring(0, schemeEnd + 3)}[$host]$port$tail';
    return Uri.tryParse(fixed) ?? parsed;
  }
}
