import 'package:brahma_core/brahma_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../ui/components.dart';
import '../../../ui/theme.dart';
import '../insights/forecast.dart';
import '../insights/money_check.dart';
import 'assistant_page.dart' show openLink;
import 'import_page.dart';

Status statusOf(Verdict v) => switch (v) {
  Verdict.good => Status.good,
  Verdict.watch => Status.warning,
  Verdict.flag => Status.serious,
  Verdict.unknown => Status.info,
};

String verdictLabel(Verdict v) => switch (v) {
  Verdict.good => 'In the healthy range',
  Verdict.watch => 'Worth watching',
  Verdict.flag => 'Worth a closer look',
  Verdict.unknown => 'Not enough data yet',
};

/// An icon and wrapping text, for status lines longer than one row.
class StatusText extends StatelessWidget {
  const StatusText(this.status, this.text, {super.key, this.style});
  final Status status;
  final String text;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.only(top: 1),
        child: Icon(status.icon, size: 16, color: status.color),
      ),
      const SizedBox(width: 6),
      Expanded(child: Text(text, style: style)),
    ],
  );
}

/// How a metric is worked out: formula, inputs, data date, healthy range
/// and its source (marked when it is a convention).
class MeasureDetails extends StatelessWidget {
  const MeasureDetails(this.m, this.currency, {super.key});
  final Measure m;
  final String currency;

  @override
  Widget build(BuildContext context) {
    final muted = ArthaSkin.of(context).muted;
    final small = TextStyle(fontSize: 12, color: muted);
    final label = TextStyle(fontSize: 12, color: muted, fontWeight: FontWeight.w600);
    Widget line(String k, String v) => Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(text: '$k ', style: label),
            TextSpan(text: v, style: small),
          ],
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        line('Formula', m.formula),
        line(
          'Inputs',
          [
            for (final i in m.inputs)
              '${i.label} ${i.amount != null ? money(i.amount!, currency) : (i.text ?? '–')}',
          ].join(' · '),
        ),
        line('Data', m.dataDate),
        line('Healthy', m.healthy),
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 6,
            children: [
              Text('Source', style: label),
              if (m.source.url == null)
                Text(m.source.label, style: small)
              else
                InkWell(
                  onTap: () => openLink(m.source.url!),
                  child: Text(
                    m.source.label,
                    style: small.copyWith(
                      decoration: TextDecoration.underline,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ),
              if (m.source.convention)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    border: Border.all(color: muted),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text('convention', style: small.copyWith(fontSize: 11)),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// One metric: its figure, verdict, caveat and how it is worked out.
class MeasureCard extends StatelessWidget {
  const MeasureCard(this.m, this.currency, {super.key});
  final Measure m;
  final String currency;

  @override
  Widget build(BuildContext context) {
    final skin = ArthaSkin.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              m.title,
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: skin.muted),
            ),
            const SizedBox(height: 4),
            Text(m.display, style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700).merge(tabular)),
            const SizedBox(height: 4),
            StatusLabel(statusOf(m.verdict), verdictLabel(m.verdict)),
            if (m.note != null) ...[
              const SizedBox(height: 6),
              Text(m.note!, style: const TextStyle(fontSize: 12)),
            ],
            const Divider(height: 20),
            MeasureDetails(m, currency),
          ],
        ),
      ),
    );
  }
}

/// "Spending check" on the Insights page: the efficiency metrics, the UK
/// comparison and the cut-this cards.
class SpendingCheck extends ConsumerWidget {
  const SpendingCheck({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final check = ref.watch(moneyCheckProvider).value;
    final cur = ref.watch(setupProvider).value ?? 'GBP';
    if (check == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader('Spending check'),
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: StatusText(
            Status.info,
            'Worked out on this device from your own records. Guidance, not financial advice: '
            'each figure shows its formula, inputs and where the healthy range comes from.',
            style: TextStyle(fontSize: 12, color: ArthaSkin.of(context).muted),
          ),
        ),
        TileGrid(
          minWidth: 300,
          children: [
            for (final m in [
              check.fixedCost,
              check.fixedCostRise,
              check.creep.measure,
              check.lifestyle,
              check.ons,
            ])
              MeasureCard(m, cur),
          ],
        ),
        CutThisCard(check.cuts, cur),
      ],
    );
  }
}

