package io.nebula.vpn_service

/**
 * VPN lifecycle state as seen by the app module (the QS TileService
 * compares against these values). Mirrors the Dart
 * `FlutterVpnServiceState` names that [ServiceStateBus] carries as
 * strings: disconnected, connecting, connected, disconnecting,
 * reasserting (Apple only), invalid.
 */
enum class VpnState {
    DISCONNECTED,
    CONNECTING,
    CONNECTED,
    DISCONNECTING,
    REASSERTING,
    INVALID;

    companion object {
        fun fromBusName(name: String): VpnState = when (name) {
            "connecting" -> CONNECTING
            "connected" -> CONNECTED
            "disconnecting" -> DISCONNECTING
            "reasserting" -> REASSERTING
            "invalid" -> INVALID
            else -> DISCONNECTED
        }
    }
}
