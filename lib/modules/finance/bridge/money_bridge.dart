// The money bridge to Samriddhi: Artha writes one `bridge_money_snapshot`
// row (cash, debts, the last full month's flows, the 90-day forecast and how
// fresh each account is) and only reads Samriddhi's `bridge_wealth_snapshot`.
// Both travel end-to-end encrypted with the rest of the synced data.

import 'package:brahma_core/brahma_core.dart';
import 'package:drift/drift.dart';

import '../../../db/database.dart';
import '../insights/forecast.dart';
import '../insights/insights.dart';
import '../reports/reports.dart';

/// Works out the money row from the ledger as of [today].
Future<MoneySnapshot> buildMoneySnapshot({
  required InsightEngine engine,
  required Reports reports,
  required List<PlannedRow> planned,
  required String today,
}) async {
  final metrics = await engine.metrics();
  final recurring = await engine.recurring();
  // The last complete month: the running one is still changing.
  final from = monthStart(addMonths(today, -1));
  final to = addDays(monthStart(today), -1);
  final pnl = await reports.incomeStatement(from, to);
  final sheet = await reports.balanceSheet(today);
  final spend = [
    for (final l in pnl.expenses)
      if (l.amount != 0) (category: l.account.name, amount: l.amount),
  ]..sort((a, b) => b.amount != a.amount ? b.amount.compareTo(a.amount) : a.category.compareTo(b.category));
  final debts = [
    for (final l in sheet.liabilities)
      if ((l.baseValue ?? 0) != 0) (name: l.account.name, balance: -(l.baseValue ?? 0)),
  ]..sort((a, b) => a.name.compareTo(b.name));
  final fixed = recurring
      .where((r) => r.amount < 0)
      .fold(0, (s, r) => s + r.cadence.perMonth(r.amount).abs());
  CashForecastSummary? forecast;
  if (metrics.liquid != 0 || recurring.isNotEmpty || planned.isNotEmpty) {
    final f = forecastCash(
      liquid: metrics.liquid,
      recurring: recurring,
      monthlySpend: metrics.monthlySpend,
      today: today,
      oneOffs: [for (final p in planned) ForecastEvent(p.date, p.label, p.amount, id: p.id)],
    );
    var low = f.opening, lowDate = today;
    for (var i = 0; i < f.balances.length; i++) {
      if (f.balances[i] < low) {
        low = f.balances[i];
        lowDate = f.dateAt(i);
      }
    }
    forecast = (days: f.days, start: f.opening, end: f.closing, low: low, lowDate: lowDate);
  }
  final fresh = await engine.freshnessRows();
  return MoneySnapshot(
    currency: reports.base,
    month: from.substring(0, 7),
    asOf: today,
    income: pnl.totalIncome,
    spend: pnl.totalExpenses,
    spendByCategory: spend,
    fixedCosts: fixed,
    liquidCash: metrics.liquid,
    debts: debts,
    forecast: forecast,
    freshness: [for (final r in fresh) (account: r.name, lastStatement: r.statement ?? r.imported ?? '')]
      ..sort((a, b) => a.account.compareTo(b.account)),
  );
}

/// The same snapshot dated [asOf], so a new day alone is not a change.
MoneySnapshot _dated(MoneySnapshot s, String asOf) => MoneySnapshot(
  currency: s.currency,
  month: s.month,
  asOf: asOf,
  income: s.income,
  spend: s.spend,
  spendByCategory: s.spendByCategory,
  fixedCosts: s.fixedCosts,
  liquidCash: s.liquidCash,
  debts: s.debts,
  forecast: s.forecast,
  freshness: s.freshness,
);

/// The stored money row, or null.
Future<MoneySnapshot?> storedMoneySnapshot(AppDatabase db) async {
  final row = await (db.select(
    db.bridgeMoneySnapshot,
  )..where((r) => r.id.equals(MoneySnapshot.rowId) & r.deleted.not())).getSingleOrNull();
  return row == null ? null : MoneySnapshot.parse(row.snapshot);
}

/// Writes the money row when it differs from the stored one (its date
/// aside). True when it wrote.
Future<bool> writeMoneySnapshot(Store store, MoneySnapshot next, {DateTime? now}) async {
  final db = store.db as AppDatabase;
  final prev = await storedMoneySnapshot(db);
  if (prev != null && _dated(next, prev.asOf).encode() == prev.encode()) return false;
  await store.save(
    db.bridgeMoneySnapshot,
    BridgeMoneySnapshotCompanion.insert(
      id: MoneySnapshot.rowId,
      source: 'artha',
      snapshot: Value(next.encode()),
      updated: (now ?? DateTime.now()).toUtc().toIso8601String(),
      deleted: const Value(false),
    ),
    MoneySnapshot.rowId,
  );
  return true;
}

/// Samriddhi's wealth row with when it last changed; null when none arrived.
Future<({WealthSnapshot snapshot, String updated})?> readWealthSnapshot(AppDatabase db) async {
  final row = await (db.select(
    db.bridgeWealthSnapshot,
  )..where((r) => r.id.equals(WealthSnapshot.rowId) & r.deleted.not())).getSingleOrNull();
  if (row == null) return null;
  final s = WealthSnapshot.parse(row.snapshot);
  return s.isEmpty ? null : (snapshot: s, updated: row.updated);
}
