// Reconstructed for the Yousj Enhanced fork (upstream file missing).
//
// API pinned from call sites:
//   * net_connections_screen.dart:391:
//       IconUtils.getProcessIcon(connection.process)
//     — cached by the screen in a Map<String, Future<Image?>>; the
//     argument is the process name/path of a connection's owner.
//     (macOS takes a different branch through ProcessUtilsMacos.)
//
// Icon extraction is a native capability; the reconstruction asks the
// platform side over a method channel and returns null when no handler
// answers (the connections UI then shows a placeholder).

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' as widgets;

class IconUtils {
  static const MethodChannel _channel = MethodChannel('karing/icon_utils');
  static final Map<String, widgets.Image?> _cache = {};

  static Future<widgets.Image?> getProcessIcon(String process) async {
    if (_cache.containsKey(process)) {
      return _cache[process];
    }
    widgets.Image? image;
    try {
      final bytes = await _channel.invokeMethod<Uint8List>(
        'getProcessIcon',
        {'process': process},
      );
      if (bytes != null && bytes.isNotEmpty) {
        image = widgets.Image.memory(bytes);
      }
    } catch (_) {
      image = null;
    }
    _cache[process] = image;
    return image;
  }
}
