/// Money check (Nidhi N3): spending efficiency, the emergency cushion,
/// how fresh each account's data is and a weekly recap. Pure functions over
/// figures the ledger already holds; every number is worked out here, with
/// its formula, inputs, data date and healthy range kept next to it so the
/// screens can show them. Guidance, not regulated advice.
library;

import 'dart:math' as math;

import 'package:brahma_core/brahma_core.dart';

import '../reports/reports.dart' show MonthFlow;
import 'catalogue.dart';
import 'categorizer.dart';
import 'forecast.dart' show ForecastEvent;
import 'insights.dart';
import 'world.dart' show MarketSnapshot;

/// How a figure compares with its healthy range.
enum Verdict { good, watch, flag, unknown }

/// Where a healthy range comes from. A [convention] is a common rule of
/// thumb, not law or research, and the screens say so.
class Source {
  const Source(this.label, {this.url, this.convention = false});
  final String label;
  final String? url;
  final bool convention;
}

/// One input to a metric: an [amount] in the base currency (minor units) or
/// plain [text].
class MeasureInput {
  const MeasureInput(this.label, {this.amount, this.text});
  final String label;
  final int? amount;
  final String? text;
}

/// A worked-out metric with everything needed to check it by hand.
class Measure {
  const Measure({
    required this.id,
    required this.title,
    required this.display,
    required this.verdict,
    required this.formula,
    required this.inputs,
    required this.dataDate,
    required this.healthy,
    required this.source,
    this.value,
    this.note,
  });
  final String id;
  final String title;

  /// The figure as shown ("42%", "2 items", "–").
  final String display;

  /// The raw figure, when there is one.
  final double? value;
  final Verdict verdict;
  final String formula;
  final List<MeasureInput> inputs;

  /// Which data the figure rests on ("Complete months Aug-Oct 2026").
  final String dataDate;
  final String healthy;
  final Source source;

  /// A caveat, or why there is no figure yet.
  final String? note;
}

String _pct(double v) => '${(v * 100).round()}%';

String _monthName(String yyyyMm) => niceDate('$yyyyMm-01').substring(2);

String _span(List<MonthFlow> months) => months.isEmpty
    ? 'No complete months yet'
    : months.length == 1
    ? 'Complete month ${_monthName(months.first.month)}'
    : 'Complete months ${_monthName(months.first.month)} to ${_monthName(months.last.month)}';

/// [flows] (oldest first, complete months only) from the first month with
/// any income or spending.
List<MonthFlow> activeMonths(List<MonthFlow> flows) {
  final i = flows.indexWhere((f) => f.income != 0 || f.expenses != 0);
  return i < 0 ? const [] : flows.sublist(i);
}

const _fiftyThirtyTwenty = Source(
  '50/30/20 budgeting rule (Warren and Tyagi, "All Your Worth", 2005): about half of take-home pay '
  'for needs',
  convention: true,
);

/// Fixed costs as a share of income: essential spending plus recurring
/// payments in other categories (subscriptions, gym), per month, over the
/// last three complete months.
Measure fixedCostRatio(List<MonthFlow> complete, List<Recurring> recurring, Set<String> essentialIds) {
  final active = activeMonths(complete);
  final recent = active.length > 3 ? active.sublist(active.length - 3) : active;
  final n = math.max(recent.length, 1);
  final income = recent.fold(0, (s, f) => s + f.income) ~/ n;
  final essential = recent.fold(0, (s, f) => s + f.essential) ~/ n;
  final otherRecurring = recurring
      .where((r) => r.amount < 0 && !essentialIds.contains(r.categoryId))
      .fold(0, (s, r) => s - r.cadence.perMonth(r.amount));
  final fixed = essential + otherRecurring;
  final ratio = income > 0 ? fixed / income : null;
  return Measure(
    id: 'fixed_cost_ratio',
    title: 'Fixed-cost ratio',
    display: ratio == null ? '–' : _pct(ratio),
    value: ratio,
    verdict: switch (ratio) {
      null => Verdict.unknown,
      <= 0.5 => Verdict.good,
      <= 0.6 => Verdict.watch,
      _ => Verdict.flag,
    },
    formula: '(essential spending + other recurring payments) / income, per month',
    inputs: [
      MeasureInput('Income a month', amount: income),
      MeasureInput('Essential spending a month', amount: essential),
      MeasureInput('Other recurring payments a month', amount: otherRecurring),
    ],
    dataDate: _span(recent),
    healthy: '50% or less (over 60% leaves little room)',
    source: _fiftyThirtyTwenty,
    note: recent.isEmpty
        ? 'Needs a complete month of income and spending.'
        : income <= 0
        ? 'No income recorded in these months, so there is no ratio.'
        : recent.length == 1
        ? 'Based on one month; more months give a steadier figure.'
        : null,
  );
}

