// Reconstructed for the Yousj Enhanced fork (upstream file missing).
//
// API pinned from call sites:
//   * diversion_rules_custom_set_screen.dart: a `DiversionCustomRules`
//     object with a `.rules` list; each rule has mutable `name` (String),
//     `enable` (bool) and `outbound` (String) fields, switched against the
//     DiversionCustomRules.kDirect / kBlock / kUrltest / kCurrentSelected /
//     kNone constants; `await DiversionCustomRules.importRules(rules)`.
//   * diversion_group_custom_screen.dart:
//     `await DiversionCustomRules.getFromFile(path)` -> ReturnResult whose
//     .error is checked and .data pushed into the editor;
//     `DiversionCustomRules.exportRules()` -> DiversionCustomRules, written
//     out with JsonEncoder (so toJson() is required);
//     `await DiversionCustomRulesPreset.getPreset(regionCode)` ->
//     DiversionCustomRules?.
//
// The JSON format is grounded by the bundled presets in
// assets/datas/preset/*.json:
//   {"rules": [{"name": ..., "switch": bool, "outbound": "direct"|...,
//               "rule_set_build_in": [...], "domain_suffix": [...],
//               "domain_keyword": [...], "ip_cidr": [...],
//               "package": [...], "processName": [...]}]}

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:karing/app/modules/server_manager.dart';
import 'package:karing/app/runtime/return_result.dart';
import 'package:karing/app/utils/convert_utils.dart';
import 'package:vpn_service/vpn_service.dart'
    show DiversionRulesGroup, ServerDiversionGroupItem;

class DiversionCustomRule {
  String name = '';
  bool enable = true;
  String outbound = DiversionCustomRules.kNone;
  List<String> ruleSetBuildIn = [];
  List<String> domainSuffix = [];
  List<String> domainKeyword = [];
  List<String> ipCidr = [];
  List<String> package = [];
  List<String> processName = [];

  Map<String, dynamic> toJson() => {
    'name': name,
    'switch': enable,
    'outbound': outbound,
    if (ruleSetBuildIn.isNotEmpty) 'rule_set_build_in': ruleSetBuildIn,
    if (domainSuffix.isNotEmpty) 'domain_suffix': domainSuffix,
    if (domainKeyword.isNotEmpty) 'domain_keyword': domainKeyword,
    if (ipCidr.isNotEmpty) 'ip_cidr': ipCidr,
    if (package.isNotEmpty) 'package': package,
    if (processName.isNotEmpty) 'processName': processName,
  };

  void fromJson(Map<String, dynamic> map) {
    name = map['name'] ?? '';
    enable = map['switch'] ?? true;
    outbound = map['outbound'] ?? DiversionCustomRules.kNone;
    ruleSetBuildIn =
        ConvertUtils.getListStringFromDynamic(map['rule_set_build_in'], true, [])
            ?.toList() ??
        [];
    domainSuffix =
        ConvertUtils.getListStringFromDynamic(map['domain_suffix'], true, [])
            ?.toList() ??
        [];
    domainKeyword =
        ConvertUtils.getListStringFromDynamic(map['domain_keyword'], true, [])
            ?.toList() ??
        [];
    ipCidr =
        ConvertUtils.getListStringFromDynamic(map['ip_cidr'], true, [])
            ?.toList() ??
        [];
    package =
        ConvertUtils.getListStringFromDynamic(map['package'], true, [])
            ?.toList() ??
        [];
    processName =
        ConvertUtils.getListStringFromDynamic(map['processName'], true, [])
            ?.toList() ??
        [];
  }

  static DiversionCustomRule fromJsonStatic(Map<String, dynamic> map) {
    final rule = DiversionCustomRule();
    rule.fromJson(map);
    return rule;
  }

  /// Convert to the config model's rule group (matchers only; the target
  /// outbound of a diversion group item is chosen separately, so the
  /// per-rule outbound is not representable in DiversionRulesGroup).
  DiversionRulesGroup toRuleGroup() {
    final group = DiversionRulesGroup();
    group.name = name;
    group.ruleSetBuildIn = List<String>.from(ruleSetBuildIn);
    group.domainSuffix = List<String>.from(domainSuffix);
    group.domainKeyword = List<String>.from(domainKeyword);
    group.ipCidr = List<String>.from(ipCidr);
    group.package = List<String>.from(package);
    group.processName = List<String>.from(processName);
    return group;
  }
}

