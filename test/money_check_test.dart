import 'package:artha/db/database.dart';
import 'package:artha/modules/finance/domain/accounting.dart';
import 'package:artha/modules/finance/domain/ledger.dart';
import 'package:artha/modules/finance/insights/catalogue.dart';
import 'package:artha/modules/finance/insights/forecast.dart';
import 'package:artha/modules/finance/insights/insights.dart';
import 'package:artha/modules/finance/insights/money_check.dart';
import 'package:artha/modules/finance/insights/world.dart';
import 'package:artha/modules/finance/portfolio/portfolio.dart';
import 'package:artha/modules/finance/reports/reports.dart';
import 'package:brahma_core/brahma_core.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

/// Complete months ending with [last] (yyyy-MM), oldest first.
List<MonthFlow> months(String last, List<(int income, int spend, int essential)> xs) {
  final start = addMonths('$last-01', -(xs.length - 1));
  return [
    for (var i = 0; i < xs.length; i++)
      MonthFlow(addMonths(start, i).substring(0, 7))
        ..income = xs[i].$1
        ..expenses = xs[i].$2
        ..essential = xs[i].$3,
  ];
}

Recurring rec(String label, int amount, String category, {Cadence c = Cadence.monthly, int? from}) =>
    Recurring(label, label, c, amount, '2026-11-01', category, 4, priceFrom: from);

