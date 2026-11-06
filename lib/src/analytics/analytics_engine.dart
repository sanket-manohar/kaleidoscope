import 'dart:math' as math;

import '../models/ai_usage_record.dart';
import '../pricing/pricing_table.dart';
import 'analytics_models.dart';

/// Pure functions over a list of records. Everything here is synchronous
/// and safe to call from tests or isolates.
class AnalyticsEngine {
  AnalyticsEngine(this.records, {this.pricing, DateTime? now})
    : now = now ?? DateTime.now();

  final List<AIUsageRecord> records;
  final PricingTable? pricing;
  final DateTime now;

  static UsageTotals totalsOf(
    Iterable<AIUsageRecord> rs, {
    PricingTable? pricing,
  }) {
    var calls = 0, errors = 0, cancelled = 0, inT = 0, outT = 0, cached = 0;
    var write = 0, reasoning = 0, est = 0, lat = 0, latN = 0;
    var cost = 0.0, savings = 0.0;
    String? currency;
    for (final r in rs) {
      calls++;
      if (r.status == AICallStatus.error) errors++;
      if (r.status == AICallStatus.cancelled) cancelled++;
      inT += r.usage.inputTokens;
      outT += r.usage.outputTokens;
      cached += r.usage.cachedInputTokens;
      write += r.usage.cacheWriteTokens;
      reasoning += r.usage.reasoningTokens;
      if (r.usage.estimated) est++;
      cost += r.cost.total;
      currency ??= r.cost.priced ? r.cost.currency : null;
      if (r.latencyMs != null) {
        lat += r.latencyMs!;
        latN++;
      }
      if (pricing != null && r.usage.cachedInputTokens > 0) {
        final p = pricing.lookup(r.model, provider: r.provider);
        if (p != null) {
          savings +=
              r.usage.cachedInputTokens *
              (p.inputPerMillion -
                  (p.cachedInputPerMillion ?? p.inputPerMillion)) /
              1e6;
        }
      }
    }
    return UsageTotals(
      calls: calls,
      errors: errors,
      cancelled: cancelled,
      inputTokens: inT,
      outputTokens: outT,
      cachedInputTokens: cached,
      cacheWriteTokens: write,
      reasoningTokens: reasoning,
      estimatedCalls: est,
      cost: cost,
      cacheSavings: savings,
      totalLatencyMs: lat,
      latencySamples: latN,
      currency: currency ?? 'USD',
    );
  }

  UsageTotals get totals => totalsOf(records, pricing: pricing);

  static String keyOf(
    AIUsageRecord r,
    UsageDimension d, {
    String unset = '(none)',
  }) {
    final c = r.context;
    String v(String? s) => (s == null || s.isEmpty) ? unset : s;
    switch (d) {
      case UsageDimension.provider:
        return r.provider;
      case UsageDimension.model:
        return r.model;
      case UsageDimension.module:
        return v(c.module);
      case UsageDimension.page:
        return v(c.page);
      case UsageDimension.section:
        return v(c.section);
      case UsageDimension.feature:
        return v(c.feature);
      case UsageDimension.operation:
        return r.operation;
      case UsageDimension.status:
        return r.status.name;
      case UsageDimension.modulePage:
        return '${v(c.module)} › ${v(c.page)}';
      case UsageDimension.fullPath:
        return '${v(c.module)} › ${v(c.page)} › ${v(c.section)}';
      case UsageDimension.user:
        return v(c.userId);
      case UsageDimension.conversation:
        return v(c.conversationId);
    }
  }

  /// Groups by [dimension] (or by `context.custom[customKey]` when given),
  /// sorted by cost then tokens.
  List<BreakdownItem> breakdown(UsageDimension dimension, {String? customKey}) {
    final groups = <String, List<AIUsageRecord>>{};
    for (final r in records) {
      final k = customKey != null
          ? '${r.context.custom[customKey] ?? r.customData[customKey] ?? '(none)'}'
          : keyOf(r, dimension);
      (groups[k] ??= []).add(r);
    }
    final all = totals;
    final items =
        groups.entries.map((e) {
          final t = totalsOf(e.value, pricing: pricing);
          return BreakdownItem(
            e.key,
            t,
            all.cost == 0 ? 0 : t.cost / all.cost,
            all.totalTokens == 0 ? 0 : t.totalTokens / all.totalTokens,
          );
        }).toList()..sort((a, b) {
          final c = b.totals.cost.compareTo(a.totals.cost);
          return c != 0
              ? c
              : b.totals.totalTokens.compareTo(a.totals.totalTokens);
        });
    return items;
  }

