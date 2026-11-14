// Reconstructed for the Yousj Enhanced fork (upstream file missing).
//
// API pinned from call sites (dns_settings_screen.dart,
// dns_auto_setup_screen.dart):
//   _taskQueue ??= ParallelTaskQueue((url) async { ... });
//   _taskQueue!.hasTask(url) -> bool
//   _taskQueue!.addTasks(urls);  // List<String>
//   _taskQueue!.run();
//   _taskQueue?.cancel();
//   _taskQueue!.running(addr) -> bool
// The screens poll hasTask/running from their build methods while DNS
// latency tests run in parallel.

import 'dart:async';

/// Runs a per-item async task over a queue of string keys with bounded
/// parallelism.
class ParallelTaskQueue {
  ParallelTaskQueue(this._task, [this.onDone]);

  final Future<String> Function(String url) _task;

  /// Maximum number of tasks in flight at once.
  int parallel = 8;

  /// Progress callback invoked per task: (url, left, total, start,
  /// finish) — start=true when a task begins, finish=true when the
  /// queue has fully drained (dns_auto_setup / dns_settings screens).
  final void Function(String url, int left, int total, bool start, bool finish)?
  onDone;

  final List<String> _pending = [];
  final Set<String> _running = {};
  final Set<String> _finished = {};
  bool _cancelled = false;
  bool _started = false;

  void addTasks(List<String> urls) {
    for (final url in urls) {
      if (!_pending.contains(url) &&
          !_running.contains(url) &&
          !_finished.contains(url)) {
        _pending.add(url);
      }
    }
    if (_started) {
      _pump();
    }
  }

  bool hasTask(String url) {
    return _pending.contains(url) ||
        _running.contains(url) ||
        _finished.contains(url);
  }

  bool running(String url) {
    return _running.contains(url);
  }

  void run() {
    _started = true;
    _cancelled = false;
    _pump();
  }

  void cancel() {
    _cancelled = true;
    _pending.clear();
  }

  void _pump() {
    if (_cancelled) {
      return;
    }
    while (_running.length < parallel && _pending.isNotEmpty) {
      final url = _pending.removeAt(0);
      _running.add(url);
      onDone?.call(
        url,
        _pending.length,
        _finished.length + _running.length + _pending.length,
        true,
        false,
      );
      _task(url)
          .catchError((_) => '')
          .whenComplete(() {
            _running.remove(url);
            _finished.add(url);
            if (_cancelled) {
              return;
            }
            final drained = _pending.isEmpty && _running.isEmpty;
            onDone?.call(
              url,
              _pending.length,
              _finished.length + _pending.length,
              false,
              drained,
            );
            if (!drained) {
              _pump();
            }
          });
    }
  }
}