/// Change in the fixed-cost share of income against the same three months a
/// year earlier. Recurring payments of a year ago cannot be rebuilt from
/// the history kept, so both periods use essential spending / income, the
/// part known for both. A rise of 5 points or more is flagged.
Measure fixedCostRise(List<MonthFlow> complete) {
  final active = activeMonths(complete);
  final recent = active.length > 3 ? active.sublist(active.length - 3) : active;
  final byMonth = {for (final f in complete) f.month: f};
  final then = [for (final f in recent) ?byMonth[addMonths('${f.month}-01', -12).substring(0, 7)]];
  int sum(List<MonthFlow> xs, int Function(MonthFlow) f) => xs.fold(0, (s, x) => s + f(x));
  final enough =
      recent.length == 3 && then.length == 3 && active.length >= 15 && sum(then, (f) => f.income) > 0;
  final incomeNow = sum(recent, (f) => f.income), incomeThen = sum(then, (f) => f.income);
  final now = enough && incomeNow > 0 ? sum(recent, (f) => f.essential) / incomeNow : null;
  final before = enough ? sum(then, (f) => f.essential) / incomeThen : null;
  final rise = now != null && before != null ? now - before : null;
  String pts(double v) => '${v >= 0 ? '+' : ''}${(v * 100).toStringAsFixed(1)} pts';
  return Measure(
    id: 'fixed_cost_rise',
    title: 'Fixed costs vs a year ago',
    display: rise == null ? '–' : pts(rise),
    value: rise,
    verdict: switch (rise) {
      null => Verdict.unknown,
      >= 0.05 => Verdict.flag,
      > 0 => Verdict.watch,
      _ => Verdict.good,
    },
    formula: 'essential spending / income (last 3 months) - the same for those months a year earlier',
    inputs: [
      MeasureInput('Share now', text: now == null ? '–' : _pct(now)),
      MeasureInput('Share a year earlier', text: before == null ? '–' : _pct(before)),
      MeasureInput('Essential spending now, 3 months', amount: sum(recent, (f) => f.essential)),
      MeasureInput('Essential spending then, 3 months', amount: sum(then, (f) => f.essential)),
    ],
    dataDate: enough
        ? '${_span(then)}; and ${_span(recent).replaceFirst('Complete months ', '')}'
        : _span(recent),
    healthy: 'A rise under 5 points in a year',
    source: const Source(
      'Artha rule: flag a fixed-cost rise of 5 points or more in a year',
      convention: true,
    ),
    note: rise == null
        ? 'Not enough data: needs income and spending in the same three months a year earlier '
              '(15 complete months).'
        : rise >= 0.05
        ? 'Fixed costs take ${pts(rise).replaceAll(' pts', '')} points more of income than a year ago; '
              'check which essential bills grew.'
        : 'Recurring non-essential payments are left out of this comparison.',
  );
}

/// A recurring payment that is new or dearer within the window.
class CreepItem {
  const CreepItem(this.recurring, {required this.isNew, required this.yearly, required this.since});
  final Recurring recurring;

  /// True for a new payment; false for a price rise.
  final bool isNew;

  /// For a new payment its yearly cost; for a rise the extra a year.
  final int yearly;

  /// First payment (new) or the dearer one (rise).
  final String since;
}

class Creep {
  const Creep(this.items, this.measure);
  final List<CreepItem> items;
  final Measure measure;
}

String _merchantGroup(Txn t) =>
    '${t.amount < 0 ? '-' : '+'}${Categorizer.merchantKey(Categorizer.tokenize(t.text))}';

