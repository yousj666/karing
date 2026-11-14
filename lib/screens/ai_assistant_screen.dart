// yousj-plus: built-in AI assistant (BYOK).
//
// The user brings their own OpenAI-compatible endpoint (Base URL + API Key
// + model, configured in settings); this page is a plain chat UI on top of
// AiAssistantUtils. When an assistant reply contains a sing-box JSON or
// Clash YAML config code block, an "import as profile" button under the
// message routes the block through the very same import pipeline as the
// add-profile-by-content screen.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:karing/app/modules/setting_manager.dart';
import 'package:karing/app/utils/ai_assistant_tools.dart';
import 'package:karing/app/utils/ai_assistant_utils.dart';
import 'package:karing/screens/add_profile_by_link_or_content_screen.dart';
import 'package:karing/screens/group_item_creator.dart';
import 'package:karing/screens/group_item_options.dart';
import 'package:karing/screens/group_screen.dart';
import 'package:karing/screens/theme_config.dart';
import 'package:karing/screens/widgets/framework.dart';
import 'package:karing/screens/widgets/text_field.dart';

class AiAssistantConfigEditor {
  // Same GroupScreen-based editor pattern as the WARP / Tailscale settings.
  static Future<void> show(BuildContext context) async {
    final settingConfig = SettingManager.getConfig();
    String baseUrl = settingConfig.ai.baseUrl;
    String apiKey = settingConfig.ai.apiKey;
    String model = settingConfig.ai.model;

    Future<List<GroupItem>> getOptions(
      BuildContext context,
      SetStateCallback? setstate,
    ) async {
      return [
        GroupItem(
          options: [
            GroupItemOptions(
              textFormFieldOptions: GroupItemTextFieldOptions(
                name: "接口地址 (Base URL)",
                text: baseUrl,
                hint: "https://api.openai.com/v1",
                textWidthPercent: 0.55,
                onChanged: (String value) {
                  baseUrl = value.trim();
                },
              ),
            ),
            GroupItemOptions(
              textFormFieldOptions: GroupItemTextFieldOptions(
                name: "API Key",
                text: apiKey,
                obscureText: true,
                textWidthPercent: 0.55,
                onChanged: (String value) {
                  apiKey = value.trim();
                },
              ),
            ),
            GroupItemOptions(
              textFormFieldOptions: GroupItemTextFieldOptions(
                name: "模型名",
                text: model,
                hint: "gpt-4o-mini",
                textWidthPercent: 0.55,
                onChanged: (String value) {
                  model = value.trim();
                },
              ),
            ),
          ],
        ),
      ];
    }

    await Navigator.push(
      context,
      MaterialPageRoute(
        settings: GroupScreen.routeSettings("AiAssistant"),
        builder: (context) => GroupScreen(
          title: "AI 助手设置",
          getOptions: getOptions,
          onDone: (BuildContext context, SetStateCallback? setstate) async {
            settingConfig.ai.baseUrl = baseUrl;
            settingConfig.ai.apiKey = apiKey;
            settingConfig.ai.model = model;
            SettingManager.setDirty(true);
            await SettingManager.save();
            return true;
          },
        ),
      ),
    );
  }
}

class _ChatEntry {
  final bool isUser;
  final bool isError;
  // localOnly entries (welcome text, errors) are never sent to the API.
  final bool localOnly;
  final String text;
  const _ChatEntry({
    required this.isUser,
    required this.text,
    this.isError = false,
    this.localOnly = false,
  });
}

class AiAssistantScreen extends LasyRenderingStatefulWidget {
  static RouteSettings routeSettings() {
    return const RouteSettings(name: "AiAssistantScreen");
  }

  const AiAssistantScreen({super.key});

  @override
  State<AiAssistantScreen> createState() => _AiAssistantScreenState();
}

class _AiAssistantScreenState extends LasyRenderingState<AiAssistantScreen> {
  static final RegExp _codeBlockPattern = RegExp(
    r'```([a-zA-Z0-9_+-]*)\n([\s\S]*?)```',
  );

  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final List<_ChatEntry> _entries = [];
  bool _sending = false;