/// Costs worth cutting, each with its yearly saving and why.
class CutThisCard extends StatelessWidget {
  const CutThisCard(this.cuts, this.currency, {super.key, this.max = 5});
  final List<CutCard> cuts;
  final String currency;
  final int max;

  @override
  Widget build(BuildContext context) {
    final muted = ArthaSkin.of(context).muted;
    return SectionCard(
      title: 'Cut this',
      hint: 'card.cut',
      child: cuts.isEmpty
          ? const Text('Nothing stands out: no new or dearer payments and no group well above UK households.')
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final c in cuts.take(max))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.content_cut, size: 18, color: muted),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(c.title, style: const TextStyle(fontWeight: FontWeight.w600)),
                              const SizedBox(height: 2),
                              Text(c.why, style: TextStyle(fontSize: 12, color: muted)),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              money(c.yearly, currency),
                              style: const TextStyle(fontWeight: FontWeight.w700).merge(tabular),
                            ),
                            Text('a year', style: TextStyle(fontSize: 11, color: muted)),
                          ],
                        ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }
}

/// Months of essentials the cash covers against the user's target, the
/// target picker and the live rate note.
class CushionCard extends ConsumerWidget {
  const CushionCard(this.c, this.currency, {super.key});
  final Cushion c;
  final String currency;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final skin = ArthaSkin.of(context);
    final m = c.measure;
    final months = c.months;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    months == null ? '–' : '${months.toStringAsFixed(1)} months',
                    style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700).merge(tabular),
                  ),
                ),
                Text('target ${c.target}', style: TextStyle(color: skin.muted)),
              ],
            ),
            const SizedBox(height: 10),
            ProgressLine(value: months == null ? 0 : months / c.target, height: 10),
            const SizedBox(height: 10),
            StatusText(
              statusOf(m.verdict),
              months == null
                  ? m.note ?? verdictLabel(m.verdict)
                  : c.shortfall > 0
                  ? '${money(c.shortfall, currency)} more reaches ${c.target} months of '
                        '${money(c.need, currency)}.'
                  : 'Covers your ${c.target}-month target.',
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Text('Target', style: TextStyle(fontSize: 12, color: skin.muted)),
                const SizedBox(width: 12),
                Flexible(
                  child: SegmentedButton<int>(
                    showSelectedIcon: false,
                    segments: [for (final t in cushionTargets) ButtonSegment(value: t, label: Text('$t'))],
                    selected: {c.target},
                    onSelectionChanged: (s) => guarded(
                      context,
                      () => ref.mutate((x) => x.ledger.setPref(cushionTargetKey, s.first)),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text('months', style: TextStyle(fontSize: 12, color: skin.muted)),
              ],
            ),
            if (c.rateNote != null) ...[
              const SizedBox(height: 12),
              StatusText(Status.info, c.rateNote!, style: const TextStyle(fontSize: 12)),
            ],
            const Divider(height: 24),
            MeasureDetails(m, currency),
          ],
        ),
      ),
    );
  }
}