/// Recurring payments out that started, or went up in price, in the last
/// [window] days. Each counts at its yearly cost (new) or its yearly
/// increase (rise).
Creep subscriptionCreep(List<Recurring> recurring, List<Txn> txns, String today, {int window = 90}) {
  final from = addDays(today, -window);
  final firstSeen = <String, String>{};
  for (final t in txns) {
    if (Categorizer.tokenize(t.text).isEmpty || t.amount == 0) continue;
    final k = _merchantGroup(t);
    if ((firstSeen[k] ?? '9999').compareTo(t.date) > 0) firstSeen[k] = t.date;
  }
  String? first(Recurring r) {
    if (!r.manual) return firstSeen[r.key];
    final p = r.pattern!.toLowerCase();
    final seen = [
      for (final t in txns)
        if (t.amount < 0 && t.text.toLowerCase().contains(p)) t.date,
    ]..sort();
    return seen.firstOrNull;
  }

  final items = <CreepItem>[];
  var total = 0;
  for (final r in recurring.where((r) => r.amount < 0)) {
    final yearly = -r.cadence.perMonth(r.amount) * 12;
    total += yearly;
    final start = first(r);
    if (start != null && start.compareTo(from) >= 0) {
      items.add(CreepItem(r, isNew: true, yearly: yearly, since: start));
    } else if (r.priceFrom case final was? when r.amount < was && r.lastDate.compareTo(from) >= 0) {
      items.add(
        CreepItem(r, isNew: false, yearly: r.cadence.perMonth(was - r.amount) * 12, since: r.lastDate),
      );
    }
  }
  items.sort((a, b) => b.yearly.compareTo(a.yearly));
  final creep = items.fold(0, (s, i) => s + i.yearly);
  return Creep(
    items,
    Measure(
      id: 'subscription_creep',
      title: 'Subscription creep',
      display: items.isEmpty ? 'None' : '${items.length} ${items.length == 1 ? 'item' : 'items'}',
      value: creep.toDouble(),
      verdict: items.isEmpty ? Verdict.good : Verdict.watch,
      formula: 'yearly cost of recurring payments that are new, or rose in price, in the last $window days',
      inputs: [
        MeasureInput('New or dearer, a year', amount: creep),
        MeasureInput('All recurring payments, a year', amount: total),
        MeasureInput('Recurring payments watched', text: '${recurring.where((r) => r.amount < 0).length}'),
      ],
      dataDate: 'Payments ${niceDate(from)} to ${niceDate(today)}',
      healthy: 'No new or dearer payment you did not choose on purpose',
      source: const Source('Artha rule of thumb: check each new or dearer payment', convention: true),
      note: recurring.isEmpty ? 'No recurring payments spotted yet.' : null,
    ),
  );
}

/// Spending growth against income growth: the last 12 complete months
/// against the 12 before when there are 24; else the last 3 against the
/// same 3 a year earlier (needs 15). Both are nominal, so inflation cancels
/// out of the comparison.
Measure lifestyleInflation(List<MonthFlow> complete) {
  final active = activeMonths(complete);
  final List<MonthFlow> recent, prior;
  final String method;
  if (active.length >= 24) {
    recent = active.sublist(active.length - 12);
    prior = active.sublist(active.length - 24, active.length - 12);
    method = 'last 12 months against the 12 before';
  } else if (active.length >= 15) {
    recent = active.sublist(active.length - 3);
    prior = active.sublist(active.length - 15, active.length - 12);
    method = 'last 3 months against the same months a year earlier';
  } else {
    recent = prior = const [];
    method = '';
  }
  int sum(List<MonthFlow> xs, int Function(MonthFlow) f) => xs.fold(0, (s, x) => s + f(x));
  final spendThen = sum(prior, (f) => f.expenses), spendNow = sum(recent, (f) => f.expenses);
  final incomeThen = sum(prior, (f) => f.income), incomeNow = sum(recent, (f) => f.income);
  final spendGrowth = spendThen > 0 ? spendNow / spendThen - 1 : null;
  final incomeGrowth = incomeThen > 0 && incomeNow > 0 ? incomeNow / incomeThen - 1 : null;
  final gap = spendGrowth != null && incomeGrowth != null ? spendGrowth - incomeGrowth : null;
  String signed(double v) => '${v >= 0 ? '+' : ''}${(v * 100).toStringAsFixed(1)}%';
  return Measure(
    id: 'lifestyle_inflation',
    title: 'Lifestyle inflation',
    display: gap == null ? '–' : '${signed(gap)} pts',
    value: gap,
    verdict: switch (gap) {
      null => Verdict.unknown,
      <= 0 => Verdict.good,
      <= 0.05 => Verdict.watch,
      _ => Verdict.flag,
    },
    formula: 'spending growth - income growth ($method)'.replaceAll(' ()', ''),
    inputs: [
      MeasureInput('Spending growth', text: spendGrowth == null ? '–' : signed(spendGrowth)),
      MeasureInput('Income growth', text: incomeGrowth == null ? '–' : signed(incomeGrowth)),
      MeasureInput('Spending then', amount: spendThen),
      MeasureInput('Spending now', amount: spendNow),
    ],
    dataDate: recent.isEmpty
        ? '${active.length} complete ${active.length == 1 ? 'month' : 'months'} so far'
        : '${_span(prior)}; ${_span(recent)}'.replaceAll('; Complete', '; and'),
    healthy: 'Spending grows no faster than income (0 or below)',
    source: const Source(
      'Common planning rule: keep spending growth at or below income growth',
      convention: true,
    ),
    note: recent.isEmpty
        ? 'Needs at least 15 complete months; ${active.length} recorded.'
        : spendGrowth == null
        ? 'No spending in the earlier period to compare with.'
        : incomeGrowth == null
        ? 'No income in one of the periods, so only spending growth is shown.'
        : null,
  );
}

