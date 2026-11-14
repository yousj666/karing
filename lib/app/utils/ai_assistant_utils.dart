// yousj-plus: BYOK AI assistant client.
//
// Pure client-side: the only network destination is the OpenAI-compatible
// endpoint the user configured in settings (SettingConfig.ai). There is no
// first-party backend and no subscription. The user's API key is sent solely
// as the Authorization header to that endpoint and is never logged.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:karing/app/modules/setting_manager.dart';
import 'package:karing/app/runtime/return_result.dart';
import 'package:karing/app/utils/ai_assistant_tools.dart';

class AiChatMessage {
  final String role; // system | user | assistant
  final String content;
  const AiChatMessage(this.role, this.content);

  Map<String, dynamic> toJson() => {'role': role, 'content': content};
}

class AiAssistantUtils {
  static const String kSystemPrompt = '''
你是 Yousj Enhanced 内置的 AI 助手，一名代理与网络配置专家，精通 sing-box 与 Clash/mihomo 的配置格式、分流（路由）规则、DNS、TUN 与测速设置。

你的职责：
- 帮用户生成、修改、讲解 sing-box JSON 配置与 Clash YAML 配置；
- 解答节点、代理组、规则集、分流规则方面的问题。

回答要求：
- 生成完整配置时，必须把整份配置放进同一个 ```json 或 ```yaml 代码块完整输出（应用会据此提供一键导入），不要把一份配置拆散到多个代码块里。
- 回答简洁、准确；不确定的参数要明确说明，不要编造不存在的配置字段。

你现在能通过工具（函数调用）实际执行三类动作，除此之外不能控制本应用：
1. 打开：用 select_node 选中并启用用户指定的节点、用 select_profile 选中并启用用户指定的配置（都会落盘保存）。
2. 连接：用 connect 调用应用现有的连接动作启动代理。
3. 推荐节点：先用 list_nodes 取得应用内真实节点数据（名称、地区、类型、已测延迟），再基于这些数据给推荐和理由；用户认可后可接着执行 select_node / connect。

动作铁律（防幻觉，必须遵守）：
- 涉及节点与配置的事实只能来自 list_nodes 的返回；没有延迟数据（latency 为 null）就明说没有测速数据，绝不编造延迟、地区或节点。
- select_node / select_profile 只有唯一匹配时才会真正执行；工具返回多个候选或找不到时，绝不能自行替用户挑选，必须先在对话里向用户问清是哪一个。
- connect 的结果以工具返回为准：工具说未连接，就必须如实告诉用户未连接及原因（例如本版本代理核心尚未接入），绝不能声称已经连接成功。
- 工具执行后，用一句话向用户复述做了什么、结果如何。

能力边界（仍然不能做，必须如实说明）：
- 断开连接、删除配置、修改应用设置、修改分流规则等不在你的工具范围内；用户要求时如实说明做不到，并简要给出手动操作的位置（断开在主界面、设置在设置页、节点在节点列表）。
- 绝不能假装执行了任何没有工具回执的动作。
''';

  static const int kMaxHistoryMessages = 20;

  // Accepts a base URL like "https://api.openai.com/v1" (with or without a
  // trailing slash), or a full ".../chat/completions" URL used as-is.
  static String completionsUrl(String baseUrl) {
    var url = baseUrl.trim();
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    if (url.endsWith('/chat/completions')) {
      return url;
    }
    return '$url/chat/completions';
  }

