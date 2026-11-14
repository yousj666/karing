// state.dart — RECONSTRUCTED by the yousj-plus fork.
//
// Shared model layer of the vpn_service plugin. The upstream plugin is not
// part of the public Karing source release; every class, field and method
// below was re-derived from the call sites that survive in the app
// (server_manager.dart, setting_manager.dart, diversion screens, ...).
// Field sets are the union of in-repo accesses; JSON keys follow the
// snake_case convention used by the app's own persisted models
// (cf. ServerUse in server_manager.dart). Where the upstream persisted
// format could not be observed, keys are symmetric with toJson() so data
// round-trips within this reconstruction.
//
// This library is deliberately self-contained: it must not import the host
// app (package:karing/...).

import 'package:tuple/tuple.dart';

// ---------------------------------------------------------------------------
// Tag / type constants (shared by the app, the config builder and parsers).
// Values follow sing-box naming; they are reconstruction choices pinned by
// the comparisons surviving in the app (e.g. ServerUse.fromJson rewrites
// selector nodes onto kOutboundTagUrltest).
// ---------------------------------------------------------------------------

const String kOutboundTagUrltest = 'urltest';
const String kOutboundTagDirect = 'direct';
const String kOutboundTagBlock = 'block';

const String kOutboundTypeUrltest = 'urltest';
const String kOutboundTypeSelector = 'selector';
const String kOutboundTypeDirect = 'direct';
const String kOutboundTypeBlock = 'block';
const String kOutboundTypeDns = 'dns';

/// Markers stored in [DiversionRulesGroup.proxies] for the built-in
/// direct/block targets (compared in ServerManager.loadFrom).
const String kProxyDirect = 'direct';
const String kProxyBlock = 'block';

/// DNS server tags used by generated configs / DNS rule detection.
const String kDnsTagProxy = 'dns_proxy';
const String kDnsTagOutbound = 'dns_outbound';

// ---------------------------------------------------------------------------
// Small coercion helpers (plugin-local; the app's ConvertUtils is not
// visible from here).
// ---------------------------------------------------------------------------

String _asString(dynamic v, [String fallback = '']) {
  if (v == null) return fallback;
  if (v is String) return v;
  return v.toString();
}

int _asInt(dynamic v, [int fallback = 0]) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? fallback;
  return fallback;
}

bool _asBool(dynamic v, [bool fallback = false]) {
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) return v == 'true' || v == '1';
  return fallback;
}

List<String> _asStringList(dynamic v) {
  if (v is List) {
    return v.map((e) => _asString(e)).toList();
  }
  if (v is String && v.isNotEmpty) {
    return [v];
  }
  return <String>[];
}

List<int> _asIntList(dynamic v) {
  if (v is List) {
    return v.map((e) => _asInt(e)).toList();
  }
  if (v is int) return [v];
  return <int>[];
}

// ---------------------------------------------------------------------------
// Enums / option types
// ---------------------------------------------------------------------------

/// How a profile link was classified (drives which converter handles it).
enum SubscriptionLinkType { unknown, singbox, clash, wireguard, ss, v2ray }

/// Preferred routing strategy for a profile (used by port selection and
/// DNS resolution mode). Also referenced from setting_manager.dart via
/// proxy_manager.dart's re-export of this library.
enum ProxyStrategy { preferProxy, preferDirect, onlyProxy, onlyDirect }

enum ProxyFilterMethod { all, include, exclude }

/// Node filter attached to a profile: keep nodes whose tag/type matches
/// (or does not match) [keywordOrRegx].
class ProxyFilter {
  ProxyFilterMethod method = ProxyFilterMethod.all;
  String keywordOrRegx = '';
  bool matchAttribute = false;

  ProxyFilter clone() {
    return ProxyFilter()
      ..method = method
      ..keywordOrRegx = keywordOrRegx
      ..matchAttribute = matchAttribute;
  }

  Map<String, dynamic> toJson() => {
    'method': method.name,
    'keyword_or_regx': keywordOrRegx,
    'match_attribute': matchAttribute,
  };

  void fromJson(Map<String, dynamic>? map) {
    if (map == null) return;
    final m = _asString(map['method']);
    method = ProxyFilterMethod.values.firstWhere(
      (e) => e.name == m,
      orElse: () => ProxyFilterMethod.all,
    );
    keywordOrRegx = _asString(map['keyword_or_regx']);
    matchAttribute = _asBool(map['match_attribute']);
  }
}

