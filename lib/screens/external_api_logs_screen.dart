// yousj-plus (v1.0.7): request log of the external AI API.
//
// Shows the newest-first entries recorded by ExternalApiService (time,
// source IP, method, path, HTTP status, token verdict, and for Termux
// exec the command length / exit code / duration). The entries never
// contain the token or any command text. The log is capped at 200
// entries and persisted by the service, so it survives restarts.

import 'package:flutter/material.dart';
import 'package:karing/app/utils/external_api_service.dart';

class ExternalApiLogsScreen extends StatefulWidget {
  const ExternalApiLogsScreen({super.key});

  @override
  State<ExternalApiLogsScreen> createState() => _ExternalApiLogsScreenState();
}

class _ExternalApiLogsScreenState extends State<ExternalApiLogsScreen> {
  List<Map<String, dynamic>> _logs = <Map<String, dynamic>>[];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final logs = await ExternalApiService.getLogs();
    if (!mounted) {
      return;
    }
    setState(() {
      _logs = logs;
      _loading = false;
    });
  }

  Future<void> _clear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("清空接口日志"),
        content: const Text("确定要清空全部接口日志吗？此操作不可恢复。"),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text("取消"),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text("清空"),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    await ExternalApiService.clearLogs();
    await _refresh();
  }

  String _formatTime(Object? raw) {
    final parsed = raw is String ? DateTime.tryParse(raw) : null;
    if (parsed == null) {
      return (raw ?? '').toString();
    }
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(parsed.month)}-${two(parsed.day)} '
        '${two(parsed.hour)}:${two(parsed.minute)}:${two(parsed.second)}';
  }

  String _authText(Object? auth) {
    if (auth == true) {
      return '令牌通过';
    }
    if (auth == false) {
      return '令牌失败';
    }
    return '免令牌';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("接口日志"),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: "刷新",
            onPressed: _refresh,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: "清空日志",
            onPressed: _logs.isEmpty ? null : _clear,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _logs.isEmpty
          ? const Center(child: Text("暂无日志"))
          : ListView.separated(
              itemCount: _logs.length,
              separatorBuilder: (context, index) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final entry = _logs[index];
                final status = entry['status'];
                final isExec = entry['cmd_len'] != null;
                final details = <String>[
                  _formatTime(entry['time']),
                  '来源 ${(entry['ip'] ?? '').toString()}',
                  _authText(entry['auth']),
                ];
                if (isExec) {
                  details.add('命令长度 ${entry['cmd_len']}');
                  if (entry['timed_out'] == true) {
                    details.add('超时');
                  } else if (entry.containsKey('exit_code')) {
                    details.add('退出码 ${entry['exit_code']}');
                  }
                  if (entry['duration_ms'] != null) {
                    details.add('耗时 ${entry['duration_ms']}ms');
                  }
                }
                return ListTile(
                  dense: true,
                  title: Text(
                    '${entry['method'] ?? ''} ${entry['path'] ?? ''}',
                  ),
                  subtitle: Text(details.join(' · ')),
                  trailing: Text(
                    '$status',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: status == 200
                          ? Colors.green
                          : (status == 401 || status == 403)
                          ? Colors.red
                          : null,
                    ),
                  ),
                );
              },
            ),
    );
  }
}
