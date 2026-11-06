/// Aggregated numbers for a set of records.
class UsageTotals {
  const UsageTotals({
    this.calls = 0,
    this.errors = 0,
    this.cancelled = 0,
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.cachedInputTokens = 0,
    this.cacheWriteTokens = 0,
    this.reasoningTokens = 0,
    this.estimatedCalls = 0,
    this.cost = 0,
    this.cacheSavings = 0,
    this.totalLatencyMs = 0,
    this.latencySamples = 0,
    this.currency = 'USD',
  });

  final int calls;
  final int errors;
  final int cancelled;
  final int inputTokens;
  final int outputTokens;
  final int cachedInputTokens;
  final int cacheWriteTokens;
  final int reasoningTokens;
  final int estimatedCalls;
  final double cost;

  /// Money saved because cached tokens were cheaper than fresh input.
  final double cacheSavings;
  final int totalLatencyMs;
  final int latencySamples;
  final String currency;

  int get successes => calls - errors - cancelled;
  int get totalTokens =>
      inputTokens + outputTokens + cachedInputTokens + cacheWriteTokens;
  double get errorRate => calls == 0 ? 0 : errors / calls;
  double get avgLatencyMs =>
      latencySamples == 0 ? 0 : totalLatencyMs / latencySamples;
  double get avgTokensPerCall => calls == 0 ? 0 : totalTokens / calls;
  double get avgCostPerCall => calls == 0 ? 0 : cost / calls;

  /// Share of prompt tokens served from cache.
  double get cacheHitRate {
    final prompt = inputTokens + cachedInputTokens;
    return prompt == 0 ? 0 : cachedInputTokens / prompt;
  }

  /// Output tokens per input token.
  double get outputInputRatio {
    final i = inputTokens + cachedInputTokens;
    return i == 0 ? 0 : outputTokens / i;
  }

  double get costPer1kTokens =>
      totalTokens == 0 ? 0 : cost / totalTokens * 1000;

  Map<String, Object?> toJson() => {
    'calls': calls,
    'successes': successes,
    'errors': errors,
    'cancelled': cancelled,
    'errorRate': errorRate,
    'inputTokens': inputTokens,
    'outputTokens': outputTokens,
    'cachedInputTokens': cachedInputTokens,
    'cacheWriteTokens': cacheWriteTokens,
    'reasoningTokens': reasoningTokens,
    'totalTokens': totalTokens,
    'estimatedCalls': estimatedCalls,
    'cost': cost,
    'cacheSavings': cacheSavings,
    'currency': currency,
    'avgLatencyMs': avgLatencyMs,
    'avgTokensPerCall': avgTokensPerCall,
    'avgCostPerCall': avgCostPerCall,
    'cacheHitRate': cacheHitRate,
    'costPer1kTokens': costPer1kTokens,
  };
}

/// What to group by.
enum UsageDimension {
  provider,
  model,
  module,
  page,
  section,
  feature,
  operation,
  status,

  /// `module › page`
  modulePage,

  /// `module › page › section`
  fullPath,
  user,
  conversation,
}

class BreakdownItem {
  const BreakdownItem(this.key, this.totals, this.costShare, this.tokenShare);
  final String key;
  final UsageTotals totals;
  final double costShare;
  final double tokenShare;
  Map<String, Object?> toJson() => {
    'key': key,
    'costShare': costShare,
    'tokenShare': tokenShare,
    ...totals.toJson(),
  };
}

/// Hierarchical module → page → section tree.
class UsageTreeNode {
  UsageTreeNode(this.name, this.totals, this.children);
  final String name;
  final UsageTotals totals;
  final List<UsageTreeNode> children;
  Map<String, Object?> toJson() => {
    'name': name,
    ...totals.toJson(),
    if (children.isNotEmpty)
      'children': children.map((c) => c.toJson()).toList(),
  };
}

enum TimeBucket { hour, day, week, month }