  /// module → page → section tree.
  List<UsageTreeNode> tree() {
    List<UsageTreeNode> level(List<AIUsageRecord> rs, int depth) {
      if (depth > 2) return const [];
      final dim = [
        UsageDimension.module,
        UsageDimension.page,
        UsageDimension.section,
      ][depth];
      final groups = <String, List<AIUsageRecord>>{};
      for (final r in rs) {
        (groups[keyOf(r, dim)] ??= []).add(r);
      }
      final nodes =
          groups.entries
              .map(
                (e) => UsageTreeNode(
                  e.key,
                  totalsOf(e.value, pricing: pricing),
                  level(e.value, depth + 1),
                ),
              )
              .toList()
            ..sort(
              (a, b) => b.totals.cost != a.totals.cost
                  ? b.totals.cost.compareTo(a.totals.cost)
                  : b.totals.totalTokens.compareTo(a.totals.totalTokens),
            );
      if (nodes.length == 1 &&
          nodes.first.name == '(none)' &&
          nodes.first.children.isEmpty) {
        return const [];
      }
      return nodes;
    }

    return level(records, 0);
  }

  static DateTime bucketStart(DateTime t, TimeBucket b) {
    switch (b) {
      case TimeBucket.hour:
        return DateTime(t.year, t.month, t.day, t.hour);
      case TimeBucket.day:
        return DateTime(t.year, t.month, t.day);
      case TimeBucket.week:
        final d = DateTime(t.year, t.month, t.day);
        return d.subtract(Duration(days: d.weekday - 1));
      case TimeBucket.month:
        return DateTime(t.year, t.month);
    }
  }

  static DateTime _next(DateTime t, TimeBucket b) {
    switch (b) {
      case TimeBucket.hour:
        return DateTime(t.year, t.month, t.day, t.hour + 1);
      case TimeBucket.day:
        return DateTime(t.year, t.month, t.day + 1);
      case TimeBucket.week:
        return DateTime(t.year, t.month, t.day + 7);
      case TimeBucket.month:
        return DateTime(t.year, t.month + 1);
    }
  }

  /// Time series with empty buckets filled with zeros.
  List<TimePoint> timeSeries(
    TimeBucket bucket, {
    DateTime? from,
    DateTime? to,
  }) {
    if (records.isEmpty && from == null) return const [];
    final groups = <DateTime, List<AIUsageRecord>>{};
    DateTime? minT, maxT;
    for (final r in records) {
      final k = bucketStart(r.timestamp, bucket);
      (groups[k] ??= []).add(r);
      if (minT == null || k.isBefore(minT)) minT = k;
      if (maxT == null || k.isAfter(maxT)) maxT = k;
    }
    var cur = bucketStart(from ?? minT!, bucket);
    final end = bucketStart(to ?? maxT ?? now, bucket);
    final out = <TimePoint>[];
    var guard = 0;
    while (!cur.isAfter(end) && guard++ < 5000) {
      out.add(
        TimePoint(cur, totalsOf(groups[cur] ?? const [], pricing: pricing)),
      );
      cur = _next(cur, bucket);
    }
    return out;
  }

  static double _pct(List<double> sorted, double p) {
    if (sorted.isEmpty) return 0;
    final idx = (p * (sorted.length - 1));
    final lo = idx.floor(), hi = idx.ceil();
    return sorted[lo] + (sorted[hi] - sorted[lo]) * (idx - lo);
  }

