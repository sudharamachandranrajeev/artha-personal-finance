import 'package:artha/db/database.dart';
import 'package:artha/modules/finance/bridge/money_bridge.dart';
import 'package:artha/modules/finance/domain/accounting.dart';
import 'package:artha/modules/finance/domain/ledger.dart';
import 'package:artha/modules/finance/insights/insights.dart';
import 'package:artha/modules/finance/portfolio/portfolio.dart';
import 'package:artha/modules/finance/reports/reports.dart';
import 'package:brahma_core/brahma_core.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  late AppDatabase db;
  late Store store;
  late Ledger ledger;
  late String bank;

  setUp(() async {
    db = await openTestDatabase();
    store = await Store.open(db);
    ledger = Ledger(store);
    await ledger.seedDefaults('GBP');
    bank = await ledger.saveAccount(name: 'Current', subtype: 'current', commodityId: 'GBP');
    final card = await ledger.saveAccount(name: 'Card', subtype: 'credit_card', commodityId: 'GBP');
    Future<void> book(String date, String acc, String cat, int amount) => ledger.saveEntry(
      simpleEntry(date: date, currency: 'GBP', accountId: acc, categoryId: cat, amount: amount, payee: 'X'),
    );
    for (final ym in ['2026-09', '2026-10']) {
      await book('$ym-01', bank, 'cat.salary', -300000);
      await book('$ym-02', bank, 'cat.housing', 120000);
      await book('$ym-10', bank, 'cat.groceries', 30000);
    }
    await book('2026-10-05', card, 'cat.eating_out', 5000);
  });
  tearDown(() => db.close());

  Future<MoneySnapshot> build(String today) async {
    final reports = await Reports.load(db, 'GBP');
    final portfolio = await Portfolio.load(db, reports.prices, base: 'GBP', asOf: today);
    return buildMoneySnapshot(
      engine: InsightEngine(db, reports, portfolio, today),
      reports: reports,
      planned: const [],
      today: today,
    );
  }

  test('the money row covers the last full month, cash, debts and freshness', () async {
    final s = await build('2026-11-15');
    expect((s.currency, s.month, s.asOf), ('GBP', '2026-10', '2026-11-15'));
    expect((s.income, s.spend), (300000, 155000));
    expect(s.spendByCategory.first.amount, 120000);
    expect(s.liquidCash, 600000 - 300000);
    expect(s.debts.single, (name: 'Card', balance: 5000));
    expect(s.forecast, isNotNull);
    expect(s.freshness.map((f) => f.account), containsAll(['Card', 'Current']));
    // Same text the Rust side reads.
    expect(MoneySnapshot.parse(s.encode()).encode(), s.encode());
  });

  test('the row is written only when it changed', () async {
    expect(await writeMoneySnapshot(store, await build('2026-11-15')), isTrue);
    expect(await writeMoneySnapshot(store, await build('2026-11-15')), isFalse);
    await ledger.saveBalanceCheck(bank, '2026-11-14', 300000);
    expect(await writeMoneySnapshot(store, await build('2026-11-16')), isTrue);
    final row = await db.select(db.bridgeMoneySnapshot).getSingle();
    expect((row.id, row.source), (MoneySnapshot.rowId, 'artha'));
    final out = await db.customSelect("SELECT * FROM outbox WHERE entity = 'bridge_money_snapshot'").get();
    expect(out, isNotEmpty, reason: 'the row is queued to sync');
  });

  test('Samriddhi’s wealth row is read, and missing or empty reads as null', () async {
    expect(await readWealthSnapshot(db), isNull);
    await db
        .into(db.bridgeWealthSnapshot)
        .insert(
          BridgeWealthSnapshotCompanion.insert(
            id: WealthSnapshot.rowId,
            source: 'samriddhi',
            snapshot: const Value(
              '{"v":1,"currency":"GBP","asOf":"2026-11-15","holdings":{"count":2,"total":900000,"byClass":[]},'
              '"netWorth":[{"month":"2026-11","value":900000}],"exposure":[]}',
            ),
            updated: '2026-11-15T10:00:00Z',
          ),
        );
    final w = await readWealthSnapshot(db);
    expect((w!.snapshot.holdingsTotal, w.snapshot.latestNetWorth!.value), (900000, 900000));
  });
}
