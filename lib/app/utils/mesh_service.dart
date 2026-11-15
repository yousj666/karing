// yousj-plus (v1.1.0): Yousj Mesh control-plane client.
//
// Implements the same self-developed protocol as yousj-meshd / yousj-mesh-pc
// (see mesh/internal/proto): the device owns an Ed25519 identity key
// (control-plane request signing, doubles as the SSH identity) and an
// X25519 WireGuard key; private keys are generated on-device and stored
// only in mesh_state.json inside the app profile directory — never in
// SettingConfig (which can be backed up / synced) and never logged.
//
// The network PSK is generated locally by the creator and only its SHA-256
// hash is sent to the coordinator; the PSK itself travels inside invite
// payloads, exactly like on PC.
//
// Data-plane honesty: the sing-box core (libbox) is not wired up yet, so
// this service completes the whole control plane and generates the
// WireGuard endpoint config (injected by VPNService at build time), but
// phone traffic does not flow until the core lands. The UI says so.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:karing/app/modules/setting_manager.dart';
import 'package:karing/app/utils/path_utils.dart';

class MeshMember {
  final String deviceId;
  final String name;
  final String vip;
  final String wgPub;
  final String idPub;
  final bool exitCapable;
  final bool exitOffering;
  final bool online;

  MeshMember.fromJson(Map<String, dynamic> j)
    : deviceId = j['device_id'] ?? '',
      name = j['name'] ?? '',
      vip = j['vip'] ?? '',
      wgPub = j['wg_pub'] ?? '',
      idPub = j['id_pub'] ?? '',
      exitCapable = j['exit_capable'] ?? false,
      exitOffering = j['exit_offering'] ?? false,
      online = j['online'] ?? false;
}

class MeshNetworkState {
  String id = '';
  String name = '';
  String coordinator = '';
  String adminToken = '';
  String psk = ''; // base64 raw-url
  String deviceId = '';
  String vip = '';
  String hubPub = '';
  String hubEndpoint = '';
  String exitChoice = '';
  bool exitOffering = false;
  bool exitCapable = true;
  List<MeshMember> members = [];

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'coordinator': coordinator,
    'admin_token': adminToken,
    'psk': psk,
    'device_id': deviceId,
    'vip': vip,
    'hub_pub': hubPub,
    'hub_endpoint': hubEndpoint,
    'exit_choice': exitChoice,
    'exit_offering': exitOffering,
    'exit_capable': exitCapable,
    'members': members
        .map(
          (m) => {
            'device_id': m.deviceId,
            'name': m.name,
            'vip': m.vip,
            'wg_pub': m.wgPub,
            'id_pub': m.idPub,
            'exit_capable': m.exitCapable,
            'exit_offering': m.exitOffering,
            'online': m.online,
          },
        )
        .toList(),
  };

  static MeshNetworkState fromJson(Map<String, dynamic> j) {
    final n = MeshNetworkState();
    n.id = j['id'] ?? '';
    n.name = j['name'] ?? '';
    n.coordinator = j['coordinator'] ?? '';
    n.adminToken = j['admin_token'] ?? '';
    n.psk = j['psk'] ?? '';
    n.deviceId = j['device_id'] ?? '';
    n.vip = j['vip'] ?? '';
    n.hubPub = j['hub_pub'] ?? '';
    n.hubEndpoint = j['hub_endpoint'] ?? '';
    n.exitChoice = j['exit_choice'] ?? '';
    n.exitOffering = j['exit_offering'] ?? false;
    n.exitCapable = j['exit_capable'] ?? true;
    final ms = j['members'];
    if (ms is List) {
      n.members = ms
          .whereType<Map>()
          .map((m) => MeshMember.fromJson(m.cast<String, dynamic>()))
          .toList();
    }
    return n;
  }
}

class MeshService {
  static const String _stateFileName = 'mesh_state.json';

  static Map<String, dynamic>? _state;
  static Future<void> _saveChain = Future<void>.value();
  static Timer? _heartbeatTimer;

  // ---- encoding helpers (wire format = base64 raw-url, no padding) ----

  static String b64url(List<int> bytes) =>
      base64Url.encode(bytes).replaceAll('=', '');

