// Reconstructed for the Yousj Enhanced fork (upstream file missing).
//
// API pinned from call sites (home_screen.dart):
//   LocalNotifications.init();                       // :369, live code
// The remaining members appear in home_screen's (currently commented
// out) notification blocks and are reconstructed to match them:
//   LocalNotifications.notifiy(kLocalNotificationsIdNetStateId,
//       kLocalNotificationsIdNetState, title, content, "", () => null);
//   LocalNotifications.remove(kLocalNotificationsIdNetStateId);
// Note the upstream spelling "notifiy" is kept.
//
// Backed by package:flutter_local_notifications (22.x named-arg API).

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

const int kLocalNotificationsIdVpnStateId = 1;
const String kLocalNotificationsIdVpnState = 'vpn_state';
const int kLocalNotificationsIdNetStateId = 2;
const String kLocalNotificationsIdNetState = 'net_state';

class LocalNotifications {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  static bool _initialized = false;
  static final Map<int, void Function()> _tapCallbacks = {};

  static Future<void> init() async {
    if (_initialized) {
      return;
    }
    _initialized = true;
    const settings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(),
      macOS: DarwinInitializationSettings(),
      linux: LinuxInitializationSettings(defaultActionName: 'Open'),
    );
    try {
      await _plugin.initialize(
        settings: settings,
        onDidReceiveNotificationResponse: (response) {
          final id = response.id;
          if (id != null) {
            _tapCallbacks[id]?.call();
          }
        },
      );
    } catch (_) {
      // Notifications are best-effort (desktop without a notification
      // daemon, missing entitlements, ...).
    }
  }

  static Future<void> notifiy(
    int id,
    String channelId,
    String title,
    String content,
    String payload,
    void Function() onTap,
  ) async {
    await init();
    _tapCallbacks[id] = onTap;
    try {
      await _plugin.show(
        id: id,
        title: title,
        body: content,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            channelId,
            channelId,
            importance: Importance.low,
            priority: Priority.low,
            ongoing: true,
            autoCancel: false,
          ),
          iOS: const DarwinNotificationDetails(
            presentAlert: false,
            presentSound: false,
          ),
          macOS: const DarwinNotificationDetails(
            presentAlert: false,
            presentSound: false,
          ),
        ),
        payload: payload,
      );
    } catch (_) {}
  }

  static Future<void> remove(int id) async {
    _tapCallbacks.remove(id);
    try {
      await _plugin.cancel(id: id);
    } catch (_) {}
  }
}
