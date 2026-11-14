// Reconstructed for the Yousj Enhanced fork (2026-11-14) from call sites:
//  - toImage(content) -> ReturnResult<widgets.Image> (sync; qrcode_screen
//    and the LAN-sync screen keep the Image as state)
//  - scanFromFile(path) / scanFromImageData(bytes) -> Future<String?>
//    (add_profile_by_scan_qrcode_screen)
//  - saveAsImage(content, savePath) — writes the QR PNG to disk
// Generation and decoding both go through zxing2 (Encoder / QRCodeReader);
// rasterisation uses package:image.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart' as widgets;
import 'package:image/image.dart' as img;
import 'package:karing/app/runtime/return_result.dart';
import 'package:zxing2/qrcode.dart';

class QrcodeUtils {
  QrcodeUtils._();

  static const int _targetSize = 512;

  /// Render [content] as a QR PNG (with quiet zone), or null on failure.
  static Uint8List? _encodePng(String content) {
    try {
      final qr = Encoder.encode(content, ErrorCorrectionLevel.M);
      final matrix = qr.matrix;
      if (matrix == null) {
        return null;
      }
      final modules = matrix.width;
      const quiet = 4;
      final scale = (_targetSize / (modules + quiet * 2)).ceil().clamp(1, 32);
      final size = (modules + quiet * 2) * scale;
      final image = img.Image(width: size, height: size);
      img.fill(image, color: img.ColorRgb8(255, 255, 255));
      final black = img.ColorRgb8(0, 0, 0);
      for (var y = 0; y < matrix.height; y++) {
        for (var x = 0; x < matrix.width; x++) {
          if (matrix.get(x, y) == 1) {
            final px = (x + quiet) * scale;
            final py = (y + quiet) * scale;
            img.fillRect(
              image,
              x1: px,
              y1: py,
              x2: px + scale - 1,
              y2: py + scale - 1,
              color: black,
            );
          }
        }
      }
      return img.encodePng(image);
    } catch (_) {
      return null;
    }
  }

  static ReturnResult<widgets.Image> toImage(String content) {
    final png = _encodePng(content);
    if (png == null) {
      return ReturnResult<widgets.Image>(
        error: ReturnResultError('qrcode encode failed'),
      );
    }
    return ReturnResult<widgets.Image>(data: widgets.Image.memory(png));
  }

  static Future<void> saveAsImage(String content, String savePath) async {
    final png = _encodePng(content);
    if (png == null) {
      return;
    }
    await File(savePath).writeAsBytes(png);
  }

  static String? _decode(img.Image image) {
    try {
      final width = image.width;
      final height = image.height;
      final pixels = Int32List(width * height);
      for (var y = 0; y < height; y++) {
        for (var x = 0; x < width; x++) {
          final p = image.getPixel(x, y);
          final a = p.a.toInt() & 0xff;
          final r = p.r.toInt() & 0xff;
          final g = p.g.toInt() & 0xff;
          final b = p.b.toInt() & 0xff;
          pixels[y * width + x] = (a << 24) | (r << 16) | (g << 8) | b;
        }
      }
      final source = RGBLuminanceSource(width, height, pixels);
      final bitmap = BinaryBitmap(HybridBinarizer(source));
      final result = QRCodeReader().decode(bitmap);
      return result.text;
    } catch (_) {
      return null;
    }
  }

  static Future<String?> scanFromImageData(Uint8List bytes) async {
    try {
      final image = img.decodeImage(bytes);
      if (image == null) {
        return null;
      }
      return _decode(image);
    } catch (_) {
      return null;
    }
  }

  static Future<String?> scanFromFile(String filePath) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) {
        return null;
      }
      return scanFromImageData(await file.readAsBytes());
    } catch (_) {
      return null;
    }
  }
}