/// Accounts whose latest statement or import is older than the nudge, with
/// the nudge setting.
class FreshnessCard extends ConsumerWidget {
  const FreshnessCard(this.freshness, this.nudgeDays, {super.key});
  final List<Freshness> freshness;
  final int nudgeDays;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final muted = ArthaSkin.of(context).muted;
    final stale = freshness.where((f) => f.stale).toList();
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            StatusText(
              stale.isEmpty ? Status.good : Status.warning,
              stale.isEmpty
                  ? 'Every account has data from the last $nudgeDays days.'
                  : '${stale.length} ${stale.length == 1 ? 'account needs' : 'accounts need'} a fresh statement: '
                        'figures for ${stale.length == 1 ? 'it' : 'them'} may be out of date.',
            ),
            for (final f in (stale.isEmpty ? freshness : stale).take(5))
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  f.stale ? Icons.history_toggle_off : Icons.update,
                  color: f.stale ? Status.warning.color : muted,
                ),
                title: Text(f.name, overflow: TextOverflow.ellipsis),
                subtitle: Text(f.date == null ? f.label : '${f.label} · ${niceDate(f.date!)}'),
                trailing: f.stale
                    ? TextButton(
                        onPressed: () =>
                            Navigator.push(context, MaterialPageRoute(builder: (_) => const ImportPage())),
                        child: const Text('Import'),
                      )
                    : null,
              ),
            Row(
              children: [
                Expanded(
                  child: Text('Nudge after', style: TextStyle(fontSize: 12, color: muted)),
                ),
                DropdownButton<int>(
                  value: freshnessChoices.contains(nudgeDays) ? nudgeDays : null,
                  hint: Text('$nudgeDays days'),
                  underline: const SizedBox.shrink(),
                  items: [
                    for (final d in freshnessChoices) DropdownMenuItem(value: d, child: Text('$d days')),
                  ],
                  onChanged: (d) => d == null
                      ? null
                      : guarded(context, () => ref.mutate((x) => x.ledger.setPref(freshnessDaysKey, d))),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The weekly recap: spending so far, per day left, top merchants, bills
/// due in the next 7 days and one next step. Worked out on the device.
class RecapCard extends StatelessWidget {
  const RecapCard(this.r, this.currency, {super.key});
  final WeeklyRecap r;
  final String currency;

  @override
  Widget build(BuildContext context) {
    final skin = ArthaSkin.of(context);
    final caption = TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: skin.muted);
    Widget figure(String label, String value, String sub) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: caption),
        const SizedBox(height: 2),
        Text(value, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700).merge(tabular)),
        Text(sub, style: caption),
      ],
    );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 24,
              runSpacing: 12,
              children: [
                figure('Week so far', money(r.spentWeek, currency), 'since ${niceDate(r.weekFrom)}'),
                figure('Month so far', money(r.spentMonth, currency), '${r.daysLeft} days left'),
                figure(
                  'Per day left',
                  r.perDayLeft == null ? '–' : money(r.perDayLeft!, currency),
                  r.plan > 0 ? 'within ${r.planLabel}' : 'needs a budget or a month of history',
                ),
              ],
            ),
            if (r.plan > 0) ...[
              const SizedBox(height: 12),
              ProgressLine(value: r.planSpent / r.plan, height: 6),
              const SizedBox(height: 4),
              Text(
                '${money(r.planSpent, currency)} of ${money(r.plan, currency)} '
                '${r.planLabel == 'your budgets' ? 'budgeted' : 'in a usual month'}'
                '${r.onPace ? ', on pace' : ', ahead of pace'}',
                style: caption,
              ),
            ],
            if (r.topMerchants.isNotEmpty) ...[
              const SizedBox(height: 14),
              Text('Top this month', style: caption),
              for (final m in r.topMerchants)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(
                    children: [
                      Expanded(child: Text(m.label, overflow: TextOverflow.ellipsis)),
                      Text(money(m.amount, currency), style: tabular),
                    ],
                  ),
                ),
            ],
            const SizedBox(height: 14),
            Text('Bills in the next 7 days', style: caption),
            if (r.billsDue.isEmpty)
              const Padding(padding: EdgeInsets.only(top: 4), child: Text('None expected.'))
            else
              for (final b in r.billsDue)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text('${niceDate(b.date)} · ${b.label}', overflow: TextOverflow.ellipsis),
                      ),
                      Text(money(b.amount, currency, signed: true), style: tabular),
                    ],
                  ),
                ),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: skin.soft, borderRadius: BorderRadius.circular(12)),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.flag_outlined, size: 18, color: skin.onSoft),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Next step: ${r.nextStep}',
                      style: TextStyle(color: skin.onSoft, fontWeight: FontWeight.w500),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The forecast as a month calendar: each day's expected closing balance,