class DiversionCustomRules {
  static const String kDirect = 'direct';
  static const String kBlock = 'block';
  static const String kUrltest = 'urltest';
  static const String kCurrentSelected = 'currentSelected';
  static const String kNone = '';

  /// Group id under which imported custom rules are stored.
  static const String kCustomGroupId = 'custom';

  List<DiversionCustomRule> rules = [];

  Map<String, dynamic> toJson() => {
    'rules': rules.map((e) => e.toJson()).toList(),
  };

  void fromJson(Map<String, dynamic>? map) {
    rules = [];
    if (map == null) {
      return;
    }
    final list = map['rules'];
    if (list is List) {
      for (final entry in list) {
        if (entry is Map<String, dynamic>) {
          rules.add(DiversionCustomRule.fromJsonStatic(entry));
        } else if (entry is Map) {
          rules.add(
            DiversionCustomRule.fromJsonStatic(
              Map<String, dynamic>.from(entry),
            ),
          );
        }
      }
    }
  }

  static DiversionCustomRules fromJsonStatic(Map<String, dynamic>? map) {
    final rules = DiversionCustomRules();
    rules.fromJson(map);
    return rules;
  }

  /// Load a rules file (the export format above).
  static Future<ReturnResult<DiversionCustomRules>> getFromFile(
    String path,
  ) async {
    try {
      final content = await File(path).readAsString();
      final decoded = jsonDecode(content);
      if (decoded is! Map<String, dynamic>) {
        return ReturnResult(error: ReturnResultError('invalid file format'));
      }
      return ReturnResult(data: DiversionCustomRules.fromJsonStatic(decoded));
    } catch (err) {
      return ReturnResult(error: ReturnResultError(err.toString()));
    }
  }

  /// Export the currently stored custom rules (the group written by
  /// [importRules]) back to the editable model.
  static DiversionCustomRules exportRules() {
    final result = DiversionCustomRules();
    try {
      final config = ServerManager.getDiversionGroupConfig();
      for (final item in config.items) {
        if (item.groupid != kCustomGroupId) {
          continue;
        }
        for (final group in item.groups) {
          final rule = DiversionCustomRule();
          rule.name = group.name;
          rule.ruleSetBuildIn = List<String>.from(group.ruleSetBuildIn);
          rule.domainSuffix = List<String>.from(group.domainSuffix);
          rule.domainKeyword = List<String>.from(group.domainKeyword);
          rule.ipCidr = List<String>.from(group.ipCidr);
          rule.package = List<String>.from(group.package);
          rule.processName = List<String>.from(group.processName);
          result.rules.add(rule);
        }
      }
    } catch (_) {}
    return result;
  }

  /// Store [rules] as the app's custom diversion group (enabled rules
  /// only), replacing any previously imported custom group.
  static Future<void> importRules(DiversionCustomRules rules) async {
    final config = ServerManager.getDiversionGroupConfig();
    config.items.removeWhere((item) => item.groupid == kCustomGroupId);
    final item = ServerDiversionGroupItem();
    item.groupid = kCustomGroupId;
    item.remark = 'custom';
    for (final rule in rules.rules) {
      if (!rule.enable) {
        continue;
      }
      final group = rule.toRuleGroup();
      group.groupid = kCustomGroupId;
      group.name = rule.name;
      item.groups.add(group);
    }
    config.items.add(item);
    await ServerManager.saveDiversionGroupConfig();
  }
}

class DiversionCustomRulesPreset {
  /// Bundled per-region presets live at assets/datas/preset/<region>.json
  /// with default.json as the fallback.
  static Future<DiversionCustomRules?> getPreset(String regionCode) async {
    final candidates = <String>[
      'assets/datas/preset/${regionCode.toLowerCase()}.json',
      'assets/datas/preset/default.json',
    ];
    for (final path in candidates) {
      try {
        final content = await rootBundle.loadString(path);
        final decoded = jsonDecode(content);
        if (decoded is Map<String, dynamic>) {
          return DiversionCustomRules.fromJsonStatic(decoded);
        }
      } catch (_) {
        // Try the next candidate.
      }
    }
    return null;
  }
}