/// The user's spending in one ONS Family Spending group against the UK
/// average household.
class Benchmark {
  const Benchmark(this.line, this.yours, this.theirs);
  final OnsLine line;

  /// Per month, base currency (GBP).
  final int yours;
  final int theirs;
  double get ratio => theirs == 0 ? 0 : yours / theirs;
  Verdict get verdict => ratio <= 1.25
      ? Verdict.good
      : ratio <= 1.5
      ? Verdict.watch
      : Verdict.flag;
}

/// Monthly spending per category ([monthlyByCategory], GBP) grouped the way
/// ONS Family Spending groups it. Only for a GBP base: the survey is UK
/// households in pounds. Groups the user spends nothing in are left out.
List<Benchmark> compareWithOns(Map<String, int> monthlyByCategory, String base) {
  if (base != 'GBP') return const [];
  return [
    for (final l in OnsFamilySpending.lines)
      if (l.categories.fold(0, (s, c) => s + (monthlyByCategory[c] ?? 0)) case final yours when yours > 0)
        Benchmark(l, yours, l.monthly),
  ];
}

Measure onsMeasure(List<Benchmark> rows, String base, String dataDate) {
  final high = rows.where((b) => b.verdict == Verdict.flag).toList();
  return Measure(
    id: 'ons_benchmark',
    title: 'Spending vs UK households',
    display: rows.isEmpty
        ? '–'
        : high.isEmpty
        ? 'In range'
        : '${high.length} high',
    verdict: rows.isEmpty
        ? Verdict.unknown
        : high.isEmpty
        ? (rows.any((b) => b.verdict == Verdict.watch) ? Verdict.watch : Verdict.good)
        : Verdict.flag,
    formula: 'your monthly spend in a group / ONS average household weekly spend x 52 / 12',
    inputs: [
      for (final b in rows)
        MeasureInput(
          b.line.label,
          text:
              '${money(b.yours, 'GBP')} vs ${money(b.theirs, 'GBP')} (${b.ratio.toStringAsFixed(1)}x)'
              '${b.line.confirmed ? '' : ', figure unconfirmed'}',
        ),
    ],
    dataDate:
        '$dataDate; ONS ${OnsFamilySpending.period}, published ${niceDate(OnsFamilySpending.published)}',
    healthy: 'Up to 1.25x the average; over 1.5x is worth a closer look, not a judgement',
    source: const Source(OnsFamilySpending.sourceLabel, url: OnsFamilySpending.url),
    note: base != 'GBP'
        ? 'Only for a GBP base currency: the survey covers UK households.'
        : rows.isEmpty
        ? 'No spending yet in the compared groups.'
        : 'Averages across all UK households; size, income and region change what is usual. '
              'The 1.25x and 1.5x lines are Artha conventions.',
  );
}

/// A suggestion to cut a cost, with the yearly saving and the reason.
class CutCard {
  const CutCard(this.id, this.title, this.yearly, this.why);
  final String id;
  final String title;
  final int yearly;
  final String why;
}