  // Non-streaming chat completion against the user-configured endpoint.
  // [history] must already include the system prompt as the first message.
  static Future<ReturnResult<String>> chat(
    List<AiChatMessage> history,
  ) async {
    final ai = SettingManager.getConfig().ai;
    final baseUrl = ai.baseUrl.trim();
    final apiKey = ai.apiKey.trim();
    final model = ai.model.trim();
    if (baseUrl.isEmpty || model.isEmpty) {
      return ReturnResult(
        error: ReturnResultError(
          "尚未配置 AI 接口：请先填写接口地址（Base URL）与模型名（设置 → AI 助手设置，或点本页右上角的设置图标）。",
          report: false,
        ),
      );
    }
    final url = completionsUrl(baseUrl);
    final uri = Uri.tryParse(url);
    if (uri == null || !(uri.isScheme("http") || uri.isScheme("https"))) {
      return ReturnResult(
        error: ReturnResultError(
          "接口地址（Base URL）格式不正确：$baseUrl",
          report: false,
        ),
      );
    }

    try {
      final response = await http
          .post(
            uri,
            headers: {
              'Content-Type': 'application/json',
              if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
            },
            body: jsonEncode({
              'model': model,
              'messages': history.map((m) => m.toJson()).toList(),
              'stream': false,
            }),
          )
          .timeout(const Duration(seconds: 120));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        var body = utf8.decode(response.bodyBytes, allowMalformed: true);
        if (body.length > 300) {
          body = body.substring(0, 300);
        }
        return ReturnResult(
          error: ReturnResultError(
            "AI 接口返回错误（HTTP ${response.statusCode}）：$body",
            report: false,
          ),
        );
      }
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is Map<String, dynamic>) {
        final choices = decoded['choices'];
        if (choices is List && choices.isNotEmpty) {
          final message = choices[0]['message'];
          if (message is Map && message['content'] is String) {
            final content = (message['content'] as String).trim();
            if (content.isNotEmpty) {
              return ReturnResult(data: content);
            }
          }
        }
      }
      return ReturnResult(
        error: ReturnResultError(
          "AI 接口返回内容为空或格式不符（需要 OpenAI 兼容的 /chat/completions 接口）。",
          report: false,
        ),
      );
    } on TimeoutException {
      return ReturnResult(
        error: ReturnResultError("请求超时：请检查网络或接口地址后重试。", report: false),
      );
    } catch (err) {
      return ReturnResult(
        error: ReturnResultError("请求失败：${err.toString()}", report: false),
      );
    }
  }

  // Tool-calling conversation: like chat(), but the request carries the
  // restricted tool set (AiAssistantTools) and any tool calls the model
  // makes are executed through [executeTool] and fed back, looping until
  // the model produces a plain-text answer (or the round cap hits).
  // [onToolRecord] receives the human-readable record of each executed
  // action so the UI can post it into the transcript immediately.
  static const int kMaxToolRounds = 5;

  static Future<ReturnResult<String>> chatWithTools(
    List<AiChatMessage> history,
    Future<AiToolOutcome> Function(String name, Map<String, dynamic> args)
    executeTool,
    void Function(String chatRecord) onToolRecord,
  ) async {
    final ai = SettingManager.getConfig().ai;
    final baseUrl = ai.baseUrl.trim();
    final apiKey = ai.apiKey.trim();
    final model = ai.model.trim();
    if (baseUrl.isEmpty || model.isEmpty) {
      return ReturnResult(
        error: ReturnResultError(
          "尚未配置 AI 接口：请先填写接口地址（Base URL）与模型名（设置 → AI 助手设置，或点本页右上角的设置图标）。",
          report: false,
        ),
      );
    }
    final uri = Uri.tryParse(completionsUrl(baseUrl));
    if (uri == null || !(uri.isScheme("http") || uri.isScheme("https"))) {
      return ReturnResult(
        error: ReturnResultError(
          "接口地址（Base URL）格式不正确：$baseUrl",
          report: false,
        ),
      );
    }

    final messages = history
        .map((m) => <String, dynamic>{'role': m.role, 'content': m.content})
        .toList();
    var toolsUsed = false;

    for (var round = 0; round < kMaxToolRounds; round++) {
      final http.Response response;
      try {
        response = await http
            .post(
              uri,
              headers: {
                'Content-Type': 'application/json',
                if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
              },
              body: jsonEncode({
                'model': model,
                'messages': messages,
                'tools': AiAssistantTools.toolDefinitions(),
                'tool_choice': 'auto',
                'stream': false,
              }),
            )
            .timeout(const Duration(seconds: 120));
      } on TimeoutException {
        return ReturnResult(
          error: ReturnResultError("请求超时：请检查网络或接口地址后重试。", report: false),
        );
      } catch (err) {
        return ReturnResult(
          error: ReturnResultError("请求失败：${err.toString()}", report: false),
        );
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        var body = utf8.decode(response.bodyBytes, allowMalformed: true);
        if (body.length > 300) {
          body = body.substring(0, 300);
        }
        return ReturnResult(
          error: ReturnResultError(
            "AI 接口返回错误（HTTP ${response.statusCode}）：$body",
            report: false,
          ),
        );
      }
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      Map<dynamic, dynamic>? message;
      if (decoded is Map<String, dynamic>) {
        final choices = decoded['choices'];
        if (choices is List && choices.isNotEmpty) {
          final m = choices[0]['message'];
          if (m is Map) {
            message = m;
          }
        }
      }
      if (message == null) {
        return ReturnResult(
          error: ReturnResultError(
            "AI 接口返回内容为空或格式不符（需要 OpenAI 兼容的 /chat/completions 接口）。",
            report: false,
          ),
        );
      }
      final toolCalls = message['tool_calls'];
      if (toolCalls is List && toolCalls.isNotEmpty) {
        toolsUsed = true;
        // Echo the assistant's tool-call message back verbatim (the API
        // requires it before the tool results).
        messages.add({
          'role': 'assistant',
          'content': message['content'],
          'tool_calls': toolCalls,
        });
        for (final call in toolCalls) {
          if (call is! Map) {
            continue;
          }
          final id = (call['id'] as String?) ?? '';
          final function = call['function'];
          final name = function is Map
              ? (function['name'] as String?) ?? ''
              : '';
          var args = <String, dynamic>{};
          if (function is Map && function['arguments'] is String) {
            try {
              final parsed = jsonDecode(function['arguments'] as String);
              if (parsed is Map<String, dynamic>) {
                args = parsed;
              }
            } catch (_) {}
          }
          AiToolOutcome outcome;
          try {
            outcome = await executeTool(name, args);
          } catch (err) {
            outcome = AiToolOutcome('工具执行失败：${err.toString()}', '');
          }
          if (outcome.chatRecord.isNotEmpty) {
            onToolRecord(outcome.chatRecord);
          }
          messages.add({
            'role': 'tool',
            'tool_call_id': id,
            'content': outcome.toolResult,
          });
        }
        continue;
      }
      final content = (message['content'] as String?)?.trim() ?? '';
      if (content.isNotEmpty) {
        return ReturnResult(data: content);
      }
      if (toolsUsed) {
        return ReturnResult(data: '已按上方记录执行完毕。');
      }
      return ReturnResult(
        error: ReturnResultError(
          "AI 接口返回内容为空或格式不符（需要 OpenAI 兼容的 /chat/completions 接口）。",
          report: false,
        ),
      );
    }
    return ReturnResult(
      error: ReturnResultError("工具调用轮次过多，已停止本次执行。", report: false),
    );
  }
}