/// dots on days with a payment, red when below zero. Tap a day for detail.
class ForecastCalendar extends StatefulWidget {
  const ForecastCalendar(this.f, this.currency, {super.key});
  final CashForecast f;
  final String currency;

  @override
  State<ForecastCalendar> createState() => _ForecastCalendarState();
}

class _ForecastCalendarState extends State<ForecastCalendar> {
  int _month = 0;
  String? _picked;

  @override
  Widget build(BuildContext context) {
    final days = widget.f.calendar();
    if (days.isEmpty) return const SizedBox.shrink();
    final months = <String>{for (final d in days) d.date.substring(0, 7)}.toList();
    final month = months[_month.clamp(0, months.length - 1)];
    final byDate = {for (final d in days) d.date: d};
    final first = '$month-01';
    final lead = DateTime.parse('${first}T00:00:00Z').weekday - 1;
    final count = daysInMonth(first);
    final skin = ArthaSkin.of(context);
    final scheme = Theme.of(context).colorScheme;
    final picked = _picked == null ? null : byDate[_picked];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            IconButton(
              tooltip: 'Previous month',
              icon: const Icon(Icons.chevron_left),
              onPressed: _month > 0 ? () => setState(() => _month--) : null,
            ),
            Expanded(
              child: Text(
                niceDate(first).substring(2),
                textAlign: TextAlign.center,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            IconButton(
              tooltip: 'Next month',
              icon: const Icon(Icons.chevron_right),
              onPressed: _month < months.length - 1 ? () => setState(() => _month++) : null,
            ),
          ],
        ),
        Row(
          children: [
            for (final w in const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'])
              Expanded(
                child: Text(
                  w,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 11, color: skin.muted),
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        for (var row = 0; row * 7 < lead + count; row++)
          Row(
            children: [
              for (var col = 0; col < 7; col++)
                Expanded(
                  child: Builder(
                    builder: (context) {
                      final n = row * 7 + col - lead + 1;
                      if (n < 1 || n > count) return const SizedBox(height: 48);
                      final date = '$month-${n.toString().padLeft(2, '0')}';
                      final d = byDate[date];
                      final neg = d != null && d.balance < 0;
                      return InkWell(
                        onTap: d == null ? null : () => setState(() => _picked = date),
                        borderRadius: BorderRadius.circular(8),
                        child: Container(
                          height: 48,
                          margin: const EdgeInsets.all(1),
                          decoration: BoxDecoration(
                            color: d == null
                                ? null
                                : neg
                                ? scheme.errorContainer
                                : _picked == date
                                ? skin.soft
                                : null,
                            border: d?.lowest == true ? Border.all(color: Status.warning.color) : null,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                '$n',
                                style: TextStyle(fontSize: 11, color: d == null ? skin.muted : null),
                              ),
                              if (d != null)
                                FittedBox(
                                  child: Text(
                                    money(d.balance, widget.currency, compact: true),
                                    style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.w600,
                                      color: neg ? scheme.onErrorContainer : null,
                                    ).merge(tabular),
                                  ),
                                ),
                              if (d != null && d.events.isNotEmpty)
                                Container(
                                  width: 5,
                                  height: 5,
                                  margin: const EdgeInsets.only(top: 2),
                                  decoration: BoxDecoration(color: scheme.primary, shape: BoxShape.circle),
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
            ],
          ),
        const SizedBox(height: 8),
        if (picked != null) ...[
          Text(
            '${niceDate(picked.date)}: ${money(picked.balance, widget.currency)} expected'
            '${picked.change == 0 ? '' : ' (${money(picked.change, widget.currency, signed: true)} that day)'}',
            style: const TextStyle(fontWeight: FontWeight.w600).merge(tabular),
          ),
          for (final e in picked.events)
            Text('${e.label} ${money(e.amount, widget.currency, signed: true)}', style: tabular),
        ] else
          Text(
            'Tap a day for its payments. Dots mark bills or pay; the outlined day is the lowest.',
            style: TextStyle(fontSize: 12, color: skin.muted),
          ),
      ],
    );
  }
}
