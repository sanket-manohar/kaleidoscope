import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../analytics/analytics_engine.dart';
import '../analytics/analytics_models.dart';
import 'format.dart';

/// Palette used by the charts. Override via [AIChartTheme.of] by wrapping
/// in `Theme`; colours derive from the ColorScheme by default.
class AIChartPalette {
  static List<Color> series(ColorScheme s) => [
    s.primary,
    const Color(0xFFF59E0B),
    const Color(0xFF10B981),
    const Color(0xFFEF4444),
    const Color(0xFF8B5CF6),
    const Color(0xFF06B6D4),
    const Color(0xFFEC4899),
    const Color(0xFF84CC16),
  ];
}

/// Metric shown by charts.
enum AIChartMetric { cost, tokens, calls, errors }

String _metricKey(AIChartMetric m) => switch (m) {
  AIChartMetric.cost => 'cost',
  AIChartMetric.tokens => 'tokens',
  AIChartMetric.calls => 'calls',
  AIChartMetric.errors => 'errors',
};

String _fmt(AIChartMetric m, double v, String currency) => switch (m) {
  AIChartMetric.cost => AIFormat.money(v, currency),
  AIChartMetric.tokens => AIFormat.tokens(v),
  _ => v.toStringAsFixed(0),
};

/// Line chart of a time series with an optional dashed forecast.
class AIUsageLineChart extends StatelessWidget {
  const AIUsageLineChart({
    super.key,
    required this.points,
    this.metric = AIChartMetric.cost,
    this.forecast,
    this.height = 220,
    this.currency = 'USD',
    this.showHours = false,
  });

