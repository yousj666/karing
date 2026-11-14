// Reconstructed for the Yousj Enhanced fork (2026-11-14) from call sites:
//  - getAccessibilityEnabled() -> bool (setting_manager seeds its
//    `accessibility` setting default from it)
//  - setAccessibilityEnabled(bool) — sync, fire-and-forget at call sites
//  - announce(BuildContext, String) — screen-reader announcements from
//    dialog_utils / home_screen, gated by the enabled flag
//
// The enabled flag itself is persisted by SettingManager; this class only
// carries the process-wide current value and its default (on).

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

class AccessibilityUtils {
  AccessibilityUtils._();

  static bool _enabled = true;

  static bool getAccessibilityEnabled() {
    return _enabled;
  }

  static void setAccessibilityEnabled(bool enabled) {
    _enabled = enabled;
  }

  /// Announce [text] to assistive technologies (TalkBack/VoiceOver).
  static void announce(BuildContext context, String text) {
    if (!_enabled || text.isEmpty) {
      return;
    }
    try {
      final view = View.of(context);
      SemanticsService.sendAnnouncement(view, text, TextDirection.ltr);
    } catch (_) {}
  }
}