/// "Cut this" cards: new and dearer recurring payments, and spending groups
/// well above the UK average, biggest saving first.
List<CutCard> cutThis(Creep creep, List<Benchmark> benchmarks, String base) {
  final out = <CutCard>[
    for (final i in creep.items)
      if (i.isNew)
        CutCard(
          'new/${i.recurring.key}',
          'Review ${i.recurring.label}',
          i.yearly,
          'New since ${niceDate(i.since)}: ${money(-i.recurring.amount, base)} ${i.recurring.cadence.name}, '
              '${money(i.yearly, base)} a year. Cancel it if you would not choose it again today.',
        )
      else
        CutCard(
          'rise/${i.recurring.key}',
          '${i.recurring.label} went up',
          i.yearly,
          'Was ${money(-i.recurring.priceFrom!, base)}, now ${money(-i.recurring.amount, base)} '
              '${i.recurring.cadence.name} since ${niceDate(i.since)}. Asking for the old price or switching '
              'saves about ${money(i.yearly, base)} a year.',
        ),
    for (final b in benchmarks)
      if (b.verdict == Verdict.flag && b.line.cuttable)
        CutCard(
          'ons/${b.line.id}',
          'Look at ${b.line.label.toLowerCase()}',
          (b.yours - b.theirs) * 12,
          'You spend ${money(b.yours, base)} a month; the average UK household spends ${money(b.theirs, base)} '
              '(ONS ${OnsFamilySpending.period}). Coming down to the average would free about '
              '${money((b.yours - b.theirs) * 12, base)} a year. Households differ, so this is a prompt to look, '
              'not a judgement.',
        ),
  ];
  return out..sort((a, b) => b.yearly.compareTo(a.yearly));
}

/// Emergency cushion target choices, in months of essential spending.
const cushionTargets = [3, 6, 9, 12];
const cushionTargetKey = 'emergency.months';
const defaultCushionTarget = 6;

class Cushion {
  const Cushion(
    this.measure, {
    this.months,
    required this.target,
    required this.need,
    this.shortfall = 0,
    this.rateNote,
  });
  final Measure measure;
  final double? months;
  final int target;

  /// Monthly spending the cushion is sized on.
  final int need;

  /// What is missing to reach the target (0 when reached).
  final int shortfall;

  /// Bank Rate and CPI from the live UK feed, when fetched.
  final String? rateNote;
}

/// Months of essential spending that [liquid] cash covers, against the
/// user's [target] months. Uses all spending when no category is marked
/// essential.
Cushion emergencyCushion({
  required int liquid,
  required int essentialMonthly,
  required int spendMonthly,
  required int target,
  MarketSnapshot market = const MarketSnapshot(),
  required String asOf,
}) {
  final essential = essentialMonthly > 0;
  final need = essential ? essentialMonthly : spendMonthly;
  final months = need > 0 ? liquid / need : null;
  final shortfall = need > 0 ? math.max(0, need * target - liquid) : 0;
  String? rateNote;
  if (market.cpi case final cpi?) {
    final rate = market.bankRate;
    rateNote =
        'Prices rose ${cpi.toStringAsFixed(1)}% in the year to ${market.cpiMonth ?? 'the latest month'} (ONS)'
        '${rate == null ? '' : '; Bank Rate is ${rate.toStringAsFixed(2)}%'
                  '${market.bankRateDate == null ? '' : ' since ${niceDate(market.bankRateDate!)}'} (Bank of England)'}. '
        'Cash earning less than ${cpi.toStringAsFixed(1)}% loses buying power, so keep the cushion in easy '
        'access savings paying close to the best rate, not a 0% current account.';
  } else if (market.bankRate case final rate?) {
    rateNote = 'Bank Rate is ${rate.toStringAsFixed(2)}% (Bank of England). Inflation not fetched yet.';
  }
  return Cushion(
    Measure(
      id: 'emergency_cushion',
      title: 'Emergency cushion',
      display: months == null ? '–' : '${months.toStringAsFixed(1)} of $target months',
      value: months,
      verdict: switch (months) {
        null => Verdict.unknown,
        final m when m >= target => Verdict.good,
        final m when m >= 3 => Verdict.watch,
        _ => Verdict.flag,
      },
      formula:
          'cash in current, savings and cash accounts / ${essential ? 'essential' : 'all'} spending a month',
      inputs: [
        MeasureInput('Cash you can reach', amount: liquid),
        MeasureInput(essential ? 'Essential spending a month' : 'All spending a month', amount: need),
        MeasureInput('Your target', text: '$target months'),
        MeasureInput('To reach it', amount: shortfall),
      ],
      dataDate: 'Balances on ${niceDate(asOf)}; spending from recent complete months',
      healthy: '3-6 months of essential outgoings; more with one income, dependants or an unsteady job',
      source: const Source(
        'NS&I emergency fund guide (MoneyHelper guidance)',
        url: 'https://www.nsandi.com/guide/emergency-fund',
      ),
      note: need <= 0
          ? 'Needs a month of spending to size the cushion.'
          : essential
          ? null
          : 'No essential categories recorded, so all spending is used; mark categories essential to '
                'size it on needs only.',
    ),
    months: months,
    target: target,
    need: need,
    shortfall: shortfall,
    rateNote: rateNote,
  );
}