  LatencyStats latency() {
    final l =
        records
            .where(
              (r) => r.latencyMs != null && r.status == AICallStatus.success,
            )
            .map((r) => r.latencyMs!.toDouble())
            .toList()
          ..sort();
    final t =
        records
            .where((r) => r.timeToFirstTokenMs != null)
            .map((r) => r.timeToFirstTokenMs!.toDouble())
            .toList()
          ..sort();
    // Median generation speed: robust against outliers and cached replies.
    final speeds =
        records
            .where(
              (r) =>
                  r.latencyMs != null &&
                  r.latencyMs! > 0 &&
                  r.usage.outputTokens > 0,
            )
            .map((r) {
              final genMs = r.streamed && r.timeToFirstTokenMs != null
                  ? r.latencyMs! - r.timeToFirstTokenMs!
                  : r.latencyMs!;
              return r.usage.outputTokens / (math.max(genMs, 50) / 1000);
            })
            .toList()
          ..sort();
    return LatencyStats(
      samples: l.length,
      min: l.isEmpty ? 0 : l.first,
      max: l.isEmpty ? 0 : l.last,
      avg: l.isEmpty ? 0 : l.reduce((a, b) => a + b) / l.length,
      p50: _pct(l, .5),
      p90: _pct(l, .9),
      p95: _pct(l, .95),
      p99: _pct(l, .99),
      ttftSamples: t.length,
      ttftP50: _pct(t, .5),
      ttftP90: _pct(t, .9),
      ttftP99: _pct(t, .99),
      avgOutputTokensPerSecond: _pct(speeds, .5),
    );
  }

  static double metricOf(UsageTotals t, String metric) => switch (metric) {
    'tokens' => t.totalTokens.toDouble(),
    'calls' => t.calls.toDouble(),
    'errors' => t.errors.toDouble(),
    _ => t.cost,
  };

  /// Forecasts the next [days] days of [metric] (`cost`, `tokens`, `calls`)
  /// from the last [lookbackDays] of daily history, using Holt's linear
  /// trend smoothing (or a simpler method with little data), with a ~95%
  /// band from the residuals.
  UsageForecast forecast({
    String metric = 'cost',
    int days = 30,
    int lookbackDays = 60,
  }) {
    final today = DateTime(now.year, now.month, now.day);
    final from = today.subtract(Duration(days: lookbackDays - 1));
    final recent = records.where((r) => !r.timestamp.isBefore(from)).toList();
    final firstDay = recent.isEmpty
        ? today
        : recent
              .map((r) => bucketStart(r.timestamp, TimeBucket.day))
              .reduce((a, b) => a.isBefore(b) ? a : b);
    // Today is still in progress, so it would drag the trend down. Fit on
    // complete days only (when there are any).
    final lastDay = firstDay.isBefore(today)
        ? today.subtract(const Duration(days: 1))
        : today;
    final series = AnalyticsEngine(
      recent,
      pricing: pricing,
      now: now,
    ).timeSeries(TimeBucket.day, from: firstDay, to: lastDay);
    final y = series.map((p) => metricOf(p.totals, metric)).toList();
    final history = [
      for (var i = 0; i < series.length; i++)
        ForecastPoint(series[i].start, y[i], y[i], y[i]),
    ];
    List<ForecastPoint> project(double Function(int h) f, double sigma) => [
      for (var h = 1; h <= days; h++)
        ForecastPoint(
          DateTime(lastDay.year, lastDay.month, lastDay.day + h),
          math.max(0, f(h)),
          math.max(
            0,
            f(h) - 1.96 * sigma * math.sqrt(h.toDouble()).clamp(1, 3),
          ),
          math.max(
            0,
            f(h) + 1.96 * sigma * math.sqrt(h.toDouble()).clamp(1, 3),
          ),
        ),
    ];

    if (y.isEmpty || y.every((v) => v == 0)) {
      return UsageForecast(
        metric: metric,
        history: history,
        points: project((_) => 0, 0),
        slopePerDay: 0,
        method: 'average',
        confidence: 0,
      );
    }
    if (y.length < 4) {
      final avg = y.reduce((a, b) => a + b) / y.length;
      final sd = _std(y, avg);
      return UsageForecast(
        metric: metric,
        history: history,
        points: project((_) => avg, sd),
        slopePerDay: 0,
        method: 'average',
        confidence: 0.2,
      );
    }
    if (y.length < 10) {
      // Least squares line.
      final n = y.length;
      final xm = (n - 1) / 2;
      final ym = y.reduce((a, b) => a + b) / n;
      var num = 0.0, den = 0.0;
      for (var i = 0; i < n; i++) {
        num += (i - xm) * (y[i] - ym);
        den += (i - xm) * (i - xm);
      }
      final slope = den == 0 ? 0.0 : num / den;
      final icpt = ym - slope * xm;
      final res = [for (var i = 0; i < n; i++) y[i] - (icpt + slope * i)];
      final sd = _std(res, 0);
      return UsageForecast(
        metric: metric,
        history: history,
        points: project((h) => icpt + slope * (n - 1 + h), sd),
        slopePerDay: slope,
        method: 'linear',
        confidence: _confidence(y, res),
      );
    }
    // Holt's linear trend (double exponential smoothing).
    const alpha = 0.4, beta = 0.2;
    var level = y.first;
    var trend =
        (y[math.min(3, y.length - 1)] - y.first) / math.min(3, y.length - 1);
    final res = <double>[];
    for (var i = 1; i < y.length; i++) {
      final predicted = level + trend;
      res.add(y[i] - predicted);
      final newLevel = alpha * y[i] + (1 - alpha) * (level + trend);
      trend = beta * (newLevel - level) + (1 - beta) * trend;
      level = newLevel;
    }
    // Damp the trend so long horizons don't explode.
    const phi = 0.95;
    double f(int h) {
      var damp = 0.0, p = phi;
      for (var i = 0; i < h; i++) {
        damp += p;
        p *= phi;
      }
      return level + trend * damp;
    }

    return UsageForecast(
      metric: metric,
      history: history,
      points: project(f, _std(res, 0)),
      slopePerDay: trend,
      method: 'holt',
      confidence: _confidence(y.sublist(1), res),
    );
  }