  static const _ChatEntry _welcomeEntry = _ChatEntry(
    isUser: false,
    localOnly: true,
    text:
        "我是内置 AI 助手，懂 sing-box 与 Clash 配置和分流规则。\n"
        "你可以让我帮你生成、修改或讲解配置；我生成的完整配置可以直接一键导入为配置。\n"
        "现在我还能替你做三件事：选中节点/配置、发起连接、按真实延迟数据推荐节点。连接结果以应用的真实状态为准，我不会假报已连接。\n"
        "断开、删除、改设置这类操作我仍然做不了，会告诉你去哪里手动操作。",
  );

  @override
  void initState() {
    super.initState();
    _entries.add(_welcomeEntry);
  }

  @override
  void dispose() {
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  bool get _isConfigured => SettingManager.getConfig().ai.isConfigured;

  static bool _looksLikeConfig(String code) {
    if (code.isEmpty) {
      return false;
    }
    if (code.startsWith('{')) {
      try {
        final decoded = jsonDecode(code);
        if (decoded is Map<String, dynamic>) {
          return decoded.containsKey('outbounds') ||
              decoded.containsKey('inbounds');
        }
      } catch (_) {}
      return false;
    }
    return code.contains('proxies:') || code.contains('proxy-groups:');
  }

  static List<String> _extractConfigs(String text) {
    final configs = <String>[];
    for (final match in _codeBlockPattern.allMatches(text)) {
      final code = (match.group(2) ?? '').trim();
      if (_looksLikeConfig(code)) {
        configs.add(code);
      }
    }
    return configs;
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _onSend() async {
    final text = _inputController.text.trim();
    if (text.isEmpty || _sending) {
      return;
    }
    _inputController.clear();
    setState(() {
      _entries.add(_ChatEntry(isUser: true, text: text));
      _sending = true;
    });
    _scrollToBottom();

    final history = <AiChatMessage>[
      const AiChatMessage('system', AiAssistantUtils.kSystemPrompt),
    ];
    final turns = _entries
        .where((e) => !e.isError && !e.localOnly)
        .toList();
    final start =
        turns.length > AiAssistantUtils.kMaxHistoryMessages
            ? turns.length - AiAssistantUtils.kMaxHistoryMessages
            : 0;
    for (var i = start; i < turns.length; i++) {
      history.add(
        AiChatMessage(turns[i].isUser ? 'user' : 'assistant', turns[i].text),
      );
    }

    final result = await AiAssistantUtils.chatWithTools(
      history,
      AiAssistantTools.execute,
      (record) {
        // Post the record of each executed action into the transcript as
        // it happens, so the user sees exactly what was done even before
        // the assistant's summary arrives. localOnly: the record is a UI
        // receipt, not something to feed back as conversation.
        if (!mounted) {
          return;
        }
        setState(() {
          _entries.add(
            _ChatEntry(isUser: false, localOnly: true, text: record),
          );
        });
        _scrollToBottom();
      },
    );
    if (!mounted) {
      return;
    }
    setState(() {
      _sending = false;
      if (result.error != null) {
        _entries.add(
          _ChatEntry(
            isUser: false,
            isError: true,
            localOnly: true,
            text: result.error!.message,
          ),
        );
      } else {
        _entries.add(
          _ChatEntry(isUser: false, text: (result.data ?? '').trim()),
        );
      }
    });
    _scrollToBottom();
  }

  Future<void> _onImportConfig(String code) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        settings: AddProfileByLinkOrContentScreen.routeSettings(),
        builder: (context) => AddProfileByLinkOrContentScreen(
          urlOrContent: code,
          name: "AI 助手生成配置",
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Size windowSize = MediaQuery.of(context).size;
    return Scaffold(
      appBar: PreferredSize(preferredSize: Size.zero, child: AppBar()),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(0, 20, 0, 0),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  InkWell(
                    onTap: () => Navigator.pop(context),
                    child: const SizedBox(
                      width: 50,
                      height: 30,
                      child: Icon(Icons.arrow_back_ios_outlined, size: 26),
                    ),
                  ),
                  SizedBox(
                    width: windowSize.width - 50 * 3,
                    child: const Text(
                      "AI 助手",
                      textAlign: TextAlign.center,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: ThemeConfig.kFontWeightTitle,
                        fontSize: ThemeConfig.kFontSizeTitle,
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      InkWell(
                        onTap: () async {
                          await AiAssistantConfigEditor.show(context);
                          if (mounted) {
                            setState(() {});
                          }
                        },
                        child: const SizedBox(
                          width: 50,
                          height: 30,
                          child: Icon(Icons.settings_outlined, size: 26),
                        ),
                      ),
                      InkWell(
                        onTap: _sending
                            ? null
                            : () {
                                setState(() {
                                  _entries
                                    ..clear()
                                    ..add(_welcomeEntry);
                                });
                              },
                        child: const SizedBox(
                          width: 50,
                          height: 30,
                          child: Icon(Icons.delete_outline, size: 26),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 10),
              if (!_isConfigured) ...[
                InkWell(
                  onTap: () async {
                    await AiAssistantConfigEditor.show(context);
                    if (mounted) {
                      setState(() {});
                    }
                  },
                  child: Container(
                    width: double.infinity,
                    color: theme.colorScheme.errorContainer,
                    padding: const EdgeInsets.fromLTRB(18, 10, 18, 10),
                    child: Text(
                      "尚未配置 AI 接口（Base URL / API Key / 模型名），点此填写后即可使用。",
                      style: TextStyle(
                        color: theme.colorScheme.onErrorContainer,
                      ),
                    ),
                  ),
                ),
              ],
              Expanded(
                child: ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.fromLTRB(18, 10, 18, 10),
                  itemCount: _entries.length + (_sending ? 1 : 0),
                  itemBuilder: (context, index) {
                    if (index >= _entries.length) {
                      return const Padding(
                        padding: EdgeInsets.symmetric(vertical: 12),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 20,
                              height: 20,
                              child: RepaintBoundary(
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            ),
                            SizedBox(width: 10),
                            Text("AI 正在思考…"),
                          ],
                        ),
                      );
                    }
                    return _buildEntry(context, _entries[index]);
                  },
                ),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: TextFieldEx(
                        controller: _inputController,
                        maxLines: 4,
                        minLines: 1,
                        textInputAction: TextInputAction.newline,
                        decoration: const InputDecoration(
                          hintText: "输入问题，例如：帮我写一份 sing-box 配置",
                          border: OutlineInputBorder(),
                          contentPadding: EdgeInsets.fromLTRB(12, 10, 12, 10),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      onPressed: _sending ? null : _onSend,
                      icon: const Icon(Icons.send, size: 26),
                      tooltip: "发送",
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEntry(BuildContext context, _ChatEntry entry) {
    final theme = Theme.of(context);
    final Color background;
    final Color foreground;
    if (entry.isError) {
      background = theme.colorScheme.errorContainer;
      foreground = theme.colorScheme.onErrorContainer;
    } else if (entry.isUser) {
      background = theme.colorScheme.primaryContainer;
      foreground = theme.colorScheme.onPrimaryContainer;
    } else {
      background = theme.colorScheme.surfaceContainerHighest;
      foreground = theme.colorScheme.onSurface;
    }
    final configs = entry.isUser ? const <String>[] : _extractConfigs(
      entry.text,
    );
    return Align(
      alignment: entry.isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.85,
        ),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(
              entry.text,
              style: TextStyle(color: foreground, fontSize: 15),
            ),
            for (final code in configs) ...[
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: () async {
                  await _onImportConfig(code);
                },
                icon: const Icon(Icons.download_outlined, size: 18),
                label: const Text("导入为配置"),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
