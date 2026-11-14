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

能力边界（必须如实说明，绝不能假装已经执行）：
- 你目前不能直接控制本应用：不能替用户连接或断开代理、不能切换节点，这类「AI 直接控制连接」的能力即将推出。
- 若用户要求你连接、断开或切换节点，请如实说明该能力即将推出，并简要告诉用户手动操作的位置（在应用主界面连接、在节点列表中选择节点）。
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
}