  static Uint8List b64urlDecode(String s) {
    var t = s.replaceAll('-', '+').replaceAll('_', '/');
    while (t.length % 4 != 0) {
      t += '=';
    }
    return base64.decode(t);
  }

  /// sing-box wants standard base64 (with padding) for WireGuard keys.
  static String b64std(String rawUrl) => base64.encode(b64urlDecode(rawUrl));

  // ---- state ----

  static Future<File?> _stateFile() async {
    final dir = await PathUtils.profileDir();
    if (dir.isEmpty) return null;
    return File('$dir/$_stateFileName');
  }

  static Future<Map<String, dynamic>> _ensureState() async {
    if (_state != null) return _state!;
    var st = <String, dynamic>{
      'identity': null,
      'networks': <String, dynamic>{},
      'coord_pin': <String, dynamic>{},
    };
    final file = await _stateFile();
    if (file != null && await file.exists()) {
      try {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map<String, dynamic>) st = decoded;
      } catch (_) {}
    }
    st['networks'] ??= <String, dynamic>{};
    st['coord_pin'] ??= <String, dynamic>{};
    if (st['identity'] == null) {
      final ed = await Ed25519().newKeyPair();
      final edPriv = await ed.extractPrivateKeyBytes();
      final edPub = (await ed.extractPublicKey()).bytes;
      final x = await X25519().newKeyPair();
      final xPriv = await x.extractPrivateKeyBytes();
      final xPub = (await x.extractPublicKey()).bytes;
      st['identity'] = {
        'id_priv': b64url(edPriv),
        'id_pub': b64url(edPub),
        'wg_priv': b64url(xPriv),
        'wg_pub': b64url(xPub),
      };
      _state = st;
      await _save();
    }
    _state = st;
    return st;
  }

  static Future<void> _save() {
    final st = _state;
    if (st == null) return Future<void>.value();
    _saveChain = _saveChain.then((_) async {
      final file = await _stateFile();
      if (file == null) return;
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(jsonEncode(st));
      await tmp.rename(file.path);
    });
    return _saveChain;
  }

  static Future<String> deviceId() async {
    final st = await _ensureState();
    final idPub = b64urlDecode(st['identity']['id_pub'] as String);
    return crypto.sha256.convert(idPub).bytes
        .sublist(0, 8)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  static Future<List<MeshNetworkState>> networks() async {
    final st = await _ensureState();
    final nets = (st['networks'] as Map).cast<String, dynamic>();
    return nets.values
        .whereType<Map>()
        .map((j) => MeshNetworkState.fromJson(j.cast<String, dynamic>()))
        .toList();
  }

  static Future<MeshNetworkState?> activeNetwork() async {
    final cfg = SettingManager.getConfig().mesh;
    if (cfg.activeNetworkId.isEmpty) return null;
    final all = await networks();
    for (final n in all) {
      if (n.id == cfg.activeNetworkId) return n;
    }
    return null;
  }

  static Future<void> _storeNetwork(MeshNetworkState n) async {
    final st = await _ensureState();
    (st['networks'] as Map)[n.id] = n.toJson();
    await _save();
  }

  static Future<void> _removeNetwork(String id) async {
    final st = await _ensureState();
    (st['networks'] as Map).remove(id);
    final cfg = SettingManager.getConfig().mesh;
    if (cfg.activeNetworkId == id) {
      cfg.activeNetworkId = '';
      SettingManager.setDirty(true);
      await SettingManager.save();
    }
    await _save();
  }

  // ---- signed HTTP ----

  static Future<Map<String, dynamic>> _request(
    String base,
    String method,
    String path, {
    Map<String, dynamic>? body,
    String adminToken = '',
    bool sign = true,
  }) async {
    final st = await _ensureState();
    final identity = (st['identity'] as Map).cast<String, dynamic>();
    final rawBody = body == null ? <int>[] : utf8.encode(jsonEncode(body));
    final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    var sig = '';
    if (sign) {
      final bodyHash = crypto.sha256.convert(rawBody).bytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      final canonical = '$method\n$path\n$ts\n$bodyHash';
      final kp = await Ed25519().newKeyPairFromSeed(
        b64urlDecode(identity['id_priv'] as String).sublist(0, 32),
      );
      final signature = await Ed25519().sign(utf8.encode(canonical), keyPair: kp);
      sig = b64url(signature.bytes);
    }
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 15);
    // Certificate pinning (trust on first use): meshd deployments use a
    // self-signed cert; its SHA-256 fingerprint is pinned per coordinator
    // origin after the first successful contact.
    client.badCertificateCallback = (cert, host, port) {
      final origin = base;
      final fp = crypto.sha256.convert(cert.der).bytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      final pins = (st['coord_pin'] as Map).cast<String, dynamic>();
      final known = pins[origin];
      if (known == null) {
        pins[origin] = fp;
        _save();
        return true;
      }
      return known == fp;
    };
    try {
      final req = await client.openUrl(method, Uri.parse('$base$path'));
      req.headers.set('Content-Type', 'application/json');
      req.headers.set('X-Device-Id', await deviceId());
      req.headers.set('X-Timestamp', '$ts');
      if (sig.isNotEmpty) req.headers.set('X-Signature', sig);
      if (adminToken.isNotEmpty) req.headers.set('X-Admin-Token', adminToken);
      if (rawBody.isNotEmpty) req.add(rawBody);
      final resp = await req.close();
      final text = await utf8.decoder.bind(resp).join();
      Map<String, dynamic> decoded = {};
      try {
        final d = jsonDecode(text);
        if (d is Map<String, dynamic>) decoded = d;
      } catch (_) {}
      if (resp.statusCode >= 400) {
        throw Exception(
          '协调服务返回 ${resp.statusCode}: ${decoded['error'] ?? text}',
        );
      }
      return decoded;
    } finally {
      client.close(force: true);
    }
  }

  // ---- protocol operations ----

  static Future<MeshNetworkState> createNetwork(
    String coordinator,
    String networkName,
    String deviceName,
  ) async {
    final psk = _random32();
    final pskHash = crypto.sha256.convert(psk).bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    // The hub needs the PSK to complete handshakes, but the coordinator
    // must never see it in plaintext: seal it to the hub's X25519 public
    // key (same construction as the Go client, internal/proto/psk.go).
    final meta = await _request(coordinator, 'GET', '/v1/meta', sign: false);
    final hubPubB64 = (meta['hub'] as Map)['public_key'] as String;
    final pskForHub = await _sealPskForHub(psk, b64urlDecode(hubPubB64));
    final created = await _request(coordinator, 'POST', '/v1/networks', body: {
      'name': networkName,
      'psk_hash': pskHash,
      'psk_for_hub': pskForHub,
    });
    final n = MeshNetworkState()
      ..id = created['network_id'] as String
      ..name = networkName
      ..coordinator = coordinator
      ..adminToken = created['admin_token'] as String
      ..psk = b64url(psk)
      ..hubPub = (created['hub'] as Map)['public_key'] ?? ''
      ..hubEndpoint = (created['hub'] as Map)['endpoint'] ?? '';
    await _storeNetwork(n);
    // Creator joins its own network through a self-invite, same as PC.
    final inv = await _request(
      coordinator,
      'POST',
      '/v1/networks/${n.id}/invites',
      body: {'ttl_seconds': 3600, 'max_uses': 1},
      adminToken: n.adminToken,
    );
    final payload = encodeInvitePayload(
      coordinator: coordinator,
      networkId: n.id,
      networkName: networkName,
      inviteCode: inv['code'] as String,
      psk: n.psk,
    );
    return join(payload, deviceName, adminTokenKeep: n.adminToken);
  }

  static List<int> _random32() {
    final r = Random.secure();
    return List<int>.generate(32, (_) => r.nextInt(256));
  }

  /// Seals the network PSK to the hub key:
  /// ephemeralPub(32) || nonce(12) || ChaCha20-Poly1305(
  ///   HKDF-SHA256(X25519(ephemeral, hubPub), info "yousj-mesh-psk"), psk).
  /// Byte-for-byte the same construction as proto.SealPSKForHub in Go.
  static Future<String> _sealPskForHub(List<int> psk, List<int> hubPub) async {
    final x = X25519();
    final eph = await x.newKeyPair();
    final ephPub = (await eph.extractPublicKey()).bytes;
    final shared = await x.sharedSecretKey(
      keyPair: eph,
      remotePublicKey: SimplePublicKey(hubPub, type: KeyPairType.x25519),
    );
    final sharedBytes = await shared.extractBytes();
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    final key = await hkdf.deriveKey(
      secretKey: SecretKey(sharedBytes),
      nonce: const [],
      info: utf8.encode('yousj-mesh-psk'),
    );
    final nonce = _randomBytes(12);
    final box = await ChaCha20.poly1305Aead().encrypt(
      psk,
      secretKey: key,
      nonce: nonce,
    );
    final sealed = <int>[
      ...ephPub,
      ...nonce,
      ...box.cipherText,
      ...box.mac.bytes,
    ];
    return b64url(sealed);
  }

  static List<int> _randomBytes(int n) {
    final r = Random.secure();
    return List<int>.generate(n, (_) => r.nextInt(256));
  }

  static String encodeInvitePayload({
    required String coordinator,
    required String networkId,
    required String networkName,
    required String inviteCode,
    required String psk,
  }) {
    final payload = {
      'v': 1,
      'coordinator': coordinator,
      'network_id': networkId,
      'network_name': networkName,
      'invite_code': inviteCode,
      'psk': psk,
    };
    return 'yousjmesh://join?d=${b64url(utf8.encode(jsonEncode(payload)))}';
  }

  static Map<String, dynamic> decodeInvitePayload(String s) {
    var t = s.trim();
    final i = t.indexOf('d=');
    if (t.startsWith('yousjmesh://') && i >= 0) t = t.substring(i + 2);
    final decoded = jsonDecode(utf8.decode(b64urlDecode(t)));
    if (decoded is! Map<String, dynamic>) {
      throw Exception('邀请内容格式不对');
    }
    for (final k in ['coordinator', 'network_id', 'invite_code', 'psk']) {
      if ((decoded[k] as String?)?.isEmpty ?? true) {
        throw Exception('邀请内容缺字段: $k');
      }
    }
    return decoded;
  }

  static Future<String> createInvite(MeshNetworkState n) async {
    final inv = await _request(
      n.coordinator,
      'POST',
      '/v1/networks/${n.id}/invites',
      body: {'ttl_seconds': 24 * 3600, 'max_uses': 1},
      adminToken: n.adminToken,
    );
    return encodeInvitePayload(
      coordinator: n.coordinator,
      networkId: n.id,
      networkName: n.name,
      inviteCode: inv['code'] as String,
      psk: n.psk,
    );
  }

  static Future<MeshNetworkState> join(
    String payloadStr,
    String deviceName, {
    String adminTokenKeep = '',
  }) async {
    final p = decodeInvitePayload(payloadStr);
    final st = await _ensureState();
    final identity = (st['identity'] as Map).cast<String, dynamic>();
    final resp = await _request(p['coordinator'] as String, 'POST', '/v1/join', body: {
      'invite_code': p['invite_code'],
      'name': deviceName,
      'wg_pub': identity['wg_pub'],
      'id_pub': identity['id_pub'],
      'exit_capable': true,
    });
    final n = MeshNetworkState()
      ..id = resp['network_id'] as String
      ..name = (resp['network_name'] as String?) ?? (p['network_name'] ?? '')
      ..coordinator = p['coordinator'] as String
      ..adminToken = adminTokenKeep
      ..psk = p['psk'] as String
      ..deviceId = resp['device_id'] as String
      ..vip = resp['vip'] as String
      ..hubPub = (resp['hub'] as Map)['public_key'] ?? ''
      ..hubEndpoint = (resp['hub'] as Map)['endpoint'] ?? '';
    final ms = resp['members'];
    if (ms is List) {
      n.members = ms
          .whereType<Map>()
          .map((m) => MeshMember.fromJson(m.cast<String, dynamic>()))
          .toList();
    }
    await _storeNetwork(n);
    final cfg = SettingManager.getConfig().mesh;
    cfg.activeNetworkId = n.id;
    cfg.coordinatorUrl = n.coordinator;
    SettingManager.setDirty(true);
    await SettingManager.save();
    ensureHeartbeat();
    return n;
  }

  static Future<MeshNetworkState> refreshMembers(MeshNetworkState n) async {
    final resp = await _request(
      n.coordinator,
      'GET',
      '/v1/networks/${n.id}/members',
    );
    n.name = (resp['network_name'] as String?) ?? n.name;
    n.hubPub = (resp['hub'] as Map)['public_key'] ?? n.hubPub;
    n.hubEndpoint = (resp['hub'] as Map)['endpoint'] ?? n.hubEndpoint;
    final ms = resp['members'];
    if (ms is List) {
      n.members = ms
          .whereType<Map>()
          .map((m) => MeshMember.fromJson(m.cast<String, dynamic>()))
          .toList();
    }
    await _storeNetwork(n);
    return n;
  }

  static Future<void> heartbeat(MeshNetworkState n) async {
    await _storeNetwork(n);
    await _request(n.coordinator, 'POST', '/v1/networks/${n.id}/heartbeat', body: {
      'exit_capable': n.exitCapable,
      'exit_offering': n.exitOffering,
      'exit_choice': n.exitChoice,
    });
  }

  static Future<void> leave(MeshNetworkState n) async {
    try {
      await _request(n.coordinator, 'POST', '/v1/networks/${n.id}/leave');
    } finally {
      await _removeNetwork(n.id);
    }
  }

  static Future<void> kick(MeshNetworkState n, String deviceId) async {
    await _request(
      n.coordinator,
      'DELETE',
      '/v1/networks/${n.id}/devices/$deviceId',
      adminToken: n.adminToken,
    );
  }

  static Future<void> dissolve(MeshNetworkState n) async {
    await _request(
      n.coordinator,
      'DELETE',
      '/v1/networks/${n.id}',
      adminToken: n.adminToken,
    );
    await _removeNetwork(n.id);
  }

  static void ensureHeartbeat() {
    _heartbeatTimer ??= Timer.periodic(const Duration(seconds: 30), (_) async {
      final cfg = SettingManager.getConfig().mesh;
      if (!cfg.enable) return;
      final n = await activeNetwork();
      if (n == null) return;
      try {
        await heartbeat(n);
        await refreshMembers(n);
      } catch (_) {
        // Coordinator unreachable: keep the cached list, retry next tick.
      }
    });
  }

  static void applyFromConfig() {
    final cfg = SettingManager.getConfig().mesh;
    if (cfg.enable) {
      ensureHeartbeat();
    }
  }

  // ---- sing-box endpoint generation ----

  /// Builds the WireGuard endpoint JSON for the active network, or null.
  ///
  /// Hub-and-spoke: the single data-plane peer is the hub (its peer table on
  /// the server side is generated from the member list by hub-sync). The
  /// member list drives this endpoint's allowed_ips: the mesh subnet, or
  /// 0.0.0.0/0 when an exit member is chosen. Member peers cannot be listed
  /// individually here because members behind NAT have no reachable
  /// endpoint; their WireGuard sessions terminate at the hub.
  static Future<Map<String, dynamic>?> buildEndpointJson() async {
    final cfg = SettingManager.getConfig().mesh;
    if (!cfg.enable) return null;
    final n = await activeNetwork();
    if (n == null || n.vip.isEmpty || n.hubPub.isEmpty) return null;
    final st = await _ensureState();
    final identity = (st['identity'] as Map).cast<String, dynamic>();
    final hubParts = n.hubEndpoint.split(':');
    if (hubParts.length != 2) return null;
    final hubPort = int.tryParse(hubParts[1]);
    if (hubPort == null) return null;
    final allowed = n.exitChoice.isNotEmpty
        ? ['0.0.0.0/0']
        : ['10.99.0.0/24'];
    return {
      'type': 'wireguard',
      'tag': 'mesh:${n.id.substring(0, n.id.length >= 8 ? 8 : n.id.length)}',
      'address': ['${n.vip}/32'],
      'private_key': b64std(identity['wg_priv'] as String),
      'mtu': 1280,
      'peers': [
        {
          'address': hubParts[0],
          'port': hubPort,
          'public_key': b64std(n.hubPub),
          'pre_shared_key': b64std(n.psk),
          'allowed_ips': allowed,
          'persistent_keepalive_interval': 25,
        },
      ],
    };
  }

  /// Human-readable snapshot of the generated endpoint for the settings UI
  /// and for exporting to a desktop WireGuard client for verification.
  static Future<String> endpointSummary() async {
    final ep = await buildEndpointJson();
    if (ep == null) return '未生成（组网未启用或未加入网络）';
    return const JsonEncoder.withIndent('  ').convert(ep);
  }
}
