// Reconstructed for the Yousj Enhanced fork (2026-11-14) from call sites.
// (The class name keeps upstream's spelling: AppLifecycleStateNofity.)
//
// Model inferred from my_app.dart (which pushes Flutter lifecycle events
// in via stateResumed/statePaused/stateInactive with a reason string) and
// the consumers (managers and home_screen register callbacks and poll
// isPaused()):
//  - onStateResumed(key, cb) / onStatePaused(key, cb): listener registry;
//    a null key registers permanently, a non-null key (screens pass their
//    hashCode) replaces any previous registration under the same key.
//  - stateResumed/statePaused flip the paused flag and fire listeners.
//  - stateInactive only records the last state; stateLaunch records the
//    launch-at-startup flag pushed by my_app.

typedef LifecycleCallback = void Function();

class AppLifecycleStateNofity {
  AppLifecycleStateNofity._();

  static bool _paused = false;
  static bool _launchAtStartup = false;
  static String _lastState = '';

  static final Map<Object, LifecycleCallback> _resumedByKey = {};
  static final Map<Object, LifecycleCallback> _pausedByKey = {};
  static final List<LifecycleCallback> _resumedAnon = [];
  static final List<LifecycleCallback> _pausedAnon = [];

  static void init() {}

  static void uninit() {
    _resumedByKey.clear();
    _pausedByKey.clear();
    _resumedAnon.clear();
    _pausedAnon.clear();
  }

  static bool isPaused() => _paused;

  static bool get launchAtStartup => _launchAtStartup;

  static String get lastState => _lastState;

  static void onStateResumed(Object? key, LifecycleCallback? callback) {
    if (key == null) {
      if (callback != null && !_resumedAnon.contains(callback)) {
        _resumedAnon.add(callback);
      }
    } else if (callback == null) {
      _resumedByKey.remove(key);
    } else {
      _resumedByKey[key] = callback;
    }
  }

  static void onStatePaused(Object? key, LifecycleCallback? callback) {
    if (key == null) {
      if (callback != null && !_pausedAnon.contains(callback)) {
        _pausedAnon.add(callback);
      }
    } else if (callback == null) {
      _pausedByKey.remove(key);
    } else {
      _pausedByKey[key] = callback;
    }
  }

  static void _fire(List<LifecycleCallback> anon, Map<Object, LifecycleCallback> byKey) {
    for (final cb in List<LifecycleCallback>.from(anon)) {
      try {
        cb();
      } catch (_) {}
    }
    for (final cb in List<LifecycleCallback>.from(byKey.values)) {
      try {
        cb();
      } catch (_) {}
    }
  }

  static void stateResumed(String reason) {
    _lastState = reason;
    _paused = false;
    _fire(_resumedAnon, _resumedByKey);
  }

  static void statePaused(String reason) {
    _lastState = reason;
    _paused = true;
    _fire(_pausedAnon, _pausedByKey);
  }

  static void stateInactive(String reason) {
    _lastState = reason;
  }

  static void stateLaunch(bool launchAtStartup) {
    _launchAtStartup = launchAtStartup;
  }

  /// Re-evaluate the current state. Lifecycle events are pushed in by
  /// my_app's observer, so there is nothing to poll; the future completes
  /// immediately (home_screen awaits it before reading isPaused()).
  static Future<void> updateState() async {}
}
