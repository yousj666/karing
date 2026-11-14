// Reconstructed for the Yousj Enhanced fork (2026-11-14) from call sites.
// The string constants of the app's URL-scheme / LAN-sync action space:
// producers and consumers are all in-tree (scheme_handler dispatches on
// uri.host; the LAN sync server routes on "/<action>"), so the values only
// need internal consistency. [RECONSTRUCTION CHOICE: kebab-case values.]

class AppSchemeActions {
  AppSchemeActions._();

  /// The app's own URL scheme ("karing" in "karing://connect").
  static String scheme() => 'karing';

  static String connectAction() => 'connect';
  static String disconnectAction() => 'disconnect';
  static String reconnectAction() => 'reconnect';
  static String installConfigAction() => 'install-config';
  static String restoreBackup() => 'restore-backup';

  /// LAN backup-sync endpoints (also used as URL hosts by the sender).
  static String syncUploadAction() => 'sync-upload';
  static String syncDownloadAction() => 'sync-download';

  /// Apple TV companion endpoints (home_tvos_screen talks to the phone's
  /// LAN server under these paths; group_helper validates the host).
  static String appleTVHost() => 'appletv';
  static String appleTVSyncUploadAction() => 'appletv-sync-upload';
  static String appleTVGetFileContentAction() => 'appletv-get-file-content';
  static String appleTVDeleteCoreConfigAction() =>
      'appletv-delete-core-config';
}
