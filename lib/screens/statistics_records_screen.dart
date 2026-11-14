// Reconstructed for the Yousj Enhanced fork (upstream file missing).
//
// API pinned from call sites (group_helper.dart:1168):
//   settings: StatisticsRecordsScreen.routeSettings(),
//   builder: (context) => StatisticsRecordsScreen(
//       dbPath: dbPath, currentDB: dbPath == currentDB)
// — a viewer for one statistics database file (statistics.db, written
// by the core; SQLite — the app depends on package:sqlite3).
//
// The core's exact schema is part of the native layer, so this screen
// introspects the database: it lists the rows of the first table that
// looks like a records table, rendering column values generically.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:karing/i18n/strings.g.dart';
import 'package:sqlite3/sqlite3.dart';

class StatisticsRecordsScreen extends StatefulWidget {
  const StatisticsRecordsScreen({
    super.key,
    required this.dbPath,
    required this.currentDB,
  });

  final String dbPath;
  final bool currentDB;

  static RouteSettings routeSettings() {
    return const RouteSettings(name: 'StatisticsRecordsScreen');
  }

  @override
  State<StatisticsRecordsScreen> createState() =>
      _StatisticsRecordsScreenState();
}

class _StatisticsRecordsScreenState extends State<StatisticsRecordsScreen> {
  bool _loading = true;
  String? _error;
  String _tableName = '';
  List<String> _columns = [];
  List<List<String>> _rows = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final file = File(widget.dbPath);
      if (!await file.exists()) {
        setState(() {
          _loading = false;
          _error = 'file not found: ${widget.dbPath}';
        });
        return;
      }
      final db = sqlite3.open(widget.dbPath, mode: OpenMode.readOnly);
      try {
        final tables = db.select(
          "SELECT name FROM sqlite_master WHERE type='table' "
          "AND name NOT LIKE 'sqlite_%'",
        );
        if (tables.isEmpty) {
          setState(() {
            _loading = false;
          });
          return;
        }
        // Prefer a table whose name suggests traffic records.
        String table = tables.first['name'] as String;
        for (final row in tables) {
          final name = row['name'] as String;
          final lower = name.toLowerCase();
          if (lower.contains('record') ||
              lower.contains('traffic') ||
              lower.contains('statistic')) {
            table = name;
            break;
          }
        }
        final result = db.select('SELECT * FROM "$table" LIMIT 500');
        setState(() {
          _loading = false;
          _tableName = table;
          _columns = result.columnNames;
          _rows = result.rows
              .map((row) => row.map((v) => v?.toString() ?? '').toList())
              .toList();
        });
      } finally {
        db.close();
      }
    } catch (err) {
      setState(() {
        _loading = false;
        _error = err.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final tcontext = Translations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(tcontext.meta.trafficStatistics)),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(_error!),
        ),
      );
    }
    if (_rows.isEmpty) {
      return Center(child: Text(widget.dbPath));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            '$_tableName (${_rows.length})',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
        if (_columns.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              _columns.join(' · '),
              style: const TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ),
        const Divider(height: 1),
        Expanded(
          child: ListView.separated(
            itemCount: _rows.length,
            separatorBuilder: (context, index) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final row = _rows[index];
              return ListTile(
                dense: true,
                title: Text(
                  row.join('  ·  '),
                  style: const TextStyle(fontSize: 13),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
