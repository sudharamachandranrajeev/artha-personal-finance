import 'package:artha/modules/finance/domain/accounting.dart';
import 'package:artha/modules/finance/domain/ledger.dart';
import 'package:artha/modules/finance/insights/forecast.dart';
import 'package:artha/modules/finance/insights/insights.dart';
import 'package:artha/modules/finance/insights/money_check.dart';
import 'package:artha/modules/finance/reports/reports.dart' show MonthFlow;
import 'package:artha/modules/finance/ui/money_check_cards.dart';
import 'package:artha/ui/theme.dart';
import 'package:brahma_core/brahma_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'app_harness.dart';

/// The money check cards (Nidhi N3): built alone with made-up figures, and
/// inside the app over a seeded ledger.
void main() {
  Future<void> pumpAlone(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: buildArthaTheme(arthaPalettes.first, Brightness.light),
          home: Scaffold(
            body: SingleChildScrollView(
              child: Padding(padding: const EdgeInsets.all(16), child: child),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('a metric card shows formula, inputs, data date, healthy range and source', (tester) async {
    final m = fixedCostRatio(
      [
        MonthFlow('2026-10')
          ..income = 300000
          ..expenses = 200000
          ..essential = 120000,
      ],
      const [],
      const {},
    );
    await pumpAlone(tester, MeasureCard(m, 'GBP'));
    expect(find.text('Fixed-cost ratio'), findsOneWidget);
    expect(find.text('40%'), findsOneWidget);
    expect(find.text('In the healthy range'), findsOneWidget);
    for (final label in ['Formula', 'Inputs', 'Data', 'Healthy', 'Source']) {
      expect(find.textContaining(label, findRichText: true), findsWidgets, reason: label);
    }
    expect(find.textContaining('Oct 2026', findRichText: true), findsOneWidget);
    expect(find.text('convention'), findsOneWidget);
    expect(find.text(m.note!), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cut cards list the yearly saving and the reason', (tester) async {
    await pumpAlone(
      tester,
      const CutThisCard([
        CutCard('a', 'Review NewTV', 15588, 'New since 5 Sept 2026.'),
        CutCard('b', 'Look at food', 12000, 'Above the UK average.'),
      ], 'GBP'),
    );
    expect(find.text('Review NewTV'), findsOneWidget);
    expect(find.text(money(15588, 'GBP')), findsOneWidget);
    expect(find.text('a year'), findsNWidgets(2));
    await pumpAlone(tester, const CutThisCard([], 'GBP'));
    expect(find.textContaining('Nothing stands out'), findsOneWidget);
  });

  testWidgets('the recap card shows spending, per day left, merchants, bills and a next step', (
    tester,
  ) async {
    final r = weeklyRecap(
      items: const [
        SpendItem('2026-11-16', 'Fresh Market', 10000, 'cat.groceries'),
        SpendItem('2026-11-17', 'Noodle House', 3000, 'cat.eating_out'),
      ],
      today: '2026-11-18',
      budgets: const {'cat.groceries': 40000},
      usualMonth: 0,
      recurring: [Recurring('tv', 'StreamFlix', Cadence.monthly, -1099, '2026-10-20', 'x', 4)],
      base: 'GBP',
    );
    await pumpAlone(tester, RecapCard(r, 'GBP'));
    expect(find.text(money(13000, 'GBP')), findsNWidgets(2));
    expect(find.text('Per day left'), findsOneWidget);
    expect(find.text(money(30000 ~/ 13, 'GBP')), findsOneWidget);
    expect(find.text('Fresh Market'), findsOneWidget);
    expect(find.textContaining('StreamFlix'), findsOneWidget);
    expect(find.textContaining('Next step:'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the calendar shows each day\'s balance, pages months and explains a tapped day', (
    tester,
  ) async {
    final f = forecastCash(
      liquid: 50000,
      recurring: [Recurring('rent', 'RENT', Cadence.monthly, -80000, '2026-10-20', 'x', 4)],
      monthlySpend: 80000,
      today: '2026-11-16',
      days: 60,
    );
    await pumpAlone(tester, ForecastCalendar(f, 'GBP'));
    expect(find.text('Nov 2026'), findsOneWidget);
    expect(find.text('Mon'), findsOneWidget);
    // 20 Nov: rent goes out and the balance turns negative.
    await tester.tap(find.text('20'));
    await tester.pump();
    final day = f.calendar().firstWhere((d) => d.date == '2026-11-20');
    expect(find.textContaining('20 Nov 2026: ${money(day.balance, 'GBP')} expected'), findsOneWidget);
    expect(find.textContaining('RENT'), findsOneWidget);
    await tester.tap(find.byTooltip('Next month'));
    await tester.pump();
    expect(find.text('Dec 2026'), findsOneWidget);
    await tester.tap(find.byTooltip('Next month'));
    await tester.pump();
    expect(find.text('Jan 2027'), findsOneWidget);
    expect(tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.chevron_right)).onPressed, isNull);
    expect(tester.takeException(), isNull);
  });

  /// Four months of pay and bills; the current account was last imported
  /// 50 days ago.
  Future<void> seed(Ledger ledger) async {
    await ledger.setUp('GBP');
    final now = today();
    final bank = await ledger.saveAccount(name: 'Everyday', subtype: 'current', commodityId: 'GBP');
    final saver = await ledger.saveAccount(name: 'Saver', subtype: 'savings', commodityId: 'GBP');
    await ledger.saveEntry(
      simpleEntry(
        date: addMonths(now, -5),
        currency: 'GBP',
        accountId: saver,
        categoryId: openingBalancesId,
        amount: -500000,
      ),
    );
    for (var m = 3; m >= 1; m--) {
      final d = monthStart(addMonths(now, -m));
      for (final (day, cat, amount, payee) in [
        (1, 'cat.salary', -300000, 'Acme Studios'),
        (2, 'cat.housing', 120000, 'Willow Lettings'),
        (6, 'cat.groceries', 60000, 'Fresh Market'),
        (12, 'cat.subscriptions', 1099, 'StreamFlix'),
      ]) {
        await ledger.saveEntry(
          simpleEntry(
            date: addDays(d, day - 1),
            currency: 'GBP',
            accountId: bank,
            categoryId: cat,
            amount: amount,
            payee: payee,
            importRef: m == 1 ? null : 'csv:$m:$day',
          ),
        );
      }
    }
    // The last import is 50 days old.
    await ledger.saveEntry(
      simpleEntry(
        date: addDays(now, -50),
        currency: 'GBP',
        accountId: bank,
        categoryId: 'cat.groceries',
        amount: 2000,
        payee: 'Corner Grocer',
        importRef: 'csv:last',
      ),
    );
    await ledger.saveEntry(
      simpleEntry(
        date: now,
        currency: 'GBP',
        accountId: saver,
        categoryId: 'cat.eating_out',
        amount: 1500,
        payee: 'Noodle House',
      ),
    );
  }

  testWidgets('dashboard: recap, freshness nudge, cushion target and the day-by-day forecast', (
    tester,
  ) async {
    final app = AppHarness(tester)..desktop();
    await app.open(seed: seed);
    await app.run();
    expect(find.text('This week'), findsOneWidget);
    expect(find.textContaining('Next step:'), findsOneWidget);
    expect(find.textContaining('1 account needs a fresh statement'), findsOneWidget);
    expect(find.text('Last import 50 days ago · ${niceDate(addDays(today(), -50))}'), findsOneWidget);

    // The cushion target is a synced preference.
    expect(find.text('target 6'), findsOneWidget);
    await app.tap(find.descendant(of: find.byType(SegmentedButton<int>), matching: find.text('9')));
    expect(await tester.runAsync(() => app.ledger.pref<int>(cushionTargetKey, 0)), 9);
    expect(find.text('target 9'), findsOneWidget);

    // So is the nudge: at 60 days the account is fresh enough.
    await app.tap(find.byType(DropdownButton<int>));
    await app.tap(find.text('60 days').last);
    expect(await tester.runAsync(() => app.ledger.pref<int>(freshnessDaysKey, 0)), 60);
    expect(find.text('Data freshness'), findsNothing);

    await app.tap(find.text('Day by day'));
    expect(find.text('Mon'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await app.close();
  });

  testWidgets('insights: spending check metrics and cut cards; accounts show freshness', (tester) async {
    final app = AppHarness(tester)..desktop();
    await app.open(seed: seed);
    await app.run();
    await app.go('Insights');
    expect(find.text('Spending check'), findsOneWidget);
    for (final t in [
      'Fixed-cost ratio',
      'Subscription creep',
      'Lifestyle inflation',
      'Spending vs UK households',
    ]) {
      expect(find.text(t), findsOneWidget, reason: t);
    }
    expect(find.text('Cut this'), findsOneWidget);
    // Groceries at £600 a month are well above the ONS household average.
    expect(find.text('Look at food and drink at home'), findsOneWidget);
    await app.go('Accounts');
    expect(find.text('Last import 50 days ago'), findsOneWidget);
    expect(find.text('Last entry today'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await app.close();
  });
}