  static double _std(List<double> v, double mean) {
    if (v.length < 2) return 0;
    final s = v.fold<double>(0, (a, x) => a + (x - mean) * (x - mean));
    return math.sqrt(s / (v.length - 1));
  }

  static double _confidence(List<double> y, List<double> residuals) {
    final mean = y.reduce((a, b) => a + b) / y.length;
    final ssTot = y.fold<double>(0, (a, v) => a + (v - mean) * (v - mean));
    final ssRes = residuals.fold<double>(0, (a, v) => a + v * v);
    if (ssTot == 0) return ssRes == 0 ? 1 : 0;
    final r2 = 1 - ssRes / ssTot;
    // Blend R² with the amount of data we have.
    final dataFactor = math.min(1.0, y.length / 30);
    return (math.max(0.0, r2) * 0.6 + dataFactor * 0.4).clamp(0.0, 1.0);
  }

  /// Days whose [metric] deviates from the trailing 14-day mean by more than
  /// [zThreshold] standard deviations.
  List<UsageAnomaly> anomalies({
    String metric = 'cost',
    double zThreshold = 2.5,
    int window = 14,
  }) {
    final series = timeSeries(TimeBucket.day);
    final out = <UsageAnomaly>[];
    for (var i = window ~/ 2; i < series.length; i++) {
      final start = math.max(0, i - window);
      final prev = [
        for (var j = start; j < i; j++) metricOf(series[j].totals, metric),
      ];
      if (prev.length < 5) continue;
      final mean = prev.reduce((a, b) => a + b) / prev.length;
      final sd = _std(prev, mean);
      final v = metricOf(series[i].totals, metric);
      if (sd == 0) {
        if (mean > 0 && v > mean * 3) {
          out.add(UsageAnomaly(series[i].start, metric, v, mean, 99));
        }
        continue;
      }
      final z = (v - mean) / sd;
      if (z.abs() >= zThreshold) {
        out.add(UsageAnomaly(series[i].start, metric, v, mean, z));
      }
    }
    return out;
  }

  /// `[weekday 0=Mon..6][hour 0..23]` → number of calls.
  List<List<int>> heatmap() {
    final grid = List.generate(7, (_) => List.filled(24, 0));
    for (final r in records) {
      grid[r.timestamp.weekday - 1][r.timestamp.hour]++;
    }
    return grid;
  }

  /// Current month spend vs [monthlyBudget] with a month-end projection.
  BudgetStatus budget(double monthlyBudget) {
    final monthStart = DateTime(now.year, now.month);
    final monthEnd = DateTime(now.year, now.month + 1);
    final spent = records
        .where((r) => !r.timestamp.isBefore(monthStart))
        .fold<double>(0, (s, r) => s + r.cost.total);
    final daysInMonth = monthEnd.difference(monthStart).inDays;
    final elapsed = now.difference(monthStart).inMinutes / (24 * 60);
    final daysLeft = math.max(0, daysInMonth - now.day);
    final today = DateTime(now.year, now.month, now.day);
    final f = forecast(metric: 'cost', days: daysLeft + 2);
    // Rest of today: the forecast for today minus what is already spent today.
    final spentToday = records
        .where((r) => !r.timestamp.isBefore(today))
        .fold<double>(0, (s, r) => s + r.cost.total);
    final todayPoint = f.points.where((p) => p.date == today).toList();
    final restOfToday = todayPoint.isEmpty
        ? 0.0
        : math.max(0.0, todayPoint.first.value - spentToday);
    final future = f.points
        .where((p) => p.date.isAfter(today) && p.date.isBefore(monthEnd))
        .fold<double>(0, (s, p) => s + p.value);
    final projected = elapsed < 3
        ? (elapsed <= 0 ? spent : spent / elapsed * daysInMonth)
        : spent + restOfToday + future;
    return BudgetStatus(
      budget: monthlyBudget,
      spent: spent,
      projected: projected,
      daysLeft: daysLeft,
    );
  }