/// How fresh one account's data is.
class Freshness {
  const Freshness(this.accountId, this.name, {this.date, this.source, this.days, this.stale = false});
  final String accountId;
  final String name;

  /// Latest statement balance, imported row or entry, on or before today.
  final String? date;

  /// statement | import | entry
  final String? source;
  final int? days;
  final bool stale;

  String get label => switch ((source, days)) {
    (null, _) || (_, null) => 'Nothing imported yet',
    (final s, final d!) =>
      '${s == 'entry' ? 'Last entry' : 'Last $s'} ${d == 0
          ? 'today'
          : d == 1
          ? 'yesterday'
          : '$d days ago'}',
  };
}

const freshnessDaysKey = 'freshness.days';
const defaultFreshnessDays = 35;
const freshnessChoices = [14, 21, 35, 45, 60, 90];

/// Per account: the newest statement balance or imported row (an entry typed
/// by hand when there is neither), and whether it is older than [nudgeDays].
/// Only accounts marked [nudge] (everyday ones that get monthly statements)
/// are nagged about, and never one with no data at all.
List<Freshness> accountFreshness(
  List<({String id, String name, String? statement, String? imported, String? entry, bool nudge})> accounts,
  String today,
  int nudgeDays,
) {
  String? latest(String? a, String? b) => a == null ? b : (b == null || a.compareTo(b) >= 0 ? a : b);
  final out = <Freshness>[];
  for (final a in accounts) {
    final fromFile = latest(a.statement, a.imported);
    final date = fromFile ?? a.entry;
    final source = fromFile == null
        ? (a.entry == null ? null : 'entry')
        : (fromFile == a.statement ? 'statement' : 'import');
    final days = date == null || date.compareTo(today) > 0
        ? (date == null ? null : 0)
        : daysBetween(today, date);
    out.add(
      Freshness(
        a.id,
        a.name,
        date: date,
        source: source,
        days: days,
        stale: a.nudge && days != null && days > nudgeDays,
      ),
    );
  }
  out.sort((x, y) => (y.days ?? -1).compareTo(x.days ?? -1));
  return out;
}

/// One expense in base currency (positive spends, negative refunds).
class SpendItem {
  const SpendItem(this.date, this.label, this.amount, this.categoryId);
  final String date;
  final String label;
  final int amount;
  final String categoryId;
}

/// Monday of the week holding [iso].
String weekStart(String iso) => addDays(iso, -(DateTime.parse('${iso}T00:00:00Z').weekday - 1));

int daysInMonth(String iso) => int.parse(monthEnd(iso).substring(8));

class WeeklyRecap {
  const WeeklyRecap({
    required this.today,
    required this.weekFrom,
    required this.spentWeek,
    required this.spentMonth,
    required this.daysLeft,
    required this.plan,
    required this.planLabel,
    required this.planSpent,
    this.perDayLeft,
    required this.onPace,
    required this.topMerchants,
    required this.billsDue,
    required this.nextStep,
  });
  final String today;
  final String weekFrom;
  final int spentWeek;
  final int spentMonth;

  /// Days left in the month, today included.
  final int daysLeft;

  /// Monthly budgets total, else a usual month's spending; 0 when neither.
  final int plan;

  /// "your budgets" | "a usual month"
  final String planLabel;

  /// Spending so far this month that counts against [plan].
  final int planSpent;

  /// What can be spent each day left and stay within [plan].
  final int? perDayLeft;

  /// Spending is no ahead of an even pace through the month.
  final bool onPace;
  final List<({String label, int amount})> topMerchants;
  final List<ForecastEvent> billsDue;
  final String nextStep;
}

