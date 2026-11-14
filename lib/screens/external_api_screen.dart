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
import 'package:karing/app/utils/frpc_tunnel_service.dart';
import 'package:karing/screens/external_api_guide_screen.dart';
import 'package:karing/screens/external_api_logs_screen.dart';
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

    // Tunnel text fields edit local copies (the GroupScreen text-field
    // pattern used across the app); they are written back into the
    // config by syncTunnelFields() before every persist that must take
    // effect immediately, and when the page is done.
    final api0 = settingConfig.externalApi;
    String tunnelServerAddr = api0.tunnelServerAddr;
    // Port 0 means "not set" (v1.0.8): the field starts empty and only
    // shows the grey example hint, never a pre-filled example value.
    String tunnelServerPortText = api0.tunnelServerPort == 0
        ? ""
        : api0.tunnelServerPort.toString();
    String tunnelRemotePortText = api0.tunnelRemotePort == 0
        ? ""
        : api0.tunnelRemotePort.toString();
    String tunnelToken = api0.tunnelToken;

    Future<void> syncTunnelFields() async {
      final api = settingConfig.externalApi;
      api.tunnelServerAddr = tunnelServerAddr.trim();
      // Empty (or unparseable) input saves back as 0 = unset, so
      // clearing a field really un-configures it instead of silently
      // keeping the previous value.
      api.tunnelServerPort = int.tryParse(tunnelServerPortText.trim()) ?? 0;
      api.tunnelRemotePort = int.tryParse(tunnelRemotePortText.trim()) ?? 0;
      api.tunnelToken = tunnelToken.trim();
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
              name: "允许执行 Termux 指令",
              tips: "开启后，带令牌的调用方可在 Termux 里执行任意命令（以 Termux 的用户身份运行）。风险很高：拿到令牌的一方等于拿到一个完整的 Termux 终端。不用时请保持关闭。",
              switchValue: api.allowTermuxExec,
              onSwitch: (bool value) async {
                api.allowTermuxExec = value;
                await persist();
              },
            ),
          ),
        );
        options.add(
          GroupItemOptions(
            switchOptions: GroupItemSwitchOptions(
              name: "允许局域网访问",
              tips: "开启后将监听所有网卡，同一局域网内的设备也能连接（仍需令牌校验）；关闭后仅本机（127.0.0.1）可连接。仅在可信网络中开启。",
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
          pushOptions: GroupItemPushOptions(
            name: "AI 接入指令",
            text: "一键复制",
            tips: "按当前设置（地址、通道、令牌）实时生成一整段现成指令，粘贴给任何外部 AI，它照着就能连进来。",
            onPush: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const ExternalApiGuideScreen(),
                ),
              );
            },
          ),
        ),
      );
      options.add(
        GroupItemOptions(
          pushOptions: GroupItemPushOptions(
            name: "接口日志",
            text: "最近 200 条",
            tips: "记录每次接口访问的时间、来源、路径、结果与令牌校验情况（不记令牌与命令全文）。",
            onPush: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const ExternalApiLogsScreen(),
                ),
              );
            },
          ),
        ),
      );
      options.add(
        GroupItemOptions(
          textOptions: GroupItemTextOptions(
            name: "说明",
            text:
                "外部 AI（如电脑上的智能体）可用此地址 + 令牌连接本应用。"
                "在下面「外网通道」里填上你自己的 frps 服务器并保存后，通道会自动创建，"
                "外部也可通过 http://服务器地址:远程端口 访问本机接口（仍需接口令牌）；"
                "通道未配置时仅可使用局域网/本机地址。",
            textWidthPercent: 0.62,
          ),
        ),
      );

      // --- second group: the built-in reverse tunnel (frpc) ---
      final tunnelStatus = await FrpcTunnelService.status();
      final tunnelOptions = <GroupItemOptions>[
        GroupItemOptions(
          switchOptions: GroupItemSwitchOptions(
            name: "启用外网通道",
            tips: "开启后自动经 frps 服务器创建反向隧道，手机在 NAT 后面时外部 AI 也能从外网连进本机接口（仍需接口令牌）。外部 AI 接口关闭时，通道自动停用。通道随应用进程存活，应用被系统杀掉即断开。",
            switchValue: api.tunnelEnable,
            onSwitch: (bool value) async {
              api.tunnelEnable = value;
              await syncTunnelFields();
              await persist();
              await FrpcTunnelService.applyFromConfig();
            },
          ),
        ),
      ];
      if (api.tunnelEnable) {
        tunnelOptions.add(
          GroupItemOptions(
            textFormFieldOptions: GroupItemTextFieldOptions(
              name: "服务器地址",
              text: tunnelServerAddr,
              hint: "frps 服务器 IP 或域名",
              textWidthPercent: 0.55,
              onChanged: (String value) {
                tunnelServerAddr = value;
              },
            ),
          ),
        );
        tunnelOptions.add(
          GroupItemOptions(
            textFormFieldOptions: GroupItemTextFieldOptions(
              name: "服务器端口",
              text: tunnelServerPortText,
              hint: "例如 7000（frps 的 bindPort）",
              keyboardType: TextInputType.number,
              textWidthPercent: 0.55,
              onChanged: (String value) {
                tunnelServerPortText = value;
              },
            ),
          ),
        );
        tunnelOptions.add(
          GroupItemOptions(
            textFormFieldOptions: GroupItemTextFieldOptions(
              name: "远程端口",
              text: tunnelRemotePortText,
              hint: "例如 18777（映射到服务器上的端口）",
              keyboardType: TextInputType.number,
              textWidthPercent: 0.55,
              onChanged: (String value) {
                tunnelRemotePortText = value;
              },
            ),
          ),
        );
        tunnelOptions.add(
          GroupItemOptions(
            textFormFieldOptions: GroupItemTextFieldOptions(
              name: "通道令牌",
              text: tunnelToken,
              obscureText: true,
              tips: "与 frps 的 auth.token 一致（当前 ${api.tunnelToken.isEmpty ? "未设置" : api.maskedTunnelToken}）。改动在点页面右上角完成或切换开关后生效，通道会自动重连。",
              textWidthPercent: 0.55,
              onChanged: (String value) {
                tunnelToken = value;
              },
            ),
          ),
        );
      }
      tunnelOptions.add(
        GroupItemOptions(
          textOptions: GroupItemTextOptions(
            name: "通道状态",
            text: (tunnelStatus['detail'] as String?) ?? '',
          ),
        ),
      );
      tunnelOptions.add(
        GroupItemOptions(
          textOptions: GroupItemTextOptions(
            name: "说明",
            text:
                "自带服务器：在你的服务器上运行 frps，最简 frps.toml 示例：\n"
                "bindPort = 7000\n"
                "auth.method = \"token\"\n"
                "auth.token = \"与上面的通道令牌一致\"\n"
                "并在服务器防火墙放行 bindPort 与远程端口两个端口。\n"
                "安全提醒：通道开启等于把本机接口暴露到服务器的公网端口（靠接口令牌把关），远程端口不要与他人共用，通道令牌务必设置且不要外传。",
            textWidthPercent: 0.62,
          ),
        ),
      );
      return [GroupItem(options: options), GroupItem(options: tunnelOptions)];
    }

    await Navigator.push(
      context,
      MaterialPageRoute(
        settings: GroupScreen.routeSettings("ExternalApi"),
        builder: (context) => GroupScreen(
          title: "外部 AI 接口",
          getOptions: getOptions,
          onDone: (BuildContext context, SetStateCallback? setstate) async {
            await syncTunnelFields();
            await persist();
            await ExternalApiService.applyFromConfig();
            return true;
          },
        ),
      ),
    );
  }
}