class TimePoint {
  const TimePoint(this.start, this.totals);
  final DateTime start;
  final UsageTotals totals;
  Map<String, Object?> toJson() => {
    'start': start.toIso8601String(),
    ...totals.toJson(),
  };
}

class LatencyStats {
  const LatencyStats({
    this.samples = 0,
    this.min = 0,
    this.max = 0,
    this.avg = 0,
    this.p50 = 0,
    this.p90 = 0,
    this.p95 = 0,
    this.p99 = 0,
    this.ttftSamples = 0,
    this.ttftP50 = 0,
    this.ttftP90 = 0,
    this.ttftP99 = 0,
    this.avgOutputTokensPerSecond = 0,
  });
  final int samples;
  final double min, max, avg, p50, p90, p95, p99;
  final int ttftSamples;
  final double ttftP50, ttftP90, ttftP99;

  /// Streaming/generation speed estimate.
  final double avgOutputTokensPerSecond;

  Map<String, Object?> toJson() => {
    'samples': samples,
    'min': min,
    'max': max,
    'avg': avg,
    'p50': p50,
    'p90': p90,
    'p95': p95,
    'p99': p99,
    'ttftSamples': ttftSamples,
    'ttftP50': ttftP50,
    'ttftP90': ttftP90,
    'ttftP99': ttftP99,
    'avgOutputTokensPerSecond': avgOutputTokensPerSecond,
  };
}

class ForecastPoint {
  const ForecastPoint(this.date, this.value, this.lower, this.upper);
  final DateTime date;
  final double value, lower, upper;
  Map<String, Object?> toJson() => {
    'date': date.toIso8601String(),
    'value': value,
    'lower': lower,
    'upper': upper,
  };
}

/// Prediction of daily usage based on history.
class UsageForecast {
  const UsageForecast({
    required this.metric,
    required this.history,
    required this.points,
    required this.slopePerDay,
    required this.method,
    required this.confidence,
  });

  /// `cost`, `tokens` or `calls`.
  final String metric;
  final List<ForecastPoint> history;
  final List<ForecastPoint> points;
  final double slopePerDay;

  /// `holt` (trend smoothing) or `linear` or `average` (little data).
  final String method;

  /// 0..1, how well the model fits recent history.
  final double confidence;

  double get total => points.fold(0, (s, p) => s + p.value);
  double get totalLower => points.fold(0, (s, p) => s + p.lower);
  double get totalUpper => points.fold(0, (s, p) => s + p.upper);

  String get trend => slopePerDay.abs() < 1e-9
      ? 'flat'
      : (slopePerDay > 0 ? 'rising' : 'falling');

  Map<String, Object?> toJson() => {
    'metric': metric,
    'method': method,
    'confidence': confidence,
    'trend': trend,
    'slopePerDay': slopePerDay,
    'total': total,
    'totalLower': totalLower,
    'totalUpper': totalUpper,
    'points': points.map((p) => p.toJson()).toList(),
  };
}

class UsageAnomaly {
  const UsageAnomaly(
    this.date,
    this.metric,
    this.value,
    this.expected,
    this.zScore,
  );
  final DateTime date;
  final String metric;
  final double value, expected, zScore;
  bool get isSpike => zScore > 0;
  Map<String, Object?> toJson() => {
    'date': date.toIso8601String(),
    'metric': metric,
    'value': value,
    'expected': expected,
    'zScore': zScore,
  };
}

class BudgetStatus {
  const BudgetStatus({
    required this.budget,
    required this.spent,
    required this.projected,
    required this.daysLeft,
  });
  final double budget, spent, projected;
  final int daysLeft;
  double get percentUsed => budget <= 0 ? 0 : spent / budget;
  double get projectedPercent => budget <= 0 ? 0 : projected / budget;
  bool get onTrack => projected <= budget;
  double get dailyAllowance => daysLeft <= 0
      ? 0
      : ((budget - spent) / daysLeft).clamp(0, double.infinity);
  Map<String, Object?> toJson() => {
    'budget': budget,
    'spent': spent,
    'projected': projected,
    'percentUsed': percentUsed,
    'projectedPercent': projectedPercent,
    'onTrack': onTrack,
    'daysLeft': daysLeft,
    'dailyAllowance': dailyAllowance,
  };
}

