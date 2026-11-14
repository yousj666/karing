// Reconstructed for the Yousj Enhanced fork (upstream file missing).
//
// Only referenced from a commented-out maintenance block in main.dart:
//   var subnets = await GeoipSubnetUtils.genClientSubnet(files);
//   await GeoipSubnetUtils.saveSubnets(subnets, target);
// where `files` are geoip JSON files from the karing-ruleset repo and
// the target is geoip_subnets.json (the app ships one at
// assets/datas/geoip_subnets.json). It condenses each country's CIDR
// list for client-side subnet matching.

import 'dart:convert';
import 'dart:io';

class GeoipSubnetUtils {
  /// Read geoip JSON files ({code: [cidr, ...]} or [{...}]) and merge
  /// them into one code -> CIDRs map.
  static Future<Map<String, List<String>>> genClientSubnet(
    List<String> files,
  ) async {
    final result = <String, List<String>>{};
    for (final path in files) {
      try {
        final decoded = jsonDecode(await File(path).readAsString());
        if (decoded is Map<String, dynamic>) {
          decoded.forEach((code, value) {
            if (value is List) {
              final list = result.putIfAbsent(code, () => []);
              for (final entry in value) {
                final cidr = entry.toString();
                if (!list.contains(cidr)) {
                  list.add(cidr);
                }
              }
            }
          });
        }
      } catch (_) {
        // Skip unreadable files in this maintenance helper.
      }
    }
    return result;
  }

  static Future<void> saveSubnets(
    Map<String, List<String>> subnets,
    String target,
  ) async {
    final file = File(target);
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(subnets), flush: true);
  }
}
