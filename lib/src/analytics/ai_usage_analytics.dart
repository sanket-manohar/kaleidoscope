import '../core/kaleidoscope_tracker.dart';
import '../storage/usage_store.dart';
import 'analytics_engine.dart';
import 'analytics_models.dart';

/// Async analytics over stored records. Every method takes optional
/// [from]/[to] and a [filter] (e.g. only one module or model).
class AIUsageAnalytics {
  AIUsageAnalytics(this._tracker);
  final KaleidoscopeTracker _tracker;

  Future<AnalyticsEngine> engine({
    DateTime? from,
    DateTime? to,
    UsageQuery? filter,
  }) async {
    final q = (filter ?? UsageQuery.all).copyWith(from: from, to: to);
    final rs = await _tracker.records(q);
    return AnalyticsEngine(rs, pricing: _tracker.pricing);
  }

  Future<UsageTotals> summary({
    DateTime? from,
    DateTime? to,
    UsageQuery? filter,
  }) async => (await engine(from: from, to: to, filter: filter)).totals;

  Future<List<BreakdownItem>> breakdown(
    UsageDimension by, {
    String? customKey,
    DateTime? from,
    DateTime? to,
    UsageQuery? filter,
  }) async => (await engine(
    from: from,
    to: to,
    filter: filter,
  )).breakdown(by, customKey: customKey);

  Future<List<UsageTreeNode>> moduleTree({
    DateTime? from,
    DateTime? to,
    UsageQuery? filter,
  }) async => (await engine(from: from, to: to, filter: filter)).tree();

  Future<List<TimePoint>> timeSeries(
    TimeBucket bucket, {
    DateTime? from,
    DateTime? to,
    UsageQuery? filter,
  }) async => (await engine(
    from: from,
    to: to,
    filter: filter,
  )).timeSeries(bucket, from: from, to: to);

  Future<LatencyStats> latency({
    DateTime? from,
    DateTime? to,
    UsageQuery? filter,
  }) async => (await engine(from: from, to: to, filter: filter)).latency();

  Future<UsageForecast> forecast({
    String metric = 'cost',
    int days = 30,
    UsageQuery? filter,
  }) async => (await engine(
    from: DateTime.now().subtract(const Duration(days: 60)),
    filter: filter,
  )).forecast(metric: metric, days: days);

  Future<List<UsageAnomaly>> anomalies({
    String metric = 'cost',
    double zThreshold = 2.5,
    UsageQuery? filter,
  }) async => (await engine(
    from: DateTime.now().subtract(const Duration(days: 90)),
    filter: filter,
  )).anomalies(metric: metric, zThreshold: zThreshold);

  Future<BudgetStatus> budget(
    double monthlyBudget, {
    UsageQuery? filter,
  }) async => (await engine(
    from: DateTime.now().subtract(const Duration(days: 60)),
    filter: filter,
  )).budget(monthlyBudget);

  Future<PeriodComparison> compare(
    Duration period, {
    UsageQuery? filter,
  }) async => (await engine(
    from: DateTime.now().subtract(period * 2),
    filter: filter,
  )).compare(period);

  Future<List<UsageInsight>> insights({
    DateTime? from,
    UsageQuery? filter,
  }) async => (await engine(
    from: from,
    filter: filter,
  )).insights(monthlyBudget: _tracker.config.monthlyBudget);

  /// The full report: totals, every breakdown, module tree, time series,
  /// latency percentiles, forecasts, anomalies, heatmap, insights, budget.
  Future<AIUsageReport> report({
    DateTime? from,
    DateTime? to,
    UsageQuery? filter,
    int forecastDays = 30,
  }) async {
    final e = await engine(from: from, to: to, filter: filter);
    return e.report(
      from: from,
      to: to,
      monthlyBudget: _tracker.config.monthlyBudget,
      forecastDays: forecastDays,
    );
  }
}
