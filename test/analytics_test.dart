import 'package:kaleidoscope/kaleidoscope.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  final now = DateTime(2026, 11, 20, 12);

  List<AIUsageRecord> rising() => [
    for (var d = 0; d < 30; d++)
      rec(
        at: now.subtract(Duration(days: 29 - d)),
        cost: 1.0 + d * 0.1,
        input: 1000 + d * 10,
        latency: 200 + d * 10,
        context: AIUsageContext(
          module: d.isEven ? 'chat' : 'search',
          page: 'p${d % 3}',
          section: 's',
        ),
        model: d % 5 == 0 ? 'claude-sonnet-5-5' : 'gpt-4o-mini',
      ),
  ];

  test('totals and breakdowns', () {
    final e = AnalyticsEngine(rising(), now: now);
    final t = e.totals;
    expect(t.calls, 30);
    expect(t.cost, closeTo(30 + 0.1 * 435, 1e-9));
    final byModule = e.breakdown(UsageDimension.module);
    expect(byModule.map((b) => b.key).toSet(), {'chat', 'search'});
    expect(
      byModule.fold<double>(0, (s, b) => s + b.costShare),
      closeTo(1, 1e-9),
    );
    final byModel = e.breakdown(UsageDimension.model);
    expect(byModel.first.key, 'gpt-4o-mini');
    expect(e.breakdown(UsageDimension.fullPath).first.key, contains('›'));
    final tree = e.tree();
    expect(tree, hasLength(2));
    expect(tree.first.children, isNotEmpty);
    expect(tree.first.children.first.children.first.name, 's');
  });

  test('time series fills gaps', () {
    final rs = [rec(at: now.subtract(const Duration(days: 3))), rec(at: now)];
    final s = AnalyticsEngine(rs, now: now).timeSeries(TimeBucket.day);
    expect(s, hasLength(4));
    expect(s[1].totals.calls, 0);
  });

  test('forecast follows a rising trend', () {
    final f = AnalyticsEngine(rising(), now: now).forecast(days: 7);
    expect(f.method, 'holt');
    expect(f.trend, 'rising');
    expect(f.points, hasLength(7));
    expect(f.points.first.value, greaterThan(3.5));
    expect(f.points.first.upper, greaterThanOrEqualTo(f.points.first.value));
    expect(f.confidence, greaterThan(0.5));
  });

  test('forecast with little or no data', () {
    expect(AnalyticsEngine([], now: now).forecast().total, 0);
    final few = [
      rec(at: now, cost: 2),
      rec(at: now.subtract(const Duration(days: 1)), cost: 4),
    ];
    expect(AnalyticsEngine(few, now: now).forecast(days: 1).method, 'average');
  });

  test('anomaly detection flags a spike', () {
    final rs = [
      for (var d = 0; d < 20; d++)
        rec(
          at: now.subtract(Duration(days: 20 - d)),
          cost: 1 + (d % 3) * 0.05,
        ),
      rec(at: now, cost: 25),
    ];
    final a = AnalyticsEngine(rs, now: now).anomalies();
    expect(a, isNotEmpty);
    expect(a.last.isSpike, isTrue);
    expect(a.last.value, 25);
  });

  test('latency percentiles', () {
    final rs = [
      for (var i = 1; i <= 100; i++) rec(at: now, latency: i * 10, input: i),
    ];
    final l = AnalyticsEngine(rs, now: now).latency();
    expect(l.p50, closeTo(505, 1));
    expect(l.p99, closeTo(990, 1.5));
    expect(l.max, 1000);
  });

  test('budget projection and insights', () {
    final e = AnalyticsEngine(rising(), now: now);
    final b = e.budget(20);
    expect(b.spent, greaterThan(20));
    expect(b.onTrack, isFalse);
    final ins = e.insights(monthlyBudget: 20);
    expect(ins.any((i) => i.title == 'Budget at risk'), isTrue);
    final report = e.report(monthlyBudget: 20);
    expect(report.toJson()['totals'], isA<Map<String, Object?>>());
    expect(report.heatmap, hasLength(7));
  });

  test('period comparison', () {
    final c = AnalyticsEngine(
      rising(),
      now: now,
    ).compare(const Duration(days: 7));
    expect(c.costChange, greaterThan(0));
  });

  test('tracker analytics API and exports', () async {
    final t = await newTracker(monthlyBudget: 100);
    for (final r in rising()) {
      t.record(
        provider: r.provider,
        model: r.model,
        inputTokens: r.usage.inputTokens,
        outputTokens: r.usage.outputTokens,
        latencyMs: r.latencyMs,
        context: r.context,
      );
    }
    final s = await t.analytics.summary();
    expect(s.calls, 30);
    final report = await t.analytics.report();
    expect(report.byModule, isNotEmpty);
    final recs = await t.records();
    final csv = AIUsageExporter.toCsv(recs);
    expect(csv.split('\n').first, startsWith('id,timestamp,provider'));
    expect(csv.trim().split('\n'), hasLength(31));
    final html = AIUsageExporter.toHtml(report, title: 'My <App>');
    expect(html, contains('My &lt;App&gt;'));
    expect(html, contains('<svg'));
    expect(AIUsageExporter.toJson(recs), contains('"provider"'));
    await t.dispose();
  });
}
