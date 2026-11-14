// Conversion evidence for the Clash / mihomo YAML importer
// (lib/app/utils/auto_conf_utils.dart): each fixture under
// test/fixtures/ is fed through the real AutoConfUtils.tryConvert entry
// point and the produced ProxyConfig tags / raw payloads and diversion
// groups are asserted.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:karing/app/utils/auto_conf_utils.dart';
import 'package:vpn_service/state.dart';

Future<(ServerConfigGroupItem, ServerDiversionGroupItem)> convert(
  String fixture, {
  bool withDiversion = true,
}) async {
  final item = ServerConfigGroupItem()..groupid = 'grp';
  final diversion = ServerDiversionGroupItem()..groupid = 'grp';
  final ruleSets = <ServerDiversionGroupRuleSetItem>[];
  final error = await AutoConfUtils.tryConvert(
    'test/fixtures/$fixture',
    true,
    false,
    item,
    ruleSets,
    withDiversion ? diversion : null,
    null,
  );
  expect(error, isNull, reason: 'tryConvert failed for $fixture: $error');
  return (item, diversion);
}

void main() {
  test('clash-basic: protocols, plugins, groups, rules', () async {
    final (item, diversion) = await convert('clash-basic.yaml');
    final tags = item.servers.map((s) => s.tag).toList();
    expect(
      tags,
      containsAll([
        'SS-Plain',
        'SS-Obfs',
        'VMess-WS',
        'VLESS-Reality',
        'Trojan-01',
        'WG-Home',
        'Auto',
        'Main',
      ]),
    );

    final ssObfs = item.getByTag('SS-Obfs')!;
    expect(ssObfs.raw['plugin'], 'obfs-local');
    expect(ssObfs.raw['plugin_opts'], 'obfs=tls;obfs-host=cdn.example.com');

    final vmess = item.getByTag('VMess-WS')!;
    expect(vmess.raw['transport']['type'], 'ws');
    expect(vmess.raw['transport']['path'], '/ray');
    expect(vmess.raw['transport']['headers']['Host'], 'vmess.example.com');
    expect(vmess.raw['tls']['server_name'], 'vmess.example.com');
    expect(vmess.raw['tls']['insecure'], true);

    final vless = item.getByTag('VLESS-Reality')!;
    expect(vless.raw['flow'], 'xtls-rprx-vision');
    expect(vless.raw['tls']['reality']['public_key'], 'PUBLICKEYBASE64');
    expect(vless.raw['tls']['reality']['short_id'], 'abcd1234');
    expect(vless.raw['tls']['utls']['fingerprint'], 'chrome');

    final wg = item.getByTag('WG-Home')!;
    expect(wg.type, 'wireguard');
    expect(wg.server, '120.48.25.99');
    expect(wg.serverport, 51820);
    expect(wg.raw['peers'][0]['public_key'], 'PUBLICKEYBASE64=');
    expect(wg.raw['peers'][0]['allowed_ips'], ['10.66.0.0/24']);

    final auto = item.getByTag('Auto')!;
    expect(auto.type, 'urltest');
    expect(auto.raw['outbounds'], ['SS-Plain', 'VMess-WS']);
    expect(auto.raw['interval'], '300s');
    expect(auto.raw['tolerance'], 50);

    final main = item.getByTag('Main')!;
    expect(main.type, 'selector');
    expect(main.raw['outbounds'], [
      'Auto',
      'VLESS-Reality',
      'Trojan-01',
      'WG-Home',
      'direct',
    ]);
    expect(main.raw['default'], 'Auto');

    // 11 rules, only SRC-IP-CIDR unconvertible -> 10 groups.
    expect(diversion.groups.length, 10);
    final byName = {for (final g in diversion.groups) g.name: g};
    expect(byName['rule-1']!.domainSuffix, ['google.com']);
    expect(byName['rule-1']!.proxies, ['Main']);
    expect(byName['rule-4']!.ipCidr, ['192.168.0.0/16']);
    expect(byName['rule-4']!.proxies, ['direct']);
    expect(byName['rule-5']!.ruleSetBuildIn, ['geoip:cn']);
    expect(byName['rule-6']!.ruleSetBuildIn, ['geosite:category-ads-all']);
    expect(byName['rule-6']!.proxies, ['block']);
    expect(byName['rule-7']!.port, [853]);
    expect(byName['rule-9']!.ruleSet, ['myprovider']);
    expect(byName.containsKey('rule-10'), isFalse);
    expect(byName['rule-11']!.proxies, ['Main']);
    expect(AutoConfUtils.skippedUnconvertible, 1);
  });

  test('clash-full: hy2/tuic/socks/http, fallback, skips', () async {
    final (item, _) = await convert('clash-full.yaml');
    final tags = item.servers.map((s) => s.tag).toList();
    expect(
      tags,
      containsAll([
        'HY2-01',
        'HY1-01',
        'TUIC-01',
        'SOCKS-01',
        'HTTP-01',
        'VLESS-gRPC',
        'Fallback',
        'Pick',
      ]),
    );
    expect(tags, isNot(contains('Balance')));
    expect(tags, isNot(contains('VMess-XHTTP')));
    expect(tags, isNot(contains('SSR-Old')));
    expect(tags, isNot(contains('Snell-Old')));

    final hy2 = item.getByTag('HY2-01')!;
    expect(hy2.raw['obfs']['type'], 'salamander');
    expect(hy2.raw['obfs']['password'], 'obfs-secret');
    expect(hy2.raw['up_mbps'], 30);
    expect(hy2.raw['down_mbps'], 100);

    final tuic = item.getByTag('TUIC-01')!;
    expect(tuic.raw['congestion_control'], 'bbr');
    expect(tuic.raw['tls']['alpn'], ['h3']);

    final grpc = item.getByTag('VLESS-gRPC')!;
    expect(grpc.raw['transport']['type'], 'grpc');
    expect(grpc.raw['transport']['service_name'], 'gun-service');

    final fallback = item.getByTag('Fallback')!;
    expect(fallback.type, 'urltest');
    expect(fallback.raw['interval'], '180s');
    expect(fallback.raw['outbounds'], ['HY2-01', 'TUIC-01']);

    // xhttp vmess + ssr + snell + load-balance group.
    expect(AutoConfUtils.skippedUnconvertible, 4);
  });

  test('clash-subscription base64-wrapped decodes and converts', () async {
    final plain = await File(
      'test/fixtures/clash-subscription.yaml',
    ).readAsString();
    final wrapped = File(
      '${Directory.systemTemp.path}/clash_b64_fixture.txt',
    );
    await wrapped.writeAsString(base64Encode(utf8.encode(plain)));
    final item = ServerConfigGroupItem()..groupid = 'grp';
    final error = await AutoConfUtils.tryConvert(
      wrapped.path,
      true,
      false,
      item,
      <ServerDiversionGroupRuleSetItem>[],
      null,
      null,
    );
    expect(error, isNull);
    expect(
      item.servers.map((s) => s.tag),
      containsAll(['Sub-SS', 'Sub-Trojan', 'Sub-Select']),
    );
  });

  test('clash-subscription: no rules section, works without diversion',
      () async {
    final (item, _) = await convert(
      'clash-subscription.yaml',
      withDiversion: false,
    );
    final tags = item.servers.map((s) => s.tag).toList();
    expect(tags, containsAll(['Sub-SS', 'Sub-Trojan', 'Sub-Select']));
    final group = item.getByTag('Sub-Select')!;
    expect(group.raw['outbounds'], ['Sub-SS', 'Sub-Trojan', 'direct']);
    expect(AutoConfUtils.skippedUnconvertible, 0);
  });
}