/// Payload of a remotely fetched profile, handed to the converters.
class RemoteContent {
  String text = '';
}

/// Subscription quota info parsed from a `subscription-userinfo` header.
class SubscriptionTraffic {
  String upload = '';
  String download = '';
  String total = '';

  /// Unix seconds; 0 = unknown.
  int expire = 0;
  bool overQuota = false;

  /// (isExpiringSoonOrExpired, human-readable expiry) for the UI.
  Tuple2<bool, String> getExpireTime(String languageTag) {
    if (expire <= 0) {
      return const Tuple2(false, '');
    }
    final dt = DateTime.fromMillisecondsSinceEpoch(expire * 1000);
    final now = DateTime.now();
    final expiring =
        dt.isBefore(now) || dt.difference(now).inDays <= 7;
    String two(int v) => v.toString().padLeft(2, '0');
    final text =
        '${dt.year}-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}';
    return Tuple2(expiring, text);
  }

  Map<String, dynamic> toJson() => {
    'upload': upload,
    'download': download,
    'total': total,
    'expire': expire,
    'over_quota': overQuota,
  };

  void fromJson(Map<String, dynamic>? map) {
    if (map == null) return;
    upload = _asString(map['upload']);
    download = _asString(map['download']);
    total = _asString(map['total']);
    expire = _asInt(map['expire']);
    overQuota = _asBool(map['over_quota']);
  }
}

/// ISP / provider account binding of a profile.
class SubscriptionISP {
  String id = '';
  String user = '';

  Map<String, dynamic> toJson() => {'id': id, 'user': user};

  void fromJson(Map<String, dynamic>? map) {
    if (map == null) return;
    id = _asString(map['id']);
    user = _asString(map['user']);
  }
}

// ---------------------------------------------------------------------------
// ProxyConfig — one node (a sing-box outbound or endpoint) of a profile.
// ---------------------------------------------------------------------------

class ProxyConfig {
  String tag = '';
  String type = '';
  String groupid = '';
  int index = 0;
  String server = '';
  int serverport = 0;

  /// The full sing-box outbound/endpoint JSON this node was parsed from
  /// (or was edited into). Empty for nodes synthesised from scalar fields
  /// (call sites index it unconditionally).
  Map<String, dynamic> raw = {};

  /// Last latency-test result, display form ("" = untested, otherwise a
  /// millisecond count or an error string). Mirrored into raw["latency"].
  String latency = '';

  /// Free-form note shown next to the node in lists.
  String attach = '';

  String outletip = '';
  String outletregion = '';

  ProxyConfig clone() {
    final ret = ProxyConfig();
    ret.tag = tag;
    ret.type = type;
    ret.groupid = groupid;
    ret.index = index;
    ret.server = server;
    ret.serverport = serverport;
    ret.raw = Map<String, dynamic>.from(raw);
    ret.latency = latency;
    ret.attach = attach;
    ret.outletip = outletip;
    ret.outletregion = outletregion;
    return ret;
  }

  /// Identity for selection bookkeeping: same endpoint coordinates.
  bool isSame(ProxyConfig other) {
    return type == other.type &&
        server == other.server &&
        serverport == other.serverport &&
        tag == other.tag;
  }

  /// Short type label for list rows.
  String getShowType() {
    return type;
  }

  Map<String, dynamic> toJson() => {
    'tag': tag,
    'type': type,
    'groupid': groupid,
    'index': index,
    'server': server,
    'serverport': serverport,
    if (raw.isNotEmpty) 'raw': raw,
    'latency': latency,
    'attach': attach,
    'outlet_ip': outletip,
    'outlet_region': outletregion,
  };

  void fromJson(Map<String, dynamic>? map) {
    if (map == null) return;
    tag = _asString(map['tag']);
    type = _asString(map['type']);
    groupid = _asString(map['groupid']);
    index = _asInt(map['index']);
    server = _asString(map['server']);
    serverport = _asInt(map['serverport']);
    final r = map['raw'];
    raw = r is Map ? Map<String, dynamic>.from(r) : {};
    latency = _asString(map['latency']);
    attach = _asString(map['attach']);
    outletip = _asString(map['outlet_ip']);
    outletregion = _asString(map['outlet_region']);
  }
}