class PeriodComparison {
  const PeriodComparison(this.current, this.previous);
  final UsageTotals current, previous;
  double _pct(num a, num b) => b == 0 ? (a == 0 ? 0 : 1) : (a - b) / b;
  double get costChange => _pct(current.cost, previous.cost);
  double get tokenChange => _pct(current.totalTokens, previous.totalTokens);
  double get callChange => _pct(current.calls, previous.calls);
  double get latencyChange => _pct(current.avgLatencyMs, previous.avgLatencyMs);
  Map<String, Object?> toJson() => {
    'current': current.toJson(),
    'previous': previous.toJson(),
    'costChange': costChange,
    'tokenChange': tokenChange,
    'callChange': callChange,
    'latencyChange': latencyChange,
  };
}

enum InsightLevel { info, warning, critical }

class UsageInsight {
  const UsageInsight(this.level, this.title, this.detail);
  final InsightLevel level;
  final String title;
  final String detail;
  Map<String, Object?> toJson() => {
    'level': level.name,
    'title': title,
    'detail': detail,
  };
}

/// Everything at once.
class AIUsageReport {
  const AIUsageReport({
    required this.generatedAt,
    required this.from,
    required this.to,
    required this.totals,
    required this.byProvider,
    required this.byModel,
    required this.byModule,
    required this.byPage,
    required this.bySection,
    required this.byFeature,
    required this.byOperation,
    required this.tree,
    required this.daily,
    required this.hourly,
    required this.latency,
    required this.costForecast,
    required this.tokenForecast,
    required this.anomalies,
    required this.heatmap,
    required this.comparison,
    required this.insights,
    this.budget,
    this.topExpensive = const [],
    this.slowest = const [],
    this.recentErrors = const [],
  });

  final DateTime generatedAt;
  final DateTime? from, to;
  final UsageTotals totals;
  final List<BreakdownItem> byProvider,
      byModel,
      byModule,
      byPage,
      bySection,
      byFeature,
      byOperation;
  final List<UsageTreeNode> tree;
  final List<TimePoint> daily, hourly;
  final LatencyStats latency;
  final UsageForecast costForecast, tokenForecast;
  final List<UsageAnomaly> anomalies;

  /// `[weekday 0=Mon..6][hour 0..23]` → calls.
  final List<List<int>> heatmap;
  final PeriodComparison comparison;
  final List<UsageInsight> insights;
  final BudgetStatus? budget;
  final List<Map<String, Object?>> topExpensive, slowest, recentErrors;

  Map<String, Object?> toJson() => {
    'generatedAt': generatedAt.toIso8601String(),
    'from': from?.toIso8601String(),
    'to': to?.toIso8601String(),
    'totals': totals.toJson(),
    'byProvider': byProvider.map((e) => e.toJson()).toList(),
    'byModel': byModel.map((e) => e.toJson()).toList(),
    'byModule': byModule.map((e) => e.toJson()).toList(),
    'byPage': byPage.map((e) => e.toJson()).toList(),
    'bySection': bySection.map((e) => e.toJson()).toList(),
    'byFeature': byFeature.map((e) => e.toJson()).toList(),
    'byOperation': byOperation.map((e) => e.toJson()).toList(),
    'tree': tree.map((e) => e.toJson()).toList(),
    'daily': daily.map((e) => e.toJson()).toList(),
    'latency': latency.toJson(),
    'costForecast': costForecast.toJson(),
    'tokenForecast': tokenForecast.toJson(),
    'anomalies': anomalies.map((e) => e.toJson()).toList(),
    'heatmap': heatmap,
    'comparison': comparison.toJson(),
    'insights': insights.map((e) => e.toJson()).toList(),
    if (budget != null) 'budget': budget!.toJson(),
    'topExpensive': topExpensive,
    'slowest': slowest,
    'recentErrors': recentErrors,
  };
}
