// yousj-plus (v1.0.7): "AI 接入指令" — a ready-made instruction text
// generated live from the current settings (addresses, tunnel config,
// access token), which the user copies and pastes to any external AI
// program; the AI can then connect to this app's external API exactly
// as described, with no further setup conversation.
//
// The text is rebuilt from the live config every time this page is
// opened (and on the refresh action), so a reset token or a changed
// tunnel address/port is reflected immediately — nothing is a stored
// snapshot. The token appears in this text on purpose (that is the
// page's whole point); it is still never written to any log.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:karing/app/modules/setting_manager.dart';
import 'package:karing/app/utils/external_api_service.dart';

class ExternalApiGuideScreen extends StatefulWidget {
const ExternalApiGuideScreen({super.key});

@override
State<ExternalApiGuideScreen> createState() => _ExternalApiGuideScreenState();
}

class _ExternalApiGuideScreenState extends State<ExternalApiGuideScreen> {
String _text = '';
bool _loading = true;

@override
void initState() {
super.initState();
_generate();
}

Future<void> _generate() async {
final api = SettingManager.getConfig().externalApi;
final lanUrl = await ExternalApiService.currentUrl();
if (!mounted) {
return;
}
setState(() {
_text = _buildText(api, lanUrl);
_loading = false;
});
}

String _buildText(SettingConfigItemExternalApi api, String lanUrl) {
final token = api.token.isEmpty
? '（尚未生成：请先开启「外部 AI 接口」，令牌会自动生成）'
: api.token;
final tunnelConfigured = api.tunnelServerAddr.trim().isNotEmpty;
final publicUrl = 'http://${api.tunnelServerAddr}:${api.tunnelRemotePort}';
final publicLine = tunnelConfigured
? '- 公网地址：$publicUrl（经外网通道，通道已连接时可用）'
: '- 公网地址：外网通道未配置，仅可使用局域网/本机地址';
final exampleBase = tunnelConfigured ? publicUrl : lanUrl;
final lanLine = api.allowLan
? '- 局域网地址：$lanUrl（与手机同一局域网时用）'
: '- 局域网地址：未开启（设置里开启「允许局域网访问」后可用）';
return '''你正在连接我手机上的 Yousj Enhanced（代理应用）的「外部 AI 接口」。通过下面的 HTTP 接口，你可以查看它的状态、管理代理配置，并在授权范围内在手机的 Termux 里执行命令。

（按顺序试能通的那个）
$publicLine
$lanLine
- 本机地址：http://127.0.0.1:18777（在手机本机上调用时用）


$token
鉴权方式：除 health 外，所有请求都要带请求头 Authorization: Bearer <令牌>，或 X-API-Key: <令牌>。返回是 JSON：{ok: true, data: {...}} 或 {ok: false, error: "...", code: "..."}。

（<地址> = 上面任一能通的地址）
- GET <地址>/api/v1/health — 健康检查，免令牌。返回应用名、版本、API 版本。
- GET <地址>/api/v1/status — 当前状态：选中的配置、启用中的配置列表、代理运行状态（代理核心未集成时 proxy_running 为 false，这是如实报告，不要当成接口故障）。
- GET <地址>/api/v1/profiles — 配置列表（id、名称、类型、来源、节点数、是否选中）。
- POST <地址>/api/v1/profiles/select — 切换当前配置。Body: {"id": "<配置 id>"}。只是改选中状态，不会启动连接。
- POST <地址>/api/v1/profiles/import — 导入新配置。Body: {"content": "<sing-box JSON 或 Clash YAML 原文>", "remark": "备注名"}。走应用自己的导入管线（Clash 会自动转换）。
- GET <地址>/api/v1/settings/ai — 读取内置 AI 助手设置（只返回是否已设 Key，不返回 Key 明文）。
- PUT <地址>/api/v1/settings/ai — 修改内置 AI 助手设置。Body 可只带要改的字段：{"baseUrl": "https://.../v1", "apiKey": "...", "model": "..."}。
- GET <地址>/api/v1/termux/status — Termux 执行通道状态（installed / permission_granted / ready）。需要「允许执行 Termux 指令」子开关已开启，否则回 403。
- POST <地址>/api/v1/termux/exec — 在手机 Termux 里执行命令。Body: {"command": "uname -a", "timeout": 30}。命令以 Termux 用户身份运行（不是 root，也不是 Android 系统 shell）；timeout 默认 30 秒、最大 120 秒；stdout/stderr 各最多返回 64KB（超出截断并标 truncated）；同一时刻只执行一条，忙时回 429，稍等重试即可。返回 exit_code、stdout、stderr、timed_out。
- GET <地址>/api/v1/logs — 本接口的访问日志（最近 200 条，含来源、路径、状态与令牌校验结果）。


curl -H "Authorization: Bearer $token" $exampleBase/api/v1/status
curl -X POST -H "Authorization: Bearer $token" -H "Content-Type: application/json" -d '{"command":"ls ~","timeout":30}' $exampleBase/api/v1/termux/exec


1. 动手之前先调 /api/v1/status 和 /api/v1/termux/status，把当前状态摸清再行动。
2. 要加新配置用 /api/v1/profiles/import 导入，不要试图改写或删除已有配置（接口也没有这些功能）。
3. 执行命令先短后长：先跑简单命令确认通道通，再逐步做事；每步都看 exit_code 和输出，失败先看 error/code 说明，不要盲目重试。''';
}

Future<void> _copyAll() async {
await Clipboard.setData(ClipboardData(text: _text));
if (!mounted) {
return;
}
ScaffoldMessenger.of(context).showSnackBar(
const SnackBar(content: Text("接入指令已复制，去粘贴给外部 AI 吧")),
);
}

@override
Widget build(BuildContext context) {
return Scaffold(
appBar: AppBar(
title: const Text("AI 接入指令"),
actions: [
IconButton(
icon: const Icon(Icons.refresh),
tooltip: "按当前设置重新生成",
onPressed: _generate,
),
],
),
body: _loading
? const Center(child: CircularProgressIndicator())
: SafeArea(
child: Column(
children: [
Expanded(
child: SingleChildScrollView(
padding: const EdgeInsets.all(16),
child: SelectableText(_text),
),
),
Padding(
padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
child: SizedBox(
width: double.infinity,
child: FilledButton.icon(
icon: const Icon(Icons.copy),
label: const Text("复制全部"),
onPressed: _copyAll,
),
),
),
],
),
),
);
}
}
