// Reconstructed for the Yousj Enhanced fork (2026-11-14) from call sites:
// a static hand-off point for VPN actions. home_screen registers its
// _vpnConnect/_vpnDisconnect/_vpnReconnect (all
// `Future<void> Function(String from, bool background)`); tray menus,
// quick actions (my_app.dart) and the scheme handler invoke them through
// here without depending on the home screen's state object.

typedef VpnAction = Future<void> Function(String from, bool background);

class VpnActionHandler {
  VpnActionHandler._();

  static VpnAction? vpnConnect;
  static VpnAction? vpnDisconnect;
  static VpnAction? vpnReconnect;
}
