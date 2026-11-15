// yousj-plus (v1.1.0): settings page for the self-developed mesh network.
//
// Same GroupScreen editor pattern as ExternalApiConfigEditor. All mesh
// operations go through MeshService (control plane only — see its header
// for the honest data-plane status). The coordinator address is NOT
// preset (v1.0.8 rule): it starts empty and the user fills in their own
// yousj-meshd address.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:karing/app/modules/setting_manager.dart';
import 'package:karing/app/utils/mesh_service.dart';
import 'package:karing/screens/group_item_creator.dart';
import 'package:karing/screens/group_item_options.dart';
import 'package:karing/screens/group_screen.dart';

class MeshConfigEditor {
  static Future<String?> _askText(
    BuildContext context,
    String title,
    String hint, {
    String initial = '',
    int maxLines = 1,
  }) async {
    final controller = TextEditingController(text: initial);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          decoration: InputDecoration(hintText: hint),
          maxLines: maxLines,
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    controller.dispose();
    return result;
  }

  static Future<bool> _confirm(BuildContext context, String title, String body) async {
    final r = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认'),
          ),
        ],
      ),
    );
    return r ?? false;
  }

  static Future<void> _showText(
    BuildContext context,
    String title,
    String text,
  ) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: SelectableText(text)),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: text));
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('复制全部'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  static void _snack(BuildContext context, String msg) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  static Future<void> show(BuildContext context) async {
    final settingConfig = SettingManager.getConfig();
    String coordinatorUrl = settingConfig.mesh.coordinatorUrl;
    String deviceName = settingConfig.mesh.deviceName;

    Future<void> persist() async {
      final mesh = settingConfig.mesh;
      mesh.coordinatorUrl = coordinatorUrl.trim();
      mesh.deviceName = deviceName.trim();
      SettingManager.setDirty(true);
      await SettingManager.save();
    }

    String effectiveDeviceName() =>
        deviceName.trim().isNotEmpty ? deviceName.trim() : '我的手机';

    Future<List<GroupItem>> getOptions(
      BuildContext context,
      SetStateCallback? setstate,
    ) async {
      final mesh = settingConfig.mesh;
      final options = <GroupItemOptions>[
        GroupItemOptions(
          switchOptions: GroupItemSwitchOptions(
            name: "启用组网",
            tips: "自研组网：同一网络内的手机与电脑以虚拟 IP 互通，可选一台成员作上网出口。协调服务需自建（yousj-meshd），地址在下方填写、不预置。",
            switchValue: mesh.enable,
            onSwitch: (bool value) async {
              mesh.enable = value;
              await persist();
              MeshService.applyFromConfig();
            },
          ),
        ),
      ];
      if (mesh.enable) {
        options.add(
          GroupItemOptions(
            textFormFieldOptions: GroupItemTextFieldOptions(
              name: "协调服务器地址",
              text: coordinatorUrl,
              hint: "例如 https://你的服务器:18790",
              textWidthPercent: 0.55,
              onChanged: (String value) {
                coordinatorUrl = value;
              },
            ),
          ),
        );
        options.add(
          GroupItemOptions(
            textFormFieldOptions: GroupItemTextFieldOptions(
              name: "本机设备名",
              text: deviceName,
              hint: "例如 我的手机",
              textWidthPercent: 0.55,
              onChanged: (String value) {
                deviceName = value;
              },
            ),
          ),
        );
        options.add(
          GroupItemOptions(
            textOptions: GroupItemTextOptions(
              name: "本机设备 ID",
              text: await MeshService.deviceId(),
              tips: "由本机身份公钥派生，点按复制。",
              onPush: () async {
                await Clipboard.setData(
                  ClipboardData(text: await MeshService.deviceId()),
                );
                _snack(context, "设备 ID 已复制");
              },
            ),
          ),
        );
      }

      final groups = <GroupItem>[GroupItem(options: options)];
      if (!mesh.enable) {
        return groups;
      }

      // ---- networks ----
      final nets = await MeshService.networks();
      final netOptions = <GroupItemOptions>[];
      for (final n in nets) {
        final isActive = n.id == mesh.activeNetworkId;
        netOptions.add(
          GroupItemOptions(
            textOptions: GroupItemTextOptions(
              name: n.name.isEmpty ? n.id : n.name,
              text: "${isActive ? '当前 · ' : ''}${n.vip}",
              tips: isActive ? "当前激活的网络" : "点按切换为当前网络（同时只激活一个）",
              onPush: () async {
                mesh.activeNetworkId = n.id;
                await persist();
                setstate?.call();
              },
            ),
          ),
        );
      }
      netOptions.add(
        GroupItemOptions(
          pushOptions: GroupItemPushOptions(
            name: "创建网络",
            onPush: () async {
              if (coordinatorUrl.trim().isEmpty) {
                _snack(context, "先填协调服务器地址并点右上角保存");
                return;
              }
              final name = await _askText(context, "创建网络", "网络名称");
              if (name == null || name.isEmpty) return;
              try {
                await persist();
                final n = await MeshService.createNetwork(
                  coordinatorUrl.trim(),
                  name,
                  effectiveDeviceName(),
                );
                _snack(context, "已创建并加入「${n.name}」，我的虚拟 IP：${n.vip}");
              } catch (e) {
                _snack(context, "创建失败：$e");
              }
              setstate?.call();
            },
          ),
        ),
      );
      netOptions.add(
        GroupItemOptions(
          pushOptions: GroupItemPushOptions(
            name: "加入网络",
            onPush: () async {
              final payload = await _askText(
                context,
                "加入网络",
                "粘贴邀请内容（yousjmesh://join?d=…）",
                maxLines: 3,
              );
              if (payload == null || payload.isEmpty) return;
              try {
                await persist();
                final n = await MeshService.join(payload, effectiveDeviceName());
                _snack(context, "已加入「${n.name}」，我的虚拟 IP：${n.vip}");
              } catch (e) {
                _snack(context, "加入失败：$e");
              }
              setstate?.call();
            },
          ),
        ),
      );
      groups.add(GroupItem(options: netOptions));

      // ---- active network detail ----
      final active = await MeshService.activeNetwork();
      if (active != null) {
        final detail = <GroupItemOptions>[];
        detail.add(
          GroupItemOptions(
            textOptions: GroupItemTextOptions(
              name: "我的虚拟 IP",
              text: active.vip,
              tips: "同网设备用这个地址访问本机（如外部 AI 接口 http://${active.vip}:18777）。点按复制。",
              onPush: () async {
                await Clipboard.setData(ClipboardData(text: active.vip));
                _snack(context, "已复制");
              },
            ),
          ),
        );
        if (active.adminToken.isNotEmpty) {
          detail.add(
            GroupItemOptions(
              pushOptions: GroupItemPushOptions(
                name: "生成邀请",
                onPush: () async {
                  try {
                    final payload = await MeshService.createInvite(active);
                    if (context.mounted) {
                      await _showText(context, "邀请内容（24 小时、一次性）", payload);
                    }
                  } catch (e) {
                    _snack(context, "生成邀请失败：$e");
                  }
                },
              ),
            ),
          );
        }
        detail.add(
          GroupItemOptions(
            pushOptions: GroupItemPushOptions(
              name: "刷新成员列表",
              onPush: () async {
                try {
                  await MeshService.refreshMembers(active);
                  _snack(context, "已刷新");
                } catch (e) {
                  _snack(context, "刷新失败：$e");
                }
                setstate?.call();
              },
            ),
          ),
        );
        for (final m in active.members) {
          final self = m.deviceId == active.deviceId;
          final badges = <String>[
            if (m.online) "在线" else "离线",
            if (m.exitOffering) "出口中",
            if (active.exitChoice == m.deviceId) "我的出口",
          ].join(" · ");
          detail.add(
            GroupItemOptions(
              textOptions: GroupItemTextOptions(
                name: "${m.name}${self ? '（本机）' : ''}",
                text: "${m.vip} · $badges",
                tips: self
                    ? null
                    : "SSH/SFTP：在电脑或 Termux 里连 ${m.vip}:2222（组网身份密钥即 SSH 密钥）。",
              ),
            ),
          );
        }
        detail.add(
          GroupItemOptions(
            switchOptions: GroupItemSwitchOptions(
              name: "我可作出口",
              tips: "声明本机具备出口能力。手机作出口的实际转发要等隧道核心接通后生效；电脑作出口已可用。",
              switchValue: active.exitCapable,
              onSwitch: (bool value) async {
                active.exitCapable = value;
                if (!value) active.exitOffering = false;
                await MeshService.heartbeat(active);
                setstate?.call();
              },
            ),
          ),
        );
        if (active.exitCapable) {
          detail.add(
            GroupItemOptions(
              switchOptions: GroupItemSwitchOptions(
                name: "我正在提供出口",
                tips: "打开后，同网成员可选择经本机上网。手机端转发待核心接通后生效。",
                switchValue: active.exitOffering,
                onSwitch: (bool value) async {
                  active.exitOffering = value;
                  await MeshService.heartbeat(active);
                  setstate?.call();
                },
              ),
            ),
          );
        }
        detail.add(
          GroupItemOptions(
            pushOptions: GroupItemPushOptions(
              name: "选择我的出口",
              text: active.exitChoice.isEmpty
                  ? "无（本地直连）"
                  : active.exitChoice,
              onPush: () async {
                final offering = active.members
                    .where((m) => m.exitOffering && m.deviceId != active.deviceId)
                    .toList();
                if (offering.isEmpty) {
                  _snack(context, "当前没有成员在提供出口");
                  return;
                }
                final picked = await showDialog<String>(
                  context: context,
                  builder: (ctx) => SimpleDialog(
                    title: const Text("选择出口"),
                    children: [
                      SimpleDialogOption(
                        onPressed: () => Navigator.pop(ctx, ''),
                        child: const Text("无（本地直连）"),
                      ),
                      for (final m in offering)
                        SimpleDialogOption(
                          onPressed: () => Navigator.pop(ctx, m.deviceId),
                          child: Text("${m.name}（${m.vip}）"),
                        ),
                    ],
                  ),
                );
                if (picked == null) return;
                active.exitChoice = picked;
                await MeshService.heartbeat(active);
                _snack(context, picked.isEmpty ? "已关闭出口" : "已选择出口，配置已更新");
                setstate?.call();
              },
            ),
          ),
        );
        detail.add(
          GroupItemOptions(
            pushOptions: GroupItemPushOptions(
              name: "查看生成的隧道配置",
              onPush: () async {
                final summary = await MeshService.endpointSummary();
                if (context.mounted) {
                  await _showText(context, "WireGuard endpoint（自动生成）", summary);
                }
              },
            ),
          ),
        );
        detail.add(
          GroupItemOptions(
            pushOptions: GroupItemPushOptions(
              name: "退出网络",
              onPush: () async {
                if (!await _confirm(context, "退出网络", "本机将注销并删除「${active.name}」的本地材料，确定？")) {
                  return;
                }
                try {
                  await MeshService.leave(active);
                  _snack(context, "已退出");
                } catch (e) {
                  _snack(context, "退出失败：$e");
                }
                setstate?.call();
              },
            ),
          ),
        );
        if (active.adminToken.isNotEmpty) {
          detail.add(
            GroupItemOptions(
              pushOptions: GroupItemPushOptions(
                name: "解散网络",
                onPush: () async {
                  if (!await _confirm(context, "解散网络", "「${active.name}」将被解散，全部成员失效，确定？")) {
                    return;
                  }
                  try {
                    await MeshService.dissolve(active);
                    _snack(context, "已解散");
                  } catch (e) {
                    _snack(context, "解散失败：$e");
                  }
                  setstate?.call();
                },
              ),
            ),
          );
        }
        groups.add(GroupItem(options: detail));
      }

      groups.add(
        GroupItem(
          options: [
            GroupItemOptions(
              textOptions: GroupItemTextOptions(
                name: "说明",
                text:
                    "组网走自研协调服务（yousj-meshd）＋ WireGuard 隧道，经你自己的服务器中转互通。\n"
                    "组网内 SSH/SFTP：电脑端开启后，同网设备可用组网身份密钥直连对方虚拟 IP 的 2222 端口；手机上可用 Termux 的 ssh/sftp 连过去。\n"
                    "手机端状态：控制面与配置生成已通；手机真实流量要等隧道核心（libbox）接通后生效，电脑端已可真跑。",
                textWidthPercent: 0.62,
              ),
            ),
          ],
        ),
      );
      return groups;
    }

    await Navigator.push(
      context,
      MaterialPageRoute(
        settings: GroupScreen.routeSettings("Mesh"),
        builder: (context) => GroupScreen(
          title: "组网",
          getOptions: getOptions,
          onDone: (BuildContext context, SetStateCallback? setstate) async {
            await persist();
            MeshService.applyFromConfig();
            return true;
          },
        ),
      ),
    );
  }
}