  final List<TimePoint> points;
  final AIChartMetric metric;
  final UsageForecast? forecast;
  final double height;
  final String currency;
  final bool showHours;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (points.isEmpty) {
      return SizedBox(
        height: height,
        child: const Center(child: Text('No data yet')),
      );
    }
    final hist = <FlSpot>[
      for (var i = 0; i < points.length; i++)
        FlSpot(
          i.toDouble(),
          AnalyticsEngine.metricOf(points[i].totals, _metricKey(metric)),
        ),
    ];
    final fc = forecast?.points ?? const <ForecastPoint>[];
    final future = <FlSpot>[
      if (fc.isNotEmpty) hist.last,
      for (var i = 0; i < fc.length; i++)
        FlSpot((points.length + i).toDouble(), fc[i].value),
    ];
    final upper = <FlSpot>[
      if (fc.isNotEmpty) hist.last,
      for (var i = 0; i < fc.length; i++)
        FlSpot((points.length + i).toDouble(), fc[i].upper),
    ];
    final lower = <FlSpot>[
      if (fc.isNotEmpty) hist.last,
      for (var i = 0; i < fc.length; i++)
        FlSpot((points.length + i).toDouble(), fc[i].lower),
    ];
    const band = Color(0xFFF59E0B);
    final maxY = [...hist, ...upper].map((s) => s.y).fold<double>(0, math.max);
    final dates = [...points.map((p) => p.start), ...fc.map((p) => p.date)];
    final total = dates.length;
    final step = math.max(1, (total / 5).ceil());
    return SizedBox(
      height: height,
      child: Padding(
        padding: const EdgeInsets.only(right: 12, top: 8),
        child: LineChart(
          LineChartData(
            minY: 0,
            maxY: maxY == 0 ? 1 : maxY * 1.15,
            gridData: FlGridData(
              drawVerticalLine: false,
              getDrawingHorizontalLine: (_) => FlLine(
                color: scheme.outlineVariant.withValues(alpha: .4),
                strokeWidth: 1,
              ),
            ),
            borderData: FlBorderData(show: false),
            lineTouchData: LineTouchData(
              touchTooltipData: LineTouchTooltipData(
                getTooltipColor: (_) => scheme.inverseSurface,
                getTooltipItems: (spots) => spots.map((s) {
                  if (s.barIndex >= 2) return null; // forecast band edges
                  final i = s.x.toInt().clamp(0, total - 1);
                  final d = dates[i];
                  return LineTooltipItem(
                    '${showHours ? '${d.hour}:00' : '${d.month}/${d.day}'}\n${_fmt(metric, s.y, currency)}',
                    TextStyle(color: scheme.onInverseSurface, fontSize: 12),
                  );
                }).toList(),
              ),
            ),
            titlesData: FlTitlesData(
              topTitles: const AxisTitles(
                sideTitles: SideTitles(showTitles: false),
              ),
              rightTitles: const AxisTitles(
                sideTitles: SideTitles(showTitles: false),
              ),
              leftTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: 52,
                  getTitlesWidget: (v, meta) {
                    // Skip the padded top value so labels never repeat.
                    if (v == meta.max && v % meta.appliedInterval != 0) {
                      return const SizedBox.shrink();
                    }
                    return SideTitleWidget(
                      meta: meta,
                      child: Text(
                        _fmt(metric, v, currency),
                        style: const TextStyle(fontSize: 10),
                      ),
                    );
                  },
                ),
              ),
              bottomTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  interval: 1,
                  reservedSize: 24,
                  getTitlesWidget: (v, meta) {
                    final i = v.toInt();
                    if (i < 0 || i >= total || i % step != 0) {
                      return const SizedBox.shrink();
                    }
                    final d = dates[i];
                    return SideTitleWidget(
                      meta: meta,
                      child: Text(
                        showHours ? '${d.hour}h' : '${d.month}/${d.day}',
                        style: const TextStyle(fontSize: 10),
                      ),
                    );
                  },
                ),
              ),
            ),
            lineBarsData: [
              LineChartBarData(
                spots: hist,
                isCurved: true,
                preventCurveOverShooting: true,
                color: scheme.primary,
                barWidth: 2.5,
                dotData: FlDotData(show: hist.length < 3),
                belowBarData: BarAreaData(
                  show: true,
                  color: scheme.primary.withValues(alpha: .12),
                ),
              ),
              if (future.length > 1)
                LineChartBarData(
                  spots: future,
                  isCurved: true,
                  preventCurveOverShooting: true,
                  color: const Color(0xFFF59E0B),
                  barWidth: 2,
                  dashArray: [6, 4],
                  dotData: const FlDotData(show: false),
                ),
              if (upper.length > 1) ...[
                // Forecast range (shaded between lower and upper bound).
                LineChartBarData(
                  spots: upper,
                  color: band.withValues(alpha: 0),
                  barWidth: 0,
                  dotData: const FlDotData(show: false),
                ),
                LineChartBarData(
                  spots: lower,
                  color: band.withValues(alpha: 0),
                  barWidth: 0,
                  dotData: const FlDotData(show: false),
                ),
              ],
            ],
            betweenBarsData: [
              if (upper.length > 1)
                BetweenBarsData(
                  fromIndex: 2,
                  toIndex: 3,
                  color: band.withValues(alpha: .10),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Donut chart of a breakdown with a legend.
class AIUsagePieChart extends StatelessWidget {
  const AIUsagePieChart({
    super.key,
    required this.items,
    this.metric = AIChartMetric.cost,
    this.maxSlices = 6,
    this.size = 170,
    this.currency = 'USD',
  });

  final List<BreakdownItem> items;
  final AIChartMetric metric;
  final int maxSlices;
  final double size;
  final String currency;

  double _v(BreakdownItem i) =>
      AnalyticsEngine.metricOf(i.totals, _metricKey(metric));

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final colors = AIChartPalette.series(scheme);
    final sorted = [...items]..sort((a, b) => _v(b).compareTo(_v(a)));
    final shown = sorted.take(maxSlices).toList();
    final rest = sorted.skip(maxSlices).fold<double>(0, (s, i) => s + _v(i));
    final entries = [
      for (final i in shown) (i.key, _v(i)),
      if (rest > 0) ('Other', rest),
    ].where((e) => e.$2 > 0).toList();
    final total = entries.fold<double>(0, (s, e) => s + e.$2);
    if (total == 0) {
      return SizedBox(
        height: size,
        child: const Center(child: Text('No data yet')),
      );
    }
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 16,
      runSpacing: 12,
      children: [
        SizedBox(
          width: size,
          height: size,
          child: PieChart(
            PieChartData(
              centerSpaceRadius: size * .28,
              sectionsSpace: 2,
              sections: [
                for (var i = 0; i < entries.length; i++)
                  PieChartSectionData(
                    value: entries[i].$2,
                    color: colors[i % colors.length],
                    radius: size * .2,
                    title: entries[i].$2 / total > .08
                        ? AIFormat.pct(entries[i].$2 / total)
                        : '',
                    titleStyle: const TextStyle(
                      fontSize: 10,
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
              ],
            ),
          ),
        ),
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < entries.length; i++)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: colors[i % colors.length],
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                    const SizedBox(width: 6),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 160),
                      child: Text(
                        entries[i].$1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      _fmt(metric, entries[i].$2, currency),
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ],
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// Horizontal bars for a breakdown (good for long names like pages).
class AIUsageBarList extends StatelessWidget {
  const AIUsageBarList({
    super.key,
    required this.items,
    this.metric = AIChartMetric.cost,
    this.maxItems = 10,
    this.currency = 'USD',
    this.onTap,
  });

  final List<BreakdownItem> items;
  final AIChartMetric metric;
  final int maxItems;
  final String currency;
  final void Function(BreakdownItem item)? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final shown = items.take(maxItems).toList();
    if (shown.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Text('No data yet'),
      );
    }
    double v(BreakdownItem i) =>
        AnalyticsEngine.metricOf(i.totals, _metricKey(metric));
    final maxV = shown.map(v).fold<double>(0, math.max);
    return Column(
      children: [
        for (final i in shown)
          InkWell(
            onTap: onTap == null ? null : () => onTap!(i),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          i.key,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                      Text(
                        _fmt(metric, v(i), currency),
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '${i.totals.calls} calls',
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: maxV == 0 ? 0 : v(i) / maxV,
                      minHeight: 6,
                      backgroundColor: scheme.surfaceContainerHighest,
                      color: scheme.primary,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// Vertical bar chart (e.g. calls per hour).
class AIUsageBarChart extends StatelessWidget {
  const AIUsageBarChart({
    super.key,
    required this.values,
    required this.labels,
    this.height = 160,
    this.color,
  });
  final List<double> values;
  final List<String> labels;
  final double height;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.primary;
    final maxV = values.fold<double>(0, math.max);
    return SizedBox(
      height: height,
      child: BarChart(
        BarChartData(
          maxY: maxV == 0 ? 1 : maxV * 1.15,
          borderData: FlBorderData(show: false),
          gridData: const FlGridData(show: false),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            rightTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            leftTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 20,
                getTitlesWidget: (v, meta) {
                  final i = v.toInt();
                  if (i < 0 || i >= labels.length) {
                    return const SizedBox.shrink();
                  }
                  return SideTitleWidget(
                    meta: meta,
                    child: Text(labels[i], style: const TextStyle(fontSize: 9)),
                  );
                },
              ),
            ),
          ),
          barGroups: [
            for (var i = 0; i < values.length; i++)
              BarChartGroupData(
                x: i,
                barRods: [
                  BarChartRodData(
                    toY: values[i],
                    color: c,
                    width: math.max(3, 200 / math.max(values.length, 1)),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

/// Weekday × hour activity grid.
class AIUsageHeatmap extends StatelessWidget {
  const AIUsageHeatmap({super.key, required this.grid});
  final List<List<int>> grid;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme.primary;
    final maxV = grid.expand((e) => e).fold<int>(0, math.max);
    const days = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
    return LayoutBuilder(
      builder: (context, box) {
        final cell = ((box.maxWidth - 20) / 24).clamp(6.0, 22.0);
        return Column(
          children: [
            for (var d = 0; d < 7; d++)
              Row(
                children: [
                  SizedBox(
                    width: 20,
                    child: Text(days[d], style: const TextStyle(fontSize: 10)),
                  ),
                  for (var h = 0; h < 24; h++)
                    Tooltip(
                      message: '${grid[d][h]} calls at $h:00',
                      child: Container(
                        width: cell - 2,
                        height: cell - 2,
                        margin: const EdgeInsets.all(1),
                        decoration: BoxDecoration(
                          color: c.withValues(
                            alpha: maxV == 0
                                ? .06
                                : .06 + grid[d][h] / maxV * .94,
                          ),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                ],
              ),
          ],
        );
      },
    );
  }
}

/// A compact KPI card.
class AIStatCard extends StatelessWidget {
  const AIStatCard({
    super.key,
    required this.label,
    required this.value,
    this.caption,
    this.icon,
    this.color,
  });
  final String label;
  final String value;
  final String? caption;
  final IconData? icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Card(
      elevation: 0,
      color: t.colorScheme.surfaceContainerHighest.withValues(alpha: .5),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                if (icon != null)
                  Icon(icon, size: 16, color: color ?? t.colorScheme.primary),
                if (icon != null) const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    label,
                    style: t.textTheme.labelMedium,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                value,
                style: t.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            if (caption != null)
              Text(
                caption!,
                style: t.textTheme.labelSmall?.copyWith(
                  color: t.colorScheme.onSurfaceVariant,
                ),
                maxLines: 2,
              ),
          ],
        ),
      ),
    );
  }
}
