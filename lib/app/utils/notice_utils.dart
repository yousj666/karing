// Reconstructed for the Yousj Enhanced fork (upstream file missing).
//
// API pinned from call sites:
//   * board_provider_notice_manager.dart:248:
//     `RawNoticeItem? gnotice = await NoticeUtils.parseNotice(html)` —
//     parses a provider notice page (HTML) into a RawNoticeItem.
//   * notice_manager.dart: RawNoticeItem is the element type of
//     KaringUtils.getNotice()'s ReturnResult; its String fields
//     updateTime / expireTime / title / content / url are copied into the
//     app's NoticeItem records.

class RawNoticeItem {
  String updateTime = '';
  String expireTime = '';
  String title = '';
  String content = '';
  String url = '';

  Map<String, dynamic> toJson() => {
    'update_time': updateTime,
    'expire_time': expireTime,
    'title': title,
    'content': content,
    'url': url,
  };

  void fromJson(Map<String, dynamic>? map) {
    if (map == null) {
      return;
    }
    updateTime = map['update_time'] ?? map['updateTime'] ?? '';
    expireTime = map['expire_time'] ?? map['expireTime'] ?? '';
    title = map['title'] ?? '';
    content = map['content'] ?? '';
    url = map['url'] ?? '';
  }

  static RawNoticeItem fromJsonStatic(Map<String, dynamic>? map) {
    final item = RawNoticeItem();
    item.fromJson(map);
    return item;
  }
}

class NoticeUtils {
  static String _stripTags(String html) {
    return html
        .replaceAll(RegExp(r'<script[\s\S]*?</script>', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'<style[\s\S]*?</style>', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'<[^>]+>'), ' ')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static String? _firstMatch(String text, List<RegExp> patterns) {
    for (final pattern in patterns) {
      final match = pattern.firstMatch(text);
      if (match != null && match.groupCount >= 1) {
        return match.group(1)?.trim();
      }
    }
    return null;
  }

  /// Parse a provider notice page into a [RawNoticeItem]. Returns null
  /// when the page carries no recognizable notice content.
  static Future<RawNoticeItem?> parseNotice(String html) async {
    if (html.trim().isEmpty) {
      return null;
    }
    final item = RawNoticeItem();

    final title = _firstMatch(html, [
      RegExp(r'<h1[^>]*>([\s\S]*?)</h1>', caseSensitive: false),
      RegExp(r'<title[^>]*>([\s\S]*?)</title>', caseSensitive: false),
    ]);
    item.title = title != null ? _stripTags(title) : '';

    final text = _stripTags(html);
    if (text.isEmpty && item.title.isEmpty) {
      return null;
    }
    item.content = text;

    // Dates are matched in ISO-like form wherever they appear on the page.
    final datePattern = RegExp(r'\d{4}-\d{2}-\d{2}(?:[ T]\d{2}:\d{2}(?::\d{2})?)?');
    final dates = datePattern.allMatches(text).map((m) => m.group(0)!).toList();
    if (dates.isNotEmpty) {
      item.updateTime = dates.first;
    }
    if (dates.length > 1) {
      item.expireTime = dates.last;
    }

    final link = _firstMatch(html, [
      RegExp(r'<a[^>]+href="(https?://[^"]+)"', caseSensitive: false),
    ]);
    if (link != null) {
      item.url = link;
    }
    return item;
  }
}