  /// Compares the last [period] with the one before it.
  PeriodComparison compare(Duration period) {
    final curStart = now.subtract(period);
    final prevStart = curStart.subtract(period);
    return PeriodComparison(
      totalsOf(
        records.where((r) => !r.timestamp.isBefore(curStart)),
        pricing: pricing,
      ),
      totalsOf(
        records.where(
          (r) =>
              !r.timestamp.isBefore(prevStart) &&
              r.timestamp.isBefore(curStart),
        ),
        pricing: pricing,
      ),
    );
  }

  static Map<String, Object?> _brief(AIUsageRecord r) => {
    'id': r.id,
    'time': r.timestamp.toIso8601String(),
    'provider': r.provider,
    'model': r.model,
    'where': r.context.toString(),
    'tokens': r.usage.totalTokens,
    'cost': r.cost.total,
    'latencyMs': r.latencyMs,
    'status': r.status.name,
    if (r.errorMessage != null) 'error': r.errorMessage,
  };

  List<AIUsageRecord> topBy(num Function(AIUsageRecord) f, {int n = 10}) =>
      (List.of(records)..sort((a, b) => f(b).compareTo(f(a)))).take(n).toList();

  /// Plain-language observations about the data.
  List<UsageInsight> insights({double? monthlyBudget}) {
    final out = <UsageInsight>[];
    final t = totals;
    if (t.calls == 0) return out;
    String money(double v) =>
        '${t.currency == 'USD' ? r'$' : '${t.currency} '}${v.toStringAsFixed(v < 1 ? 4 : 2)}';
    final byModule = breakdown(
      UsageDimension.module,
    ).where((b) => b.key != '(none)').toList();
    if (byModule.isNotEmpty &&
        byModule.first.costShare > 0.5 &&
        byModule.length > 1) {
      out.add(
        UsageInsight(
          InsightLevel.info,
          'One module drives most cost',
          '"${byModule.first.key}" accounts for ${(byModule.first.costShare * 100).round()}% of spend (${money(byModule.first.totals.cost)}).',
        ),
      );
    }
    final untagged = records
        .where((r) => r.context.module == null && r.context.page == null)
        .length;
    if (untagged / t.calls > 0.3) {
      out.add(
        UsageInsight(
          InsightLevel.info,
          'Many calls are untagged',
          '${(untagged / t.calls * 100).round()}% of calls have no module/page. Wrap them with Kaleidoscope.scope(...) or add AIUsageNavigatorObserver.',
        ),
      );
    }
    if (t.errorRate > 0.05) {
      final byModel = breakdown(UsageDimension.model)
        ..sort((a, b) => b.totals.errorRate.compareTo(a.totals.errorRate));
      out.add(
        UsageInsight(
          t.errorRate > 0.2 ? InsightLevel.critical : InsightLevel.warning,
          'High error rate: ${(t.errorRate * 100).toStringAsFixed(1)}%',
          'Worst model: ${byModel.first.key} (${(byModel.first.totals.errorRate * 100).toStringAsFixed(1)}% errors). Consider retries or a fallback provider.',
        ),
      );
    }
    final promptTokens = t.inputTokens + t.cachedInputTokens;
    if (promptTokens > 200000 && t.cacheHitRate < 0.1) {
      out.add(
        const UsageInsight(
          InsightLevel.info,
          'Low prompt-cache usage',
          'Less than 10% of prompt tokens are cached. Keeping system prompts stable and enabling prompt caching can cut input cost a lot.',
        ),
      );
    }
    if (t.cacheSavings > 0) {
      out.add(
        UsageInsight(
          InsightLevel.info,
          'Prompt caching saved ${money(t.cacheSavings)}',
          '${(t.cacheHitRate * 100).toStringAsFixed(1)}% of prompt tokens came from cache.',
        ),
      );
    }
    if (t.estimatedCalls / t.calls > 0.2) {
      out.add(
        UsageInsight(
          InsightLevel.warning,
          'Some token counts are estimated',
          '${t.estimatedCalls} calls had no usage data from the provider. For OpenAI-compatible streams set injectStreamUsageOption: true.',
        ),
      );
    }
    final unpriced = records
        .where((r) => !r.cost.priced && r.provider != 'on-device')
        .map((r) => r.model)
        .toSet();
    if (unpriced.isNotEmpty) {
      out.add(
        UsageInsight(
          InsightLevel.warning,
          'Models without a price',
          '${unpriced.take(5).join(', ')}. Add them with Kaleidoscope.pricing.setPrice(...).',
        ),
      );
    }
    final cmp = compare(const Duration(days: 7));
    if (cmp.previous.cost > 0 && cmp.costChange.abs() > 0.25) {
      out.add(
        UsageInsight(
          cmp.costChange > 0.5 ? InsightLevel.warning : InsightLevel.info,
          'Weekly spend ${cmp.costChange > 0 ? 'up' : 'down'} ${(cmp.costChange.abs() * 100).round()}%',
          '${money(cmp.current.cost)} in the last 7 days vs ${money(cmp.previous.cost)} the week before.',
        ),
      );
    }
    final spikes = anomalies().where((a) => a.isSpike).toList();
    if (spikes.isNotEmpty) {
      final s = spikes.last;
      out.add(
        UsageInsight(
          InsightLevel.warning,
          'Unusual spike detected',
          '${s.date.toIso8601String().substring(0, 10)}: ${money(s.value)} vs ~${money(s.expected)} expected.',
        ),
      );
    }
    final lat = latency();
    if (lat.samples > 10 && lat.p99 > 4 * math.max(lat.p50, 1)) {
      out.add(
        UsageInsight(
          InsightLevel.info,
          'Long latency tail',
          'p99 is ${(lat.p99 / 1000).toStringAsFixed(1)}s vs p50 ${(lat.p50 / 1000).toStringAsFixed(1)}s. Consider streaming or timeouts.',
        ),
      );
    }
    if (monthlyBudget != null) {
      final b = budget(monthlyBudget);
      if (!b.onTrack) {
        out.add(
          UsageInsight(
            b.percentUsed >= 1 ? InsightLevel.critical : InsightLevel.warning,
            'Budget at risk',
            'Projected ${money(b.projected)} this month vs budget ${money(b.budget)}.',
          ),
        );
      }
    }
    return out;
  }

