// yousj-plus: settings editor for the external AI API.
//
// Same GroupScreen-based editor pattern as AiAssistantConfigEditor, with
// one difference: every change applies immediately (settings saved and
// ExternalApiService re-applied), because the HTTP service must start and
// stop with its switch, not when the page is closed. The access token is
// only ever shown masked; tapping the token row copies the full token to
// the clipboard for the user to paste into their external AI program.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:karing/app/modules/setting_manager.dart';
import 'package:karing/app/utils/external_api_service.dart';
import 'package:karing/screens/group_item_creator.dart';
import 'package:karing/screens/group_item_options.dart';
import 'package:karing/screens/group_screen.dart';

class ExternalApiConfigEditor {
  static Future<void> show(BuildContext context) async {
    final settingConfig = SettingManager.getConfig();

    Future<void> persist() async {
      SettingManager.setDirty(true);
      await SettingManager.save();
    }

    Future<List<GroupItem>> getOptions(
      BuildContext context,
      SetStateCallback? setstate,
    ) async {
      final api = settingConfig.externalApi;
      final options = <GroupItemOptions>[
        GroupItemOptions(
          switchOptions: GroupItemSwitchOptions(
            name: "启用外部 AI 接口",
            tips: "开启后，本应用会开放一个带令牌校验的 HTTP 接口，供外部 AI 程序连接。接口随应用进程存活。",
            switchValue: api.enable,
            onSwitch: (bool value) async {
              api.enable = value;
              if (value && api.token.isEmpty) {
                api.token = SettingConfigItemExternalApi.generateToken();
              }
              await persist();
              await ExternalApiService.applyFromConfig();
            },
          ),
        ),
      ];
      // The remaining items only make sense while the API is enabled;
      // while it is off they are not shown (the settings framework has no
      // per-item disabled state).
      if (api.enable) {
        options.add(
          GroupItemOptions(
            textOptions: GroupItemTextOptions(
              name: "访问令牌",
              text: api.maskedToken,
              tips: "点按复制完整令牌。外部 AI 连接时需在请求头携带此令牌。",
              onPush: () async {
                await Clipboard.setData(ClipboardData(text: api.token));
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text("访问令牌已复制到剪贴板")),
                  );
                }
              },
            ),
          ),
        );
        options.add(
          GroupItemOptions(
            pushOptions: GroupItemPushOptions(
              name: "重置访问令牌",
              onPush: () async {
                api.token = SettingConfigItemExternalApi.generateToken();
                await persist();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text("访问令牌已重置，旧令牌立即失效")),
                  );
                }
              },
            ),
          ),
        );
        options.add(
          GroupItemOptions(
            switchOptions: GroupItemSwitchOptions(
              name: "允许局域网访问",
              tips: "默认仅本机（127.0.0.1）可连接。开启后将监听所有网卡，同一局域网内的设备也能连接（仍需令牌校验）。仅在可信网络中开启。",
              switchValue: api.allowLan,
              onSwitch: (bool value) async {
                api.allowLan = value;
                await persist();
                await ExternalApiService.applyFromConfig();
              },
            ),
          ),
        );
        final url = await ExternalApiService.currentUrl();
        options.add(
          GroupItemOptions(
            textOptions: GroupItemTextOptions(
              name: "连接地址",
              text: ExternalApiService.isRunning ? url : "服务未运行",
            ),
          ),
        );
        final startError = ExternalApiService.startError;
        if (!ExternalApiService.isRunning && startError != null) {
          options.add(
            GroupItemOptions(
              textOptions: GroupItemTextOptions(
                name: "状态",
                text: startError.length > 60
                    ? "启动失败：${startError.substring(0, 60)}…"
                    : "启动失败：$startError",
              ),
            ),
          );
        }
      }
      options.add(
        GroupItemOptions(
          textOptions: GroupItemTextOptions(
            name: "说明",
            text: "外部 AI（如电脑上的智能体）可用此地址 + 令牌连接本应用。",
            textWidthPercent: 0.62,
          ),
        ),
      );
      return [GroupItem(options: options)];
    }

    await Navigator.push(
      context,
      MaterialPageRoute(
        settings: GroupScreen.routeSettings("ExternalApi"),
        builder: (context) => GroupScreen(
          title: "外部 AI 接口",
          getOptions: getOptions,
          onDone: (BuildContext context, SetStateCallback? setstate) async {
            await persist();
            await ExternalApiService.applyFromConfig();
            return true;
          },
        ),
      ),
    );
  }
}
