// End to end through the real Brahma home server (../brahma/server, Node 24+)
// on loopback: Artha's store writes the money row and syncs; Samriddhi's Rust
// client (../samriddhi, brahma-sync's bridge_peer example, built with cargo)
// reads it and writes a wealth row; Artha syncs and reads that. Skipped when
// Node, cargo or either folder is missing.
@TestOn('vm')
@Tags(['live'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:artha/app/session.dart' show arthaIdentity;
import 'package:artha/modules/finance/bridge/money_bridge.dart';
import 'package:artha/modules/finance/domain/accounting.dart';
import 'package:artha/modules/finance/domain/ledger.dart';
import 'package:artha/modules/finance/insights/insights.dart';
import 'package:artha/modules/finance/portfolio/portfolio.dart';
import 'package:artha/modules/finance/reports/reports.dart';
import 'package:brahma_core/brahma_core.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

const _email = 'me@example.com', _password = 'correct horse battery';

void main() {
  final work = Directory.current.parent.path;
  final home = '$work/brahma/server/src/home.ts';
  final samriddhi = '$work/samriddhi';
  final v = Process.runSync('node', ['--version']);
  final major = int.tryParse(RegExp(r'v(\d+)').firstMatch('${v.stdout}')?.group(1) ?? '') ?? 0;
  final cargo = Process.runSync('cargo', ['--version']).exitCode == 0;
  final skip = v.exitCode != 0 || major < 24
      ? 'Needs Node 24 or newer'
      : !cargo || !File(home).existsSync() || !Directory(samriddhi).existsSync()
      ? 'Needs cargo, ../brahma/server and ../samriddhi'
      : null;

  late Directory dir;
  late Process server;
  late String url, setupCode;

  setUpAll(() async {
    HttpOverrides.global = null;
    if (skip != null) return;
    // Built first, so the run below is quick.
    final built = await Process.run('cargo', [
      'build',
      '-q',
      '-p',
      'brahma-sync',
      '--example',
      'bridge_peer',
    ], workingDirectory: samriddhi);
    expect(built.exitCode, 0, reason: '${built.stderr}');
    dir = await Directory.systemTemp.createTemp('artha-bridge-e2e-');
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    final init = await Process.run(
      'node',
      [home, 'init', '$port'],
      environment: {'BRAHMA_SERVER_HOME': dir.path},
    );
    expect(init.exitCode, 0);
    final env = File('${dir.path}/server.env');
    final text = await env.readAsString();
    setupCode = RegExp(r'^SETUP_CODE=(.+)$', multiLine: true).firstMatch(text)!.group(1)!;
    // Loopback only, and lifted rate limits for this throwaway server.
    await env.writeAsString(
      '${text.replaceAll(RegExp(r'^HOST=.*$', multiLine: true), 'HOST=127.0.0.1')}\nRATE_LIMIT_SCALE=1000\n',
    );
    server = await Process.start('node', [home, 'serve'], environment: {'BRAHMA_SERVER_HOME': dir.path});
    final ready = Completer<void>();
    server.stdout.transform(utf8.decoder).listen((t) {
      if (t.contains('listening') && !ready.isCompleted) ready.complete();
    });
    server.stderr.transform(utf8.decoder).listen(stderr.write);
    await ready.future.timeout(const Duration(seconds: 20));
    url = 'http://127.0.0.1:$port';
  });

  tearDownAll(() async {
    if (skip != null) return;
    server.kill();
    await server.exitCode;
    await dir.delete(recursive: true);
  });

  test(
    'Artha shares its money row with Samriddhi and reads Samriddhi’s wealth row',
    () async {
      final db = await openTestDatabase();
      addTearDown(db.close);
      final store = await Store.open(db);
      final ledger = Ledger(store);
      await ledger.seedDefaults('GBP');
      final bank = await ledger.saveAccount(name: 'Current', subtype: 'current', commodityId: 'GBP');
      final card = await ledger.saveAccount(name: 'Card', subtype: 'credit_card', commodityId: 'GBP');
      Future<void> book(String date, String acc, String cat, int amount) => ledger.saveEntry(
        simpleEntry(date: date, currency: 'GBP', accountId: acc, categoryId: cat, amount: amount, payee: 'X'),
      );
      await book('2026-10-01', bank, 'cat.salary', -300000);
      await book('2026-10-02', bank, 'cat.housing', 120000);
      await book('2026-10-05', card, 'cat.eating_out', 5000);

      const today = '2026-11-15';
      final reports = await Reports.load(db, 'GBP');
      final portfolio = await Portfolio.load(db, reports.prices, base: 'GBP', asOf: today);
      final money = await buildMoneySnapshot(
        engine: InsightEngine(db, reports, portfolio, today),
        reports: reports,
        planned: const [],
        today: today,
      );
      expect(await writeMoneySnapshot(store, money), isTrue);

      final artha = AccountService(
        KeyVault(MemorySecretStore(), arthaIdentity),
        deviceId: 'a' * 32,
        platform: 'linux',
      );
      await artha.signUp(server: url, email: _email, password: _password, invite: setupCode);
      expect((await (await artha.engine(store))!.run()).pushed, greaterThan(0));

      const wealth = WealthSnapshot(
        currency: 'GBP',
        asOf: today,
        holdingsCount: 2,
        holdingsTotal: 1250000,
        byClass: [(assetClass: 'equity', value: 1000000), (assetClass: 'cash', value: 250000)],
        netWorth: [(month: '2026-10', value: 1200000), (month: '2026-11', value: 1250000)],
        exposure: [(kind: 'currency', key: 'GBP', value: 1250000)],
      );
      final peer = await Process.run('cargo', [
        'run',
        '-q',
        '-p',
        'brahma-sync',
        '--example',
        'bridge_peer',
        '--',
        url,
        _email,
        _password,
        wealth.encode(),
      ], workingDirectory: samriddhi);
      expect(peer.exitCode, 0, reason: '${peer.stderr}');
      final seen = jsonDecode(LineSplitter.split('${peer.stdout}').last) as Map;
      expect(seen['source'], 'artha');
      expect(seen['currency'], 'GBP');
      expect(seen['liquidCash'], money.liquidCash);
      expect(seen['spend'], money.spend);
      expect(seen['debtTotal'], money.debtTotal);
      expect(seen['encoded'], money.encode(), reason: 'Rust reads exactly what Dart wrote');

      final result = await (await artha.engine(store))!.run();
      expect(result.pulled, greaterThan(0));
      final got = await readWealthSnapshot(db);
      expect(got, isNotNull);
      expect(got!.snapshot.encode(), wealth.encode());
      expect(got.snapshot.latestNetWorth!.value, 1250000);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
