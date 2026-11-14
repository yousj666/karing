// yousj-plus (v1.0.6): restricted action tools for the built-in AI
// assistant.
//
// The assistant may do exactly three kinds of things, exposed as four
// OpenAI-style function tools:
//   list_nodes     — read the app's real node/profile data (feeds the
//                    "recommend a node" ability; recommendations are made
//                    by the model from this data, never invented).
//   select_node    — select (and persist) one node as the current node.
//   select_profile — exclusively enable one profile (persisted).
//   connect        — run the app's own start path and report the REAL
//                    resulting state.
// Nothing else: no delete, no settings writes, no diversion edits. (The
// pre-existing "import a config from a chat code block" flow is a UI
// button the user taps, not a tool, and is unchanged.)
//
// Anti-hallucination guardrail, enforced HERE and not left to the model:
// a select only executes when the query matches exactly one candidate
// (exact match first, then unique substring match). Zero or multiple
// matches execute nothing and hand the candidates back so the model has
// to ask the user to disambiguate.

import 'dart:convert';

import 'package:karing/app/local_services/vpn_service.dart';
import 'package:karing/app/modules/biz.dart';
import 'package:karing/app/modules/server_manager.dart';
// ProxyConfig / ServerConfigGroupItem / FlutterVpnServiceState are
// re-exported by vpn_service.dart.

class AiToolOutcome {
  // Text fed back to the model as the tool result.
  final String toolResult;

  // Explicit result message posted into the chat transcript ("" when the
  // call changed nothing worth recording, e.g. a pure list query).
  final String chatRecord;

  const AiToolOutcome(this.toolResult, this.chatRecord);
}

class AiAssistantTools {
  static const int kMaxListedNodes = 300;