/// The local weekly recap: spending this week and month so far, what can be
/// spent per day left, the top merchants this month, bills in the next 7
/// days and one next step. [items] must cover the month and the week so far.
/// [budgets] maps category to monthly budget; with none set the plan is a
/// [usualMonth] of spending.
WeeklyRecap weeklyRecap({
  required List<SpendItem> items,
  required String today,
  required Map<String, int> budgets,
  required int usualMonth,
  required List<Recurring> recurring,
  List<ForecastEvent> oneOffs = const [],
  required String base,
  List<Freshness> freshness = const [],
  Cushion? cushion,
  Creep? creep,
}) {
  final from = weekStart(today);
  final month = monthStart(today);
  bool inRange(String d, String a) => d.compareTo(a) >= 0 && d.compareTo(today) <= 0;
  final spentWeek = items.where((i) => inRange(i.date, from)).fold(0, (s, i) => s + i.amount);
  final thisMonth = items.where((i) => inRange(i.date, month)).toList();
  final spentMonth = thisMonth.fold(0, (s, i) => s + i.amount);
  final budgeted = budgets.entries.where((e) => e.value > 0).toList();
  final plan = budgeted.isNotEmpty ? budgeted.fold(0, (s, e) => s + e.value) : usualMonth;
  final planSpent = budgeted.isNotEmpty
      ? thisMonth.where((i) => (budgets[i.categoryId] ?? 0) > 0).fold(0, (s, i) => s + i.amount)
      : spentMonth;
  final total = daysInMonth(today);
  final day = int.parse(today.substring(8));
  final daysLeft = total - day + 1;
  final perDay = plan > 0 ? math.max(0, plan - planSpent) ~/ daysLeft : null;
  final onPace = plan <= 0 || planSpent * total <= plan * day;

  final byMerchant = <String, ({String label, int amount})>{};
  for (final i in thisMonth) {
    final tokens = Categorizer.tokenize(i.label);
    final key = tokens.isEmpty ? i.label.toLowerCase() : Categorizer.merchantKey(tokens);
    final was = byMerchant[key];
    byMerchant[key] = (label: was?.label ?? i.label, amount: (was?.amount ?? 0) + i.amount);
  }
  final top = byMerchant.values.where((m) => m.amount > 0).toList()
    ..sort((a, b) => b.amount.compareTo(a.amount));

  final end = addDays(today, 7);
  final bills = <ForecastEvent>[
    for (final r in recurring)
      if (r.amount < 0 && r.nextDate.compareTo(end) <= 0)
        ForecastEvent(r.nextDate.compareTo(today) < 0 ? today : r.nextDate, r.label, r.amount),
    for (final o in oneOffs)
      if (o.amount < 0 && inRangeFuture(o.date, today, end)) o,
  ]..sort((a, b) => a.date.compareTo(b.date));

  final stale = freshness.where((f) => f.stale).toList();
  final newest = creep?.items.where((i) => i.isNew).firstOrNull;
  final step = !onPace && perDay != null
      ? 'Keep to ${money(perDay, base)} a day for the rest of the month to stay within ${budgeted.isNotEmpty ? 'your budgets' : 'a usual month'}.'
      : stale.isNotEmpty
      ? 'Import the latest statement for ${stale.first.name}: its data is ${stale.first.days} days old.'
      : cushion != null && cushion.shortfall > 0 && cushion.months != null
      ? 'Your cushion covers ${cushion.months!.toStringAsFixed(1)} of ${cushion.target} months; '
            '${money((cushion.shortfall / 12).ceil(), base)} a month into easy-access savings reaches it in a year.'
      : newest != null
      ? 'Check ${newest.recurring.label}: new this quarter, ${money(newest.yearly, base)} a year.'
      : 'Nothing needs you this week. Keep going.';

  return WeeklyRecap(
    today: today,
    weekFrom: from,
    spentWeek: spentWeek,
    spentMonth: spentMonth,
    daysLeft: daysLeft,
    plan: plan,
    planLabel: budgeted.isNotEmpty ? 'your budgets' : 'a usual month',
    planSpent: planSpent,
    perDayLeft: perDay,
    onPace: onPace,
    topMerchants: top.take(3).toList(),
    billsDue: bills,
    nextStep: step,
  );
}

/// [d] from [today] to [end], both included.
bool inRangeFuture(String d, String today, String end) => d.compareTo(today) >= 0 && d.compareTo(end) <= 0;