/// One user-defined urltest collection inside the custom group: nodes are
/// chosen by explicit [tags] and/or by [regexs] matched against node tags.
/// [preProxy] optionally names another urltest collection whose selected
/// node is used as the chain detour for this collection's tests.
///
/// The app refers to this type as both ProxyUrltest (construction sites
/// in urltest_group_custom_screen.dart) and ServerUrltestItem (field
/// declarations) — ProxyUrltest is the class, ServerUrltestItem an alias.
class ProxyUrltest {
  String remark = '';
  List<String> tags = [];
  List<String> regexs = [];
  String preProxy = '';

  ProxyUrltest clone() {
    return ProxyUrltest()
      ..remark = remark
      ..tags = List<String>.from(tags)
      ..regexs = List<String>.from(regexs)
      ..preProxy = preProxy;
  }

  Map<String, dynamic> toJson() => {
    'remark': remark,
    'tags': tags,
    'regexs': regexs,
    'pre_proxy': preProxy,
  };

  void fromJson(Map<String, dynamic>? map) {
    if (map == null) return;
    remark = _asString(map['remark']);
    tags = _asStringList(map['tags']);
    regexs = _asStringList(map['regexs']);
    preProxy = _asString(map['pre_proxy']);
  }
}

typedef ServerUrltestItem = ProxyUrltest;

// ---------------------------------------------------------------------------
// ServerConfigGroupItem — one profile (subscription / imported file /
// custom group) and its nodes.
// ---------------------------------------------------------------------------

class ServerConfigGroupItem {
  String groupid = '';
  int index = 0;
  String remark = '';
  SubscriptionLinkType type = SubscriptionLinkType.unknown;
  String urlOrPath = '';
  String site = '';
  bool enable = true;

  /// Whether the profile may be edited in the UI (custom groups are).
  bool editAble = false;

  List<ProxyConfig> servers = [];
  List<ProxyUrltest> urltests = [];

  /// Tags with a latency test currently running (mutated in place by
  /// ServerManager's test scheduler).
  List<String> testLatency = [];
  List<String> testLatencyIndepends = [];

  SubscriptionTraffic? traffic;
  SubscriptionISP? isp;

  ProxyFilter proxyFilter = ProxyFilter();
  List<String> proxyFilterRemove = [];
  bool userAgentAppend = false;
  List<String> userAgentCompatibles = [];
  bool xhwid = false;

  bool keepDiversionRules = false;
  bool enableDiversionRules = false;
  bool reloadAfterProfileUpdate = false;
  bool testLatencyAfterProfileUpdate = false;
  bool testLatencyAutoRemove = false;
  ProxyStrategy proxyStrategy = ProxyStrategy.preferProxy;

  String decryptPasswordAES = '';
  String decryptPasswordAGE = '';

  bool preferOutboundDns = false;
  List<String> outboundDns = [];

  Duration? updateDuration;
  String updateTime = '';

  bool isRemote() {
    return urlOrPath.startsWith('http://') || urlOrPath.startsWith('https://');
  }

  ProxyConfig? getByTag(String tag) {
    for (final server in servers) {
      if (server.tag == tag) {
        return server;
      }
    }
    return null;
  }

  /// Rebuild [urltests] membership after the node list changed: entries
  /// keep only tags that still exist. (Reconstruction: upstream may also
  /// prune regexes; tag pruning is the observable-safe part.)
  void updateTestLatencyList() {
    final exists = servers.map((e) => e.tag).toSet();
    for (final item in urltests) {
      item.tags = item.tags.where(exists.contains).toList();
    }
  }

  ServerConfigGroupItem clone({bool includeServers = true}) {
    final ret = ServerConfigGroupItem();
    ret.groupid = groupid;
    ret.index = index;
    ret.remark = remark;
    ret.type = type;
    ret.urlOrPath = urlOrPath;
    ret.site = site;
    ret.enable = enable;
    ret.editAble = editAble;
    if (includeServers) {
      ret.servers = servers.map((e) => e.clone()).toList();
    }
    ret.urltests = urltests.map((e) => e.clone()).toList();
    ret.testLatency = List<String>.from(testLatency);
    ret.testLatencyIndepends = List<String>.from(testLatencyIndepends);
    ret.traffic = traffic;
    ret.isp = isp;
    ret.proxyFilter = proxyFilter.clone();
    ret.proxyFilterRemove = List<String>.from(proxyFilterRemove);
    ret.userAgentAppend = userAgentAppend;
    ret.userAgentCompatibles = List<String>.from(userAgentCompatibles);
    ret.xhwid = xhwid;
    ret.keepDiversionRules = keepDiversionRules;
    ret.enableDiversionRules = enableDiversionRules;
    ret.reloadAfterProfileUpdate = reloadAfterProfileUpdate;
    ret.testLatencyAfterProfileUpdate = testLatencyAfterProfileUpdate;
    ret.testLatencyAutoRemove = testLatencyAutoRemove;
    ret.proxyStrategy = proxyStrategy;
    ret.decryptPasswordAES = decryptPasswordAES;
    ret.decryptPasswordAGE = decryptPasswordAGE;
    ret.preferOutboundDns = preferOutboundDns;
    ret.outboundDns = List<String>.from(outboundDns);
    ret.updateDuration = updateDuration;
    ret.updateTime = updateTime;
    return ret;
  }