  static List<Map<String, dynamic>> toolDefinitions() {
    return [
      {
        'type': 'function',
        'function': {
          'name': 'list_nodes',
          'description':
              '列出应用内已启用配置中的全部节点（名称、所属配置、类型、服务器、地区、已测延迟）与当前选中节点。'
              '在推荐节点或执行选中前，应先调用本工具获取真实数据；延迟为空表示从未测速，不要编造延迟。',
          'parameters': {
            'type': 'object',
            'properties': <String, dynamic>{},
            'additionalProperties': false,
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'select_node',
          'description':
              '选中并启用一个节点作为当前节点（会落盘保存）。参数 name 是用户所指的节点名称（或「配置名 / 节点名」）。'
              '只有唯一匹配时才会执行；匹配不到或有多个候选时不会执行，工具会返回候选列表，你必须先向用户问清是哪一个。',
          'parameters': {
            'type': 'object',
            'properties': {
              'name': {
                'type': 'string',
                'description': '节点名称，如「香港 01」或「我的订阅 / 香港 01」',
              },
            },
            'required': ['name'],
            'additionalProperties': false,
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'select_profile',
          'description':
              '选中并启用一份配置（订阅）：将其设为唯一启用配置并落盘保存。参数 name 是配置的名称（备注）。'
              '只有唯一匹配时才会执行；匹配不到或有多个候选时不会执行，你必须先向用户问清。',
          'parameters': {
            'type': 'object',
            'properties': {
              'name': {'type': 'string', 'description': '配置名称（备注）'},
            },
            'required': ['name'],
            'additionalProperties': false,
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'connect',
          'description':
              '调用应用现有的连接动作启动代理，并返回连接后的真实状态。'
              '只有当工具结果明确说已连接时，才能告诉用户已连接；结果说未连接时必须如实转述原因，绝不能声称已连接。',
          'parameters': {
            'type': 'object',
            'properties': <String, dynamic>{},
            'additionalProperties': false,
          },
        },
      },
    ];
  }

  static Future<AiToolOutcome> execute(
    String name,
    Map<String, dynamic> args,
  ) async {
    switch (name) {
      case 'list_nodes':
        return _listNodes();
      case 'select_node':
        return _selectNode((args['name'] as String?) ?? '');
      case 'select_profile':
        return _selectProfile((args['name'] as String?) ?? '');
      case 'connect':
        return _connect();
      default:
        return AiToolOutcome('未知工具：$name（未执行任何操作）', '');
    }
  }

  // --- data ------------------------------------------------------------------

  static List<({ServerConfigGroupItem group, ProxyConfig node})>
  _enabledNodes() {
    final out = <({ServerConfigGroupItem group, ProxyConfig node})>[];
    for (final group in ServerManager.getConfig().items) {
      if (!group.enable) {
        continue;
      }
      for (final node in group.servers) {
        out.add((group: group, node: node));
      }
    }
    return out;
  }

  static String _nodeLabel(ServerConfigGroupItem group, ProxyConfig node) {
    return '${group.remark} / ${node.tag}';
  }

  static AiToolOutcome _listNodes() {
    final nodes = _enabledNodes();
    final current = VPNService.getCurrent();
    final profiles = <Map<String, dynamic>>[];
    for (final group in ServerManager.getConfig().items) {
      profiles.add({
        'name': group.remark,
        'type': group.type.name,
        'enabled': group.enable,
        'node_count': group.servers.length,
      });
    }
    final listed = nodes.take(kMaxListedNodes).map((e) {
      return {
        'name': e.node.tag,
        'profile': e.group.remark,
        'type': e.node.type,
        'server': e.node.server,
        'port': e.node.serverport,
        'region': e.node.outletregion,
        // "" means never speed-tested; surfaced as null so the model
        // cannot mistake it for a real measurement.
        'latency': e.node.latency.isEmpty ? null : e.node.latency,
        'selected':
            e.node.groupid == current.groupid && e.node.tag == current.tag,
      };
    }).toList();
    final data = {
      'profiles': profiles,
      'nodes': listed,
      'node_total': nodes.length,
      'nodes_truncated': nodes.length > listed.length,
      'current_node': current.tag.isEmpty
          ? null
          : {'name': current.tag, 'profile_group': current.groupid},
      'latency_note': 'latency 为 null 表示该节点从未测速，没有延迟数据，不要编造。',
    };
    return AiToolOutcome(jsonEncode(data), '');
  }

  // --- matching (the guardrail) ----------------------------------------------

  // Returns (match, candidates, problem): exactly one of them is
  // meaningful — a single match to execute, or a problem description
  // ("not_found" / "ambiguous") plus the candidates to show the user.
  static (T?, List<T>, String) _uniqueMatch<T>(
    List<T> items,
    String query,
    String Function(T) labelOf,
  ) {
    final q = query.trim();
    if (q.isEmpty) {
      return (null, <T>[], 'empty_query');
    }
    final exact = items.where((e) => labelOf(e) == q).toList();
    if (exact.length == 1) {
      return (exact.first, <T>[], '');
    }
    if (exact.length > 1) {
      return (null, exact, 'ambiguous');
    }
    final lower = q.toLowerCase();
    final fuzzy = items
        .where((e) => labelOf(e).toLowerCase().contains(lower))
        .toList();
    if (fuzzy.length == 1) {
      return (fuzzy.first, <T>[], '');
    }
    if (fuzzy.length > 1) {
      return (null, fuzzy, 'ambiguous');
    }
    return (null, <T>[], 'not_found');
  }

  // --- actions -----------------------------------------------------------------

  static Future<AiToolOutcome> _selectNode(String query) async {
    final nodes = _enabledNodes();
    final (match, candidates, problem) = _uniqueMatch(
      nodes,
      query,
      (e) => e.node.tag,
    );
    // Also accept the explicit "profile / node" form as an exact key.
    var resolved = match;
    if (resolved == null && problem == 'not_found') {
      final (m2, c2, p2) = _uniqueMatch(
        nodes,
        query,
        (e) => _nodeLabel(e.group, e.node),
      );
      if (m2 != null) {
        resolved = m2;
      } else if (p2 == 'ambiguous') {
        return AiToolOutcome(
          '有多个候选，未执行选中：${c2.map((e) => _nodeLabel(e.group, e.node)).join('；')}。请向用户问清是哪一个。',
          '⚠️ 「$query」有多个候选节点，未执行选中，已请你确认。',
        );
      }
    }
    if (resolved == null) {
      if (problem == 'ambiguous') {
        final list = candidates
            .map((e) => _nodeLabel(e.group, e.node))
            .join('；');
        return AiToolOutcome(
          '有多个候选，未执行选中：$list。请向用户问清是哪一个。',
          '⚠️ 「$query」有多个候选节点，未执行选中，已请你确认。',
        );
      }
      return AiToolOutcome(
        '没有找到名为「$query」的节点（仅在已启用配置中查找），未执行任何操作。请向用户核对名称，或先调用 list_nodes 查看全部节点。',
        '⚠️ 没有找到节点「$query」，未执行选中。',
      );
    }

    final node = resolved.node;
    final group = resolved.group;
    // The app's own selection bookkeeping (same calls the home screen
    // makes when a node is picked): set the service's current node,
    // record it as most-recent and persist, and flag the config dirty so
    // a running connection is reloaded with the new node.
    VPNService.setCurrent(node);
    ServerManager.addRecent(node);
    await ServerManager.saveUse();
    ServerManager.setDirty(true);
    final label = _nodeLabel(group, node);
    return AiToolOutcome(
      '已选中节点：$label（类型 ${node.type}，服务器 ${node.server}:${node.serverport}），已保存。',
      '✅ 已选中节点：$label',
    );
  }

  static Future<AiToolOutcome> _selectProfile(String query) async {
    final items = ServerManager.getConfig().items;
    final (match, candidates, problem) = _uniqueMatch(
      items,
      query,
      (e) => e.remark,
    );
    if (match == null) {
      if (problem == 'ambiguous') {
        final list = candidates.map((e) => e.remark).join('；');
        return AiToolOutcome(
          '有多个候选配置，未执行选中：$list。请向用户问清是哪一个。',
          '⚠️ 「$query」有多个候选配置，未执行选中，已请你确认。',
        );
      }
      return AiToolOutcome(
        '没有找到名为「$query」的配置，未执行任何操作。请向用户核对名称，或先调用 list_nodes 查看全部配置。',
        '⚠️ 没有找到配置「$query」，未执行选中。',
      );
    }
    // Exclusive enable through the app's existing group management (the
    // same path the external AI API's profile select uses), then persist.
    for (final item in items) {
      final want = item.groupid == match.groupid;
      if (item.enable != want) {
        await ServerManager.enableGroup(item.groupid, want);
      }
    }
    await ServerManager.saveServerConfig();
    ServerManager.setDirty(true);
    return AiToolOutcome(
      '已启用配置：${match.remark}（其余配置已停用），已保存。',
      '✅ 已启用配置：${match.remark}',
    );
  }

  static Future<AiToolOutcome> _connect() async {
    final provider = Biz.onEventRequestStartVPN;
    if (provider == null) {
      return AiToolOutcome(
        '连接未执行：应用的连接入口尚未初始化（主页未创建），请用户先回到主页再重试。',
        '⚠️ 连接未执行：主页尚未初始化。',
      );
    }
    // The app's own start path — the very callback the home screen
    // registers for start requests (home connect switch funnels into the
    // same start/reload logic).
    final err = await provider('AiAssistant');
    final state = await VPNService.getState();
    final started = await VPNService.getStarted();
    final connected = started && state == FlutterVpnServiceState.connected;
    if (connected) {
      return AiToolOutcome(
        '连接动作已执行，应用状态为已连接（connected）。',
        '✅ 连接动作已执行，当前状态：已连接',
      );
    }
    final reason = err != null
        ? err.message
        : '应用状态为 ${state.name}（started=$started）。本版本代理核心（libbox）尚未接入，连接不会真正建立；核心接入后此动作即为真实连接。';
    return AiToolOutcome(
      '连接动作已真实调用，但当前未连接。状态：${state.name}，原因：$reason。必须如实告诉用户未连接及原因，不得声称已连接。',
      '⚠️ 连接动作已执行，但未连接：$reason',
    );
  }
}