void main() {
  group('fixed-cost ratio', () {
    test('essential spending plus non-essential recurring, over the last three months', () {
      final m = fixedCostRatio(
        months('2026-10', [
          (0, 0, 0),
          (999999, 999999, 999999),
          (300000, 200000, 140000),
          (300000, 210000, 150000),
          (300000, 220000, 160000),
        ]),
        [
          rec('RENT', -100000, 'cat.housing'),
          rec('TV', -1500, 'cat.subscriptions'),
          rec('GYM', -1000, 'x', c: Cadence.weekly),
          rec('PAY', 300000, 'cat.salary'),
        ],
        {'cat.housing'},
      );
      final gym = Cadence.weekly.perMonth(1000);
      expect(m.value, closeTo((150000 + 1500 + gym) / 300000, 1e-9));
      expect(m.verdict, Verdict.watch);
      expect(m.inputs.map((i) => i.amount), [300000, 150000, 1500 + gym]);
      expect(m.dataDate, contains('Aug 2026'));
      expect(m.dataDate, contains('Oct 2026'));
      expect(m.source.convention, isTrue);
      expect(m.note, isNull);
    });

    test('no income gives no ratio, and one month says so', () {
      final none = fixedCostRatio(months('2026-10', [(0, 50000, 40000)]), const [], const {});
      expect((none.value, none.verdict, none.display), (null, Verdict.unknown, '–'));
      expect(none.note, contains('No income'));
      final one = fixedCostRatio(months('2026-10', [(200000, 150000, 130000)]), const [], const {});
      expect(one.verdict, Verdict.flag);
      expect(one.note, contains('one month'));
      final empty = fixedCostRatio(const [], const [], const {});
      expect(empty.verdict, Verdict.unknown);
      expect(empty.note, contains('complete month'));
    });
  });

  group('subscription creep', () {
    const today = '2026-11-16';
    List<Txn> monthly(String text, int amount, String first, int n, {int? lastAmount}) => [
      for (var i = 0; i < n; i++)
        Txn(
          addMonths(first, i),
          text,
          i == n - 1 && lastAmount != null ? lastAmount : amount,
          'cat.subscriptions',
        ),
    ];

    test('finds new and dearer payments with their yearly cost; old and cheaper ones are left', () {
      final txns = [
        ...monthly('OLD GYM', -3000, '2025-12-10', 12),
        ...monthly('NEWTV', -1299, '2026-09-05', 3),
        ...monthly('MUSICBOX', -1099, '2026-05-15', 6, lastAmount: -1299),
        ...monthly('CHEAPER', -2000, '2026-05-15', 6, lastAmount: -1500),
      ];
      final c = subscriptionCreep(detectRecurring(txns, today), txns, today);
      expect(
        [for (final i in c.items) (i.recurring.label, i.isNew, i.yearly)],
        [('NEWTV', true, 1299 * 12), ('MUSICBOX', false, 200 * 12)],
      );
      expect(c.items.first.since, '2026-09-05');
      expect(c.measure.verdict, Verdict.watch);
      expect(c.measure.value, (1299 + 200) * 12);
      expect(c.measure.inputs[1].amount, (3000 + 1299 + 1299 + 1500) * 12);
    });

    test('a user-added item is matched by its pattern', () {
      final txns = monthly('Card payment BOXCLUB 123', -2500, '2026-10-02', 2);
      final added = Recurring(
        'manual/1',
        'Box club',
        Cadence.monthly,
        -2500,
        '2026-11-02',
        'x',
        2,
        id: '1',
        pattern: 'boxclub',
      );
      final c = subscriptionCreep([added], txns, today);
      expect(c.items.single.isNew, isTrue);
      expect(c.items.single.since, '2026-10-02');
    });

    test('nothing recurring is fine and says why', () {
      final c = subscriptionCreep(const [], const [], today);
      expect(c.items, isEmpty);
      expect((c.measure.verdict, c.measure.display), (Verdict.good, 'None'));
      expect(c.measure.note, contains('No recurring'));
    });
  });

  group('lifestyle inflation', () {
    test('needs 15 complete months', () {
      final m = lifestyleInflation(months('2026-10', [for (var i = 0; i < 14; i++) (300000, 200000, 0)]));
      expect(m.verdict, Verdict.unknown);
      expect(m.note, contains('14 recorded'));
      expect(lifestyleInflation(const []).note, contains('0 recorded'));
    });

    test('last 3 months against the same months a year earlier', () {
      final xs = [for (var i = 0; i < 15; i++) i < 3 ? (300000, 200000, 0) : (330000, 240000, 0)];
      final m = lifestyleInflation(months('2026-10', xs));
      // Spending +20%, income +10%.
      expect(m.value, closeTo(0.10, 1e-9));
      expect(m.verdict, Verdict.flag);
      expect(m.formula, contains('same months a year earlier'));
    });

    test('12 months against the 12 before; spending slower than income is good', () {
      final xs = [for (var i = 0; i < 24; i++) i < 12 ? (300000, 200000, 0) : (315000, 202000, 0)];
      final m = lifestyleInflation(months('2026-10', xs));
      expect(m.value, closeTo(0.01 - 0.05, 1e-9));
      expect(m.verdict, Verdict.good);
      expect(m.formula, contains('12 before'));
    });

    test('no income in the earlier period shows spending growth only', () {
      final xs = [for (var i = 0; i < 15; i++) i < 3 ? (0, 200000, 0) : (300000, 220000, 0)];
      final m = lifestyleInflation(months('2026-10', xs));
      expect(m.verdict, Verdict.unknown);
      expect(m.inputs.first.text, '+10.0%');
      expect(m.note, contains('No income'));
    });
  });

  group('ONS benchmarks and cut cards', () {
    test('groups categories like ONS and flags 1.5x the average', () {
      final rows = compareWithOns({'cat.groceries': 50000, 'cat.transport': 5000, 'cat.car': 4000}, 'GBP');
      expect([for (final b in rows) b.line.id], ['transport', 'food']);
      final food = rows.last;
      expect(food.theirs, (7370 * 52 / 12).round());
      expect(food.verdict, Verdict.flag);
      expect(rows.first.yours, 9000);
      expect(rows.first.verdict, Verdict.good);
      final m = onsMeasure(rows, 'GBP', 'Aug to Oct 2026');
      expect(m.verdict, Verdict.flag);
      expect(m.inputs.last.text, contains('unconfirmed'));
      expect(m.source.url, OnsFamilySpending.url);
    });

    test('only for a GBP base', () {
      expect(compareWithOns({'cat.groceries': 50000}, 'EUR'), isEmpty);
      expect(onsMeasure(const [], 'EUR', '').note, contains('GBP'));
    });

    test('cut cards carry the yearly saving and the reason, biggest first', () {
      const today = '2026-11-16';
      final txns = [
        for (var i = 0; i < 3; i++) Txn(addMonths('2026-09-05', i), 'NEWTV', -1299, 'cat.subscriptions'),
      ];
      final creep = subscriptionCreep(detectRecurring(txns, today), txns, today);
      final cards = cutThis(creep, compareWithOns({'cat.groceries': 50000}, 'GBP'), 'GBP');
      expect(cards.map((c) => c.id), ['ons/food', 'new/-newtv']);
      expect(cards.first.yearly, (50000 - (7370 * 52 / 12).round()) * 12);
      expect(cards.last.yearly, 1299 * 12);
      expect(cards.last.why, contains('a year'));
      expect(cards.first.why, contains('not a judgement'));
    });
  });

  group('emergency cushion', () {
    const market = MarketSnapshot(
      bankRate: 4.0,
      bankRateDate: '2026-11-05',
      cpi: 3.5,
      cpiMonth: 'September 2026',
    );

    test('months of essentials against the target, with the shortfall', () {
      final six = emergencyCushion(
        liquid: 600000,
        essentialMonthly: 100000,
        spendMonthly: 150000,
        target: 6,
        asOf: '2026-11-16',
      );
      expect((six.months, six.shortfall, six.measure.verdict), (6.0, 0, Verdict.good));
      final nine = emergencyCushion(
        liquid: 600000,
        essentialMonthly: 100000,
        spendMonthly: 150000,
        target: 9,
        asOf: '2026-11-16',
      );
      expect((nine.shortfall, nine.measure.verdict), (300000, Verdict.watch));
      expect(nine.measure.display, '6.0 of 9 months');
      final low = emergencyCushion(
        liquid: 100000,
        essentialMonthly: 100000,
        spendMonthly: 0,
        target: 3,
        asOf: '2026-11-16',
      );
      expect(low.measure.verdict, Verdict.flag);
    });

    test('falls back to all spending, and with none says what it needs', () {
      final all = emergencyCushion(
        liquid: 300000,
        essentialMonthly: 0,
        spendMonthly: 100000,
        target: 6,
        asOf: '2026-11-16',
      );
      expect(all.months, 3.0);
      expect(all.measure.note, contains('essential'));
      final none = emergencyCushion(
        liquid: 300000,
        essentialMonthly: 0,
        spendMonthly: 0,
        target: 6,
        asOf: '2026-11-16',
      );
      expect((none.months, none.measure.verdict, none.shortfall), (null, Verdict.unknown, 0));
    });

    test('notes Bank Rate and inflation from the live feed', () {
      final c = emergencyCushion(
        liquid: 1,
        essentialMonthly: 1,
        spendMonthly: 1,
        target: 6,
        market: market,
        asOf: '2026-11-16',
      );
      expect(c.rateNote, contains('3.5%'));
      expect(c.rateNote, contains('4.00%'));
      expect(c.rateNote, contains('September 2026'));
      expect(
        emergencyCushion(
          liquid: 1,
          essentialMonthly: 1,
          spendMonthly: 1,
          target: 6,
          asOf: '2026-11-16',
        ).rateNote,
        isNull,
      );
    });
  });

  group('freshness', () {
    test('newest statement or import; a hand entry when neither; nothing is not nagged', () {
      final f = accountFreshness(
        [
          (
            id: 'a',
            name: 'Old',
            statement: '2026-10-01',
            imported: '2026-09-20',
            entry: '2026-10-03',
            nudge: true,
          ),
          (
            id: 'b',
            name: 'Fresh',
            statement: '2026-10-01',
            imported: '2026-11-10',
            entry: '2026-11-10',
            nudge: true,
          ),
          (id: 'c', name: 'Hand', statement: null, imported: null, entry: '2026-11-15', nudge: true),
          (id: 'd', name: 'Empty', statement: null, imported: null, entry: null, nudge: true),
          (id: 'e', name: 'Ahead', statement: null, imported: '2026-11-20', entry: null, nudge: true),
        ],
        '2026-11-16',
        35,
      );
      final by = {for (final x in f) x.accountId: x};
      expect((by['a']!.source, by['a']!.days, by['a']!.stale), ('statement', 46, true));
      expect(by['a']!.label, 'Last statement 46 days ago');
      expect((by['b']!.source, by['b']!.days, by['b']!.stale), ('import', 6, false));
      expect(by['c']!.label, 'Last entry yesterday');
      expect((by['d']!.days, by['d']!.stale, by['d']!.label), (null, false, 'Nothing imported yet'));
      expect(by['e']!.days, 0);
      expect(f.first.accountId, 'a');
      // The nudge threshold is the user's.
      expect(
        accountFreshness(
          [(id: 'a', name: 'x', statement: '2026-10-01', imported: null, entry: null, nudge: true)],
          '2026-11-16',
          60,
        ).single.stale,
        isFalse,
      );
      // A pension or property is shown with its age but never nagged about.
      final pension = accountFreshness(
        [(id: 'p', name: 'Pension', statement: null, imported: null, entry: '2025-01-01', nudge: false)],
        '2026-11-16',
        35,
      ).single;
      expect((pension.stale, pension.label), (false, 'Last entry 684 days ago'));
    });
  });

  group('weekly recap', () {
    test('week and month so far, per day left against budgets, top merchants, bills, next step', () {
      const today = '2026-11-18'; // Wednesday
      final r = weeklyRecap(
        items: const [
          SpendItem('2026-11-02', 'Fresh Market', 20000, 'cat.groceries'),
          SpendItem('2026-11-16', 'Fresh Market 0042', 10000, 'cat.groceries'),
          SpendItem('2026-11-17', 'Noodle House', 3000, 'cat.eating_out'),
          SpendItem('2026-11-17', 'Noodle House', -500, 'cat.eating_out'),
          SpendItem('2026-11-19', 'Future', 99999, 'cat.groceries'),
        ],
        today: today,
        budgets: const {'cat.groceries': 40000, 'cat.eating_out': 0},
        usualMonth: 150000,
        recurring: [
          Recurring('tv', 'TV', Cadence.monthly, -1299, '2026-10-20', 'x', 4),
          Recurring('late', 'Late bill', Cadence.monthly, -5000, '2026-10-10', 'x', 4),
          Recurring('pay', 'Pay', Cadence.monthly, 300000, '2026-10-20', 'x', 4),
          Recurring('later', 'Later', Cadence.monthly, -100, '2026-11-01', 'x', 4),
        ],
        oneOffs: const [ForecastEvent('2026-11-24', 'MOT', -5500), ForecastEvent('2026-11-20', 'Gift', 2000)],
        base: 'GBP',
      );
      expect(r.weekFrom, '2026-11-16');
      expect((r.spentWeek, r.spentMonth), (12500, 32500));
      expect((r.plan, r.planSpent, r.planLabel), (40000, 30000, 'your budgets'));
      expect(r.daysLeft, 13);
      expect(r.perDayLeft, 10000 ~/ 13);
      // 30000 of 40000 by day 18 of 30 is ahead of an even pace.
      expect(r.onPace, isFalse);
      expect(r.nextStep, contains('a day'));
      expect(r.topMerchants.first, (label: 'Fresh Market', amount: 30000));
      expect(
        [for (final b in r.billsDue) (b.date, b.label)],
        [('2026-11-18', 'Late bill'), ('2026-11-20', 'TV'), ('2026-11-24', 'MOT')],
      );
    });

    test('with no budgets the plan is a usual month; with no history, no per-day figure', () {
      final r = weeklyRecap(
        items: const [],
        today: '2026-02-01',
        budgets: const {},
        usualMonth: 0,
        recurring: const [],
        base: 'GBP',
      );
      expect((r.plan, r.perDayLeft, r.onPace), (0, null, true));
      expect(r.daysLeft, 28);
      expect(r.nextStep, contains('Nothing needs you'));
    });

    test('next step order: stale account, then cushion, then a new subscription', () {
      final stale = [const Freshness('a', 'Everyday', days: 50, source: 'import', stale: true)];
      final cushion = emergencyCushion(
        liquid: 100000,
        essentialMonthly: 100000,
        spendMonthly: 0,
        target: 6,
        asOf: '2026-11-16',
      );
      WeeklyRecap go({List<Freshness> f = const [], Cushion? c}) => weeklyRecap(
        items: const [],
        today: '2026-11-16',
        budgets: const {},
        usualMonth: 100000,
        recurring: const [],
        base: 'GBP',
        freshness: f,
        cushion: c,
      );
      expect(go(f: stale, c: cushion).nextStep, contains('Everyday'));
      expect(go(c: cushion).nextStep, contains('${money(41667, 'GBP')} a month'));
    });

    test('weeks start on Monday across the clock changes', () {
      expect(weekStart('2026-03-29'), '2026-03-23'); // Sunday, clocks go forward
      expect(weekStart('2026-03-30'), '2026-03-30');
      expect(weekStart('2026-10-25'), '2026-10-19'); // Sunday, clocks go back
      expect(weekStart('2026-10-26'), '2026-10-26');
      expect(weekStart('2027-01-01'), '2026-12-28');
      expect(daysInMonth('2028-02-10'), 29);
      expect(daysInMonth('2026-03-29'), 31);
    });
  });

  group('forecast calendar', () {
    test('one day per forecast day, with events, change and the lowest day, across the clock change', () {
      final f = forecastCash(
        liquid: 50000,
        recurring: [Recurring('rent', 'RENT', Cadence.monthly, -60000, '2026-02-28', 'x', 4)],
        monthlySpend: 60000,
        today: '2026-03-27',
        days: 40,
      );
      final days = f.calendar();
      expect(days.length, 40);
      expect(
        [for (final d in days.take(4)) d.date],
        ['2026-03-28', '2026-03-29', '2026-03-30', '2026-03-31'],
      );
      final rent = days.firstWhere((d) => d.events.isNotEmpty);
      expect(rent.date, '2026-03-28');
      expect(rent.change, -60000);
      expect(days.where((d) => d.lowest).single.date, f.lowest.date);
      expect(days.last.balance, f.closing);
      expect(days.fold(50000, (s, d) => s + d.change), f.closing);
    });
  });

  group('from the ledger', () {
    late AppDatabase db;
    late Ledger ledger;
    setUp(() async {
      db = await openTestDatabase();
      ledger = Ledger(await Store.open(db));
      await ledger.seedDefaults('GBP');
    });
    tearDown(() => db.close());

    Future<InsightEngine> engine(String today) async {
      final reports = await Reports.load(db, 'GBP');
      return InsightEngine(
        db,
        reports,
        await Portfolio.load(db, reports.prices, base: 'GBP', asOf: today),
        today,
      );
    }

    test('spending in another currency counts at that day\'s rate; one with no rate is skipped', () async {
      final gbp = await ledger.saveAccount(name: 'Current', subtype: 'current', commodityId: 'GBP');
      final usd = await ledger.saveAccount(name: 'Dollar', subtype: 'current', commodityId: 'USD');
      final inr = await ledger.saveAccount(name: 'Rupee', subtype: 'current', commodityId: 'INR');
      await ledger.savePrice('USD', 'GBP', '2026-11-01', Rate.parse('0.8'));
      await ledger.saveEntry(
        simpleEntry(
          date: '2026-11-10',
          currency: 'GBP',
          accountId: gbp,
          categoryId: 'cat.groceries',
          amount: 1000,
          payee: 'Shop',
        ),
      );
      await ledger.saveEntry(
        simpleEntry(
          date: '2026-11-11',
          currency: 'USD',
          accountId: usd,
          categoryId: 'cat.eating_out',
          amount: 5000,
          payee: 'Diner',
        ),
      );
      await ledger.saveEntry(
        simpleEntry(
          date: '2026-11-12',
          currency: 'INR',
          accountId: inr,
          categoryId: 'cat.eating_out',
          amount: 90000,
          payee: 'Dhaba',
        ),
      );
      await ledger.saveEntry(
        simpleEntry(
          date: '2026-11-12',
          currency: 'GBP',
          accountId: gbp,
          categoryId: 'cat.salary',
          amount: -90000,
        ),
      );
      final items = await (await engine('2026-11-16')).spendItems('2026-11-01');
      expect({for (final i in items) i.label: i.amount}, {'Shop': 1000, 'Diner': 4000});
    });

    test('freshness reads statements, imports and entries, and skips holdings and closed accounts', () async {
      final bank = await ledger.saveAccount(name: 'Current', subtype: 'current', commodityId: 'GBP');
      final card = await ledger.saveAccount(name: 'Card', subtype: 'credit_card', commodityId: 'GBP');
      await ledger.saveAccount(name: 'Closed', subtype: 'savings', commodityId: 'GBP', closed: true);
      await ledger.saveEntry(
        simpleEntry(
          date: '2026-10-01',
          currency: 'GBP',
          accountId: bank,
          categoryId: 'cat.groceries',
          amount: 100,
          importRef: 'csv:1',
        ),
      );
      await ledger.saveEntry(
        simpleEntry(
          date: '2026-11-01',
          currency: 'GBP',
          accountId: bank,
          categoryId: 'cat.groceries',
          amount: 100,
        ),
      );
      await ledger.saveBalanceCheck(card, '2026-09-30', -5000);
      final rows = await (await engine('2026-11-16')).freshnessRows();
      final by = {for (final r in rows) r.name: r};
      expect(by.keys.toSet(), {'Current', 'Card'});
      expect(
        (by['Current']!.imported, by['Current']!.entry, by['Current']!.statement),
        ('2026-10-01', '2026-11-01', null),
      );
      expect(by['Card']!.statement, '2026-09-30');
      expect((by['Current']!.nudge, by['Card']!.nudge), (true, true));
    });

    test('monthly spend per category averages complete months', () async {
      final bank = await ledger.saveAccount(name: 'Current', subtype: 'current', commodityId: 'GBP');
      for (final d in ['2026-08-05', '2026-09-05', '2026-10-05', '2026-11-05']) {
        await ledger.saveEntry(
          simpleEntry(date: d, currency: 'GBP', accountId: bank, categoryId: 'cat.groceries', amount: 30000),
        );
      }
      final r = await (await engine('2026-11-16')).monthlyByCategory();
      expect((r.from, r.to, r.byCategory['cat.groceries']), ('2026-08-01', '2026-10-31', 30000));
    });
  });
}