  Map<String, dynamic> toJson() => {
    'groupid': groupid,
    'index': index,
    'remark': remark,
    'type': type.name,
    'url_or_path': urlOrPath,
    'site': site,
    'enable': enable,
    'servers': servers.map((e) => e.toJson()).toList(),
    'urltests': urltests.map((e) => e.toJson()).toList(),
    if (traffic != null) 'traffic': traffic!.toJson(),
    if (isp != null) 'isp': isp!.toJson(),
    'proxy_filter': proxyFilter.toJson(),
    'proxy_filter_remove': proxyFilterRemove,
    'user_agent_append': userAgentAppend,
    'user_agent_compatibles': userAgentCompatibles,
    'xhwid': xhwid,
    'keep_diversion_rules': keepDiversionRules,
    'enable_diversion_rules': enableDiversionRules,
    'reload_after_profile_update': reloadAfterProfileUpdate,
    'test_latency_after_profile_update': testLatencyAfterProfileUpdate,
    'test_latency_auto_remove': testLatencyAutoRemove,
    'proxy_strategy': proxyStrategy.name,
    'decrypt_password_aes': decryptPasswordAES,
    'decrypt_password_age': decryptPasswordAGE,
    'prefer_outbound_dns': preferOutboundDns,
    'outbound_dns': outboundDns,
    if (updateDuration != null)
      'update_duration': updateDuration!.inMilliseconds,
    'update_time': updateTime,
  };

  void fromJson(Map<String, dynamic>? map) {
    if (map == null) return;
    groupid = _asString(map['groupid']);
    index = _asInt(map['index']);
    remark = _asString(map['remark']);
    final t = _asString(map['type']);
    type = SubscriptionLinkType.values.firstWhere(
      (e) => e.name == t,
      orElse: () => SubscriptionLinkType.unknown,
    );
    urlOrPath = _asString(map['url_or_path']);
    site = _asString(map['site']);
    enable = _asBool(map['enable'], true);
    servers = [];
    final ss = map['servers'];
    if (ss is List) {
      for (final s in ss) {
        if (s is Map) {
          final pc = ProxyConfig();
          pc.fromJson(Map<String, dynamic>.from(s));
          servers.add(pc);
        }
      }
    }
    urltests = [];
    final us = map['urltests'];
    if (us is List) {
      for (final u in us) {
        if (u is Map) {
          final item = ServerUrltestItem();
          item.fromJson(Map<String, dynamic>.from(u));
          urltests.add(item);
        }
      }
    }
    final tr = map['traffic'];
    if (tr is Map) {
      traffic = SubscriptionTraffic();
      traffic!.fromJson(Map<String, dynamic>.from(tr));
    }
    final ip = map['isp'];
    if (ip is Map) {
      isp = SubscriptionISP();
      isp!.fromJson(Map<String, dynamic>.from(ip));
    }
    final pf = map['proxy_filter'];
    if (pf is Map) {
      proxyFilter.fromJson(Map<String, dynamic>.from(pf));
    }
    proxyFilterRemove = _asStringList(map['proxy_filter_remove']);
    userAgentAppend = _asBool(map['user_agent_append']);
    userAgentCompatibles = _asStringList(map['user_agent_compatibles']);
    xhwid = _asBool(map['xhwid']);
    keepDiversionRules = _asBool(map['keep_diversion_rules']);
    enableDiversionRules = _asBool(map['enable_diversion_rules']);
    reloadAfterProfileUpdate = _asBool(map['reload_after_profile_update']);
    testLatencyAfterProfileUpdate = _asBool(
      map['test_latency_after_profile_update'],
    );
    testLatencyAutoRemove = _asBool(map['test_latency_auto_remove']);
    final ps = _asString(map['proxy_strategy']);
    proxyStrategy = ProxyStrategy.values.firstWhere(
      (e) => e.name == ps,
      orElse: () => ProxyStrategy.preferProxy,
    );
    decryptPasswordAES = _asString(map['decrypt_password_aes']);
    decryptPasswordAGE = _asString(map['decrypt_password_age']);
    preferOutboundDns = _asBool(map['prefer_outbound_dns']);
    outboundDns = _asStringList(map['outbound_dns']);
    final ud = map['update_duration'];
    updateDuration = ud == null
        ? null
        : Duration(milliseconds: _asInt(ud));
    updateTime = _asString(map['update_time']);
  }
}