  AIUsageReport report({
    DateTime? from,
    DateTime? to,
    double? monthlyBudget,
    int forecastDays = 30,
  }) {
    return AIUsageReport(
      generatedAt: now,
      from: from,
      to: to,
      totals: totals,
      byProvider: breakdown(UsageDimension.provider),
      byModel: breakdown(UsageDimension.model),
      byModule: breakdown(UsageDimension.module),
      byPage: breakdown(UsageDimension.modulePage),
      bySection: breakdown(UsageDimension.fullPath),
      byFeature: breakdown(UsageDimension.feature),
      byOperation: breakdown(UsageDimension.operation),
      tree: tree(),
      daily: timeSeries(TimeBucket.day),
      hourly: AnalyticsEngine(
        records
            .where(
              (r) =>
                  r.timestamp.isAfter(now.subtract(const Duration(hours: 48))),
            )
            .toList(),
        pricing: pricing,
        now: now,
      ).timeSeries(TimeBucket.hour),
      latency: latency(),
      costForecast: forecast(metric: 'cost', days: forecastDays),
      tokenForecast: forecast(metric: 'tokens', days: forecastDays),
      anomalies: anomalies(),
      heatmap: heatmap(),
      comparison: compare(const Duration(days: 7)),
      insights: insights(monthlyBudget: monthlyBudget),
      budget: monthlyBudget == null ? null : budget(monthlyBudget),
      topExpensive: topBy(
        (r) => r.cost.total,
      ).where((r) => r.cost.total > 0).map(_brief).toList(),
      slowest: topBy(
        (r) => r.latencyMs ?? 0,
      ).where((r) => r.latencyMs != null).map(_brief).toList(),
      recentErrors: records
          .where((r) => r.isError)
          .take(20)
          .map(_brief)
          .toList(),
    );
  }
}