// ---------------------------------------------------------------------------
// Diversion (routing rule) models
// ---------------------------------------------------------------------------

/// One rule-set collected while importing profiles; consumed by the config
/// builder to emit sing-box `route.rule_set` entries.
class ServerDiversionGroupRuleSetItem {
  String type = '';
  String tag = '';
  String format = '';
  String? url;

  ServerDiversionGroupRuleSetItem clone() {
    return ServerDiversionGroupRuleSetItem()
      ..type = type
      ..tag = tag
      ..format = format
      ..url = url;
  }

  /// Derives a short display name for a remote rule-set from its URL:
  /// the last path segment without its extension
  /// (diversion_rules_screen.dart's getDiversionShortName).
  static String? getTagFromUrl(Uri uri) {
    if (uri.pathSegments.isEmpty) {
      return null;
    }
    var name = uri.pathSegments.last;
    final dot = name.lastIndexOf('.');
    if (dot > 0) {
      name = name.substring(0, dot);
    }
    return name.isEmpty ? null : name;
  }

  Map<String, dynamic> toJson() => {
    'type': type,
    'tag': tag,
    'format': format,
    'url': url,
  };

  void fromJson(Map<String, dynamic>? map) {
    if (map == null) return;
    type = _asString(map['type']);
    tag = _asString(map['tag']);
    format = _asString(map['format']);
    final u = map['url'];
    url = u == null ? null : _asString(u);
  }
}

/// A set of matchers plus the proxies they route to. When [groups] is
/// non-empty this is a logical (OR/AND) combination of its sub-groups.
class DiversionRulesGroup {
  String groupid = '';
  String name = '';
  bool or = false;

  /// Position within the owning ServerDiversionGroupItem (ServerManager
  /// sorts and re-numbers groups by it).
  int index = 0;

  /// Sub-groups for logical nesting.
  List<DiversionRulesGroup> groups = [];

  /// Target outbound tags; the built-in markers are [kProxyDirect] /
  /// [kProxyBlock].
  List<String> proxies = [];

  List<String> ruleSetBuildIn = [];
  List<String> ruleSet = [];
  List<String> package = [];
  List<String> domain = [];
  List<String> domainSuffix = [];
  List<String> domainKeyword = [];
  List<String> domainRegex = [];
  List<String> ipCidr = [];

  /// 0 = any, 4 = IPv4 only, 6 = IPv6 only (sing-box `ip_version`).
  int ipVersion = 0;

  List<int> port = [];
  List<String> portRange = [];
  List<String> network = [];
  List<String> networkType = [];
  List<String> protocol = [];
  List<String> processName = [];
  List<String> processPath = [];
  List<String> processDir = [];
  List<String> wifiSsid = [];
  List<String> wifiBssid = [];

  DiversionRulesGroup clone() {
    final ret = DiversionRulesGroup();
    ret.groupid = groupid;
    ret.name = name;
    ret.or = or;
    ret.index = index;
    ret.groups = groups.map((e) => e.clone()).toList();
    ret.proxies = List<String>.from(proxies);
    ret.ruleSetBuildIn = List<String>.from(ruleSetBuildIn);
    ret.ruleSet = List<String>.from(ruleSet);
    ret.package = List<String>.from(package);
    ret.domain = List<String>.from(domain);
    ret.domainSuffix = List<String>.from(domainSuffix);
    ret.domainKeyword = List<String>.from(domainKeyword);
    ret.domainRegex = List<String>.from(domainRegex);
    ret.ipCidr = List<String>.from(ipCidr);
    ret.ipVersion = ipVersion;
    ret.port = List<int>.from(port);
    ret.portRange = List<String>.from(portRange);
    ret.network = List<String>.from(network);
    ret.networkType = List<String>.from(networkType);
    ret.protocol = List<String>.from(protocol);
    ret.processName = List<String>.from(processName);
    ret.processPath = List<String>.from(processPath);
    ret.processDir = List<String>.from(processDir);
    ret.wifiSsid = List<String>.from(wifiSsid);
    ret.wifiBssid = List<String>.from(wifiBssid);
    return ret;
  }

  Map<String, dynamic> toJson() => {
    'groupid': groupid,
    'name': name,
    'or': or,
    'index': index,
    'groups': groups.map((e) => e.toJson()).toList(),
    'proxies': proxies,
    'rule_set_build_in': ruleSetBuildIn,
    'rule_set': ruleSet,
    'package': package,
    'domain': domain,
    'domain_suffix': domainSuffix,
    'domain_keyword': domainKeyword,
    'domain_regex': domainRegex,
    'ip_cidr': ipCidr,
    'ip_version': ipVersion,
    'port': port,
    'port_range': portRange,
    'network': network,
    'network_type': networkType,
    'protocol': protocol,
    'process_name': processName,
    'process_path': processPath,
    'process_dir': processDir,
    'wifi_ssid': wifiSsid,
    'wifi_bssid': wifiBssid,
  };

  void fromJson(Map<String, dynamic>? map) {
    if (map == null) return;
    groupid = _asString(map['groupid']);
    name = _asString(map['name']);
    or = _asBool(map['or']);
    index = _asInt(map['index']);
    groups = [];
    final gs = map['groups'];
    if (gs is List) {
      for (final g in gs) {
        if (g is Map) {
          final sub = DiversionRulesGroup();
          sub.fromJson(Map<String, dynamic>.from(g));
          groups.add(sub);
        }
      }
    }
    proxies = _asStringList(map['proxies']);
    ruleSetBuildIn = _asStringList(map['rule_set_build_in']);
    ruleSet = _asStringList(map['rule_set']);
    package = _asStringList(map['package']);
    domain = _asStringList(map['domain']);
    domainSuffix = _asStringList(map['domain_suffix']);
    domainKeyword = _asStringList(map['domain_keyword']);
    domainRegex = _asStringList(map['domain_regex']);
    ipCidr = _asStringList(map['ip_cidr']);
    ipVersion = _asInt(map['ip_version']);
    port = _asIntList(map['port']);
    portRange = _asStringList(map['port_range']);
    network = _asStringList(map['network']);
    networkType = _asStringList(map['network_type']);
    protocol = _asStringList(map['protocol']);
    processName = _asStringList(map['process_name']);
    processPath = _asStringList(map['process_path']);
    processDir = _asStringList(map['process_dir']);
    wifiSsid = _asStringList(map['wifi_ssid']);
    wifiBssid = _asStringList(map['wifi_bssid']);
  }
}

/// The diversion groups that belong to one profile.
class ServerDiversionGroupItem {
  String groupid = '';
  String urlOrPath = '';
  String remark = '';
  bool editAble = false;
  List<DiversionRulesGroup> groups = [];

  DiversionRulesGroup? getByName(String name) {
    for (final group in groups) {
      if (group.name == name) {
        return group;
      }
    }
    return null;
  }

  ServerDiversionGroupItem clone() {
    final ret = ServerDiversionGroupItem();
    ret.groupid = groupid;
    ret.urlOrPath = urlOrPath;
    ret.remark = remark;
    ret.editAble = editAble;
    ret.groups = groups.map((e) => e.clone()).toList();
    return ret;
  }

  Map<String, dynamic> toJson() => {
    'groupid': groupid,
    'url_or_path': urlOrPath,
    'remark': remark,
    'edit_able': editAble,
    'groups': groups.map((e) => e.toJson()).toList(),
  };

  void fromJson(
    Map<String, dynamic>? map,
    bool editAbleDefault,
    String groupidFallback,
  ) {
    if (map == null) return;
    groupid = _asString(map['groupid'], groupidFallback);
    urlOrPath = _asString(map['url_or_path']);
    remark = _asString(map['remark']);
    editAble = map.containsKey('edit_able')
        ? _asBool(map['edit_able'])
        : editAbleDefault;
    groups = [];
    final gs = map['groups'];
    if (gs is List) {
      for (final g in gs) {
        if (g is Map) {
          final group = DiversionRulesGroup();
          group.fromJson(Map<String, dynamic>.from(g));
          group.groupid = groupid;
          groups.add(group);
        }
      }
    }
  }
}
