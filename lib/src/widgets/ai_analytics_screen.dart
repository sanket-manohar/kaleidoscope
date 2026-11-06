import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../analytics/analytics_models.dart';
import '../core/kaleidoscope_tracker.dart';
import '../export/usage_exporter.dart';
import '../models/ai_usage_record.dart';
import '../storage/usage_store.dart';
import 'ai_usage_charts.dart';
import 'format.dart';

/// Export formats offered by the screen's menu.
enum AIExportFormat { json, csv, html }

/// Ready-made analytics dashboard. Push it anywhere:
///
/// ```dart
/// Navigator.push(context, MaterialPageRoute(builder: (_) => const AIAnalyticsScreen()));
/// ```
///
/// By default it only opens in debug builds; set [allowInRelease] (and
/// ideally an [accessPin]) to show it to admins in production.
class AIAnalyticsScreen extends StatefulWidget {
  const AIAnalyticsScreen({
    super.key,
    this.tracker,
    this.title = 'AI usage',
    this.accessPin,
    this.allowInRelease = false,
    this.initialRange = const Duration(days: 7),
    this.onExport,
    this.allowClear = true,
  });

  final KaleidoscopeTracker? tracker;
  final String title;

  /// If set, the screen asks for this PIN first.
  final String? accessPin;
  final bool allowInRelease;
  final Duration? initialRange;

  /// Receives exported text (e.g. to save or share it with share_plus).
  /// Without it, exports are copied to the clipboard.
  final void Function(AIExportFormat format, String content)? onExport;
  final bool allowClear;

  /// Convenience: `AIAnalyticsScreen.open(context)`.
  static Future<void> open(
    BuildContext context, {
    String? accessPin,
    bool allowInRelease = false,
  }) => Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => AIAnalyticsScreen(
        accessPin: accessPin,
        allowInRelease: allowInRelease,
      ),
    ),
  );

  @override
  State<AIAnalyticsScreen> createState() => _AIAnalyticsScreenState();
}

class _AIAnalyticsScreenState extends State<AIAnalyticsScreen> {
  KaleidoscopeTracker get _t => widget.tracker ?? KaleidoscopeTracker.instance;
  late Duration? _range = widget.initialRange;
  AIUsageReport? _report;
  List<AIUsageRecord> _records = const [];
  bool _loading = true;
  Object? _error;
  late bool _unlocked = widget.accessPin == null;
  final _pin = TextEditingController();
  String _search = '';
  UsageDimension _dim = UsageDimension.module;
  AIChartMetric _metric = AIChartMetric.cost;
  Timer? _debounce;

  static const _ranges = <String, Duration?>{
    '24h': Duration(hours: 24),
    '7d': Duration(days: 7),
    '30d': Duration(days: 30),
    '90d': Duration(days: 90),
    'All': null,
  };

  @override
  void initState() {
    super.initState();
    _t.revision.addListener(_onChange);
    _load();
  }

  @override
  void dispose() {
    _t.revision.removeListener(_onChange);
    _debounce?.cancel();
    _pin.dispose();
    super.dispose();
  }

  void _onChange() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 600), _load);
  }

  DateTime? get _from =>
      _range == null ? null : DateTime.now().subtract(_range!);

  Future<void> _load() async {
    try {
      final records = await _t.records(UsageQuery(from: _from, limit: 20000));
      final report = await _t.analytics.report(from: _from);
      if (!mounted) return;
      setState(() {
        _records = records;
        _report = report;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e;
          _loading = false;
        });
      }
    }
  }

  String get _cur => _report?.totals.currency ?? 'USD';

  Future<void> _export(AIExportFormat f) async {
    final r = _report;
    if (r == null) return;
    final content = switch (f) {
      AIExportFormat.json => const JsonEncoder.withIndent('  ').convert({
        'report': r.toJson(),
        'records': _records.map((e) => e.toJson()).toList(),
      }),
      AIExportFormat.csv => AIUsageExporter.toCsv(_records),
      AIExportFormat.html => AIUsageExporter.toHtml(r, title: widget.title),
    };
    if (widget.onExport != null) {
      widget.onExport!(f, content);
      return;
    }
    await Clipboard.setData(ClipboardData(text: content));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${f.name.toUpperCase()} copied to clipboard (${AIFormat.tokens(content.length)} chars)',
          ),
        ),
      );
    }
  }

  Future<void> _clear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete all AI usage data?'),
        content: const Text(
          'This removes every stored record from this device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await _t.clearAll();
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!kDebugMode && !widget.allowInRelease) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.title)),
        body: const Center(
          child: Text('AI analytics is only available in debug builds.'),
        ),
      );
    }
    if (!_unlocked) return _lock();
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.title),
          actions: [
            IconButton(
              tooltip: 'Refresh',
              onPressed: _load,
              icon: const Icon(Icons.refresh),
            ),
            PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'clear') {
                  _clear();
                } else {
                  _export(AIExportFormat.values.byName(v));
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'json', child: Text('Export JSON')),
                const PopupMenuItem(value: 'csv', child: Text('Export CSV')),
                const PopupMenuItem(
                  value: 'html',
                  child: Text('Export HTML report'),
                ),
                if (widget.allowClear)
                  const PopupMenuItem(
                    value: 'clear',
                    child: Text('Delete all data'),
                  ),
              ],
            ),
          ],
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(96),
            child: Column(
              children: [
                SizedBox(
                  height: 44,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    children: [
                      for (final e in _ranges.entries)
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: ChoiceChip(
                            label: Text(e.key),
                            selected: _range == e.value,
                            onSelected: (_) {
                              setState(() => _range = e.value);
                              _load();
                            },
                          ),
                        ),
                    ],
                  ),
                ),
                const TabBar(
                  isScrollable: true,
                  tabs: [
                    Tab(text: 'Overview'),
                    Tab(text: 'Breakdown'),
                    Tab(text: 'Trends'),
                    Tab(text: 'Calls'),
                  ],
                ),
              ],
            ),
          ),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
            ? Center(child: Text('Could not load data: $_error'))
            : TabBarView(
                children: [_overview(), _breakdown(), _trends(), _calls()],
              ),
      ),
    );
  }

  Widget _lock() => Scaffold(
    appBar: AppBar(title: Text(widget.title)),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.lock_outline, size: 40),
              const SizedBox(height: 12),
              TextField(
                controller: _pin,
                obscureText: true,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'PIN',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => _tryPin(),
              ),
              const SizedBox(height: 12),
              FilledButton(onPressed: _tryPin, child: const Text('Unlock')),
            ],
          ),
        ),
      ),
    ),
  );

  void _tryPin() {
    if (_pin.text == widget.accessPin) {
      setState(() => _unlocked = true);
    } else {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Wrong PIN')));
    }
  }

  Widget _section(String title, Widget child, {Widget? trailing}) => Card(
    elevation: 0,
    margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
    shape: RoundedRectangleBorder(
      side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              ?trailing,
            ],
          ),
          const SizedBox(height: 8),
          child,
        ],
      ),
    ),
  );

  Widget _grid(List<Widget> cards) => LayoutBuilder(
    builder: (context, box) {
      final cols = box.maxWidth > 900 ? 4 : (box.maxWidth > 560 ? 3 : 2);
      final w = (box.maxWidth - 24 - (cols - 1) * 4) / cols;
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Wrap(
          spacing: 4,
          runSpacing: 4,
          children: [for (final c in cards) SizedBox(width: w, child: c)],
        ),
      );
    },
  );

  Widget _overview() {
    final r = _report!;
    final t = r.totals;
    final cmp = r.comparison;
    String change(double v) =>
        '${v >= 0 ? '+' : '−'}${AIFormat.pct(v.abs())} vs prev 7 days';
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          _grid([
            AIStatCard(
              label: 'Cost',
              value: AIFormat.money(t.cost, _cur),
              icon: Icons.payments_outlined,
              caption: cmp.previous.calls > 0 ? change(cmp.costChange) : null,
            ),
            AIStatCard(
              label: 'Calls',
              value: '${t.calls}',
              icon: Icons.bolt_outlined,
              caption: '${AIFormat.pct(t.errorRate)} errors',
            ),
            AIStatCard(
              label: 'Input tokens',
              value: AIFormat.tokens(t.inputTokens + t.cachedInputTokens),
              icon: Icons.input,
              caption: t.cachedInputTokens > 0
                  ? '${AIFormat.pct(t.cacheHitRate)} cached'
                  : 'question tokens',
            ),
            AIStatCard(
              label: 'Output tokens',
              value: AIFormat.tokens(t.outputTokens),
              icon: Icons.output,
              caption: t.reasoningTokens > 0
                  ? '${AIFormat.tokens(t.reasoningTokens)} reasoning'
                  : 'answer tokens',
            ),
            AIStatCard(
              label: 'Latency p50 / p99',
              value:
                  '${AIFormat.ms(r.latency.p50)} / ${AIFormat.ms(r.latency.p99)}',
              icon: Icons.timer_outlined,
              caption: r.latency.ttftSamples > 0
                  ? 'TTFT p50 ${AIFormat.ms(r.latency.ttftP50)}'
                  : null,
            ),
            AIStatCard(
              label: 'Next 30 days',
              value: AIFormat.money(r.costForecast.total, _cur),
              icon: Icons.trending_up,
              caption:
                  '${r.costForecast.trend} · ${AIFormat.pct(r.costForecast.confidence)} confidence',
            ),
            if (t.cacheSavings > 0)
              AIStatCard(
                label: 'Cache savings',
                value: AIFormat.money(t.cacheSavings, _cur),
                icon: Icons.savings_outlined,
              ),
            AIStatCard(
              label: 'Avg / call',
              value: AIFormat.money(t.avgCostPerCall, _cur),
              icon: Icons.functions,
              caption: '${AIFormat.tokens(t.avgTokensPerCall)} tokens',
            ),
          ]),
          if (r.budget != null)
            _section(
              'Monthly budget',
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LinearProgressIndicator(
                    value: r.budget!.percentUsed.clamp(0, 1),
                    minHeight: 10,
                    borderRadius: BorderRadius.circular(6),
                    color: r.budget!.onTrack
                        ? null
                        : Theme.of(context).colorScheme.error,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${AIFormat.money(r.budget!.spent, _cur)} of ${AIFormat.money(r.budget!.budget, _cur)} · '
                    'projected ${AIFormat.money(r.budget!.projected, _cur)} · ${r.budget!.daysLeft} days left',
                  ),
                ],
              ),
            ),
          if (r.insights.isNotEmpty)
            _section(
              'Insights',
              Column(
                children: [
                  for (final i in r.insights)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        switch (i.level) {
                          InsightLevel.critical => Icons.error_outline,
                          InsightLevel.warning => Icons.warning_amber_outlined,
                          InsightLevel.info => Icons.lightbulb_outline,
                        },
                        color: switch (i.level) {
                          InsightLevel.critical => Theme.of(
                            context,
                          ).colorScheme.error,
                          InsightLevel.warning => Colors.orange,
                          InsightLevel.info => Theme.of(
                            context,
                          ).colorScheme.primary,
                        },
                      ),
                      title: Text(i.title),
                      subtitle: Text(i.detail),
                    ),
                ],
              ),
            ),
          _section(
            'Cost per day',
            AIUsageLineChart(
              points: r.daily,
              forecast: r.costForecast,
              currency: _cur,
            ),
          ),
          _section(
            'Cost by model',
            AIUsagePieChart(items: r.byModel, currency: _cur),
          ),
          _section(
            'Cost by module',
            AIUsageBarList(items: r.byModule, currency: _cur),
          ),
        ],
      ),
    );
  }

  List<BreakdownItem> _itemsFor(UsageDimension d) {
    final r = _report!;
    return switch (d) {
      UsageDimension.provider => r.byProvider,
      UsageDimension.model => r.byModel,
      UsageDimension.module => r.byModule,
      UsageDimension.modulePage => r.byPage,
      UsageDimension.fullPath => r.bySection,
      UsageDimension.feature => r.byFeature,
      UsageDimension.operation => r.byOperation,
      _ => r.byModule,
    };
  }

  Widget _breakdown() {
    const dims = {
      UsageDimension.module: 'Module',
      UsageDimension.modulePage: 'Page',
      UsageDimension.fullPath: 'Section',
      UsageDimension.model: 'Model',
      UsageDimension.provider: 'Provider',
      UsageDimension.feature: 'Feature',
      UsageDimension.operation: 'Operation',
    };
    final items = _itemsFor(_dim);
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        SizedBox(
          height: 44,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              for (final e in dims.entries)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(
                    label: Text(e.value),
                    selected: _dim == e.key,
                    onSelected: (_) => setState(() => _dim = e.key),
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: SegmentedButton<AIChartMetric>(
            segments: const [
              ButtonSegment(value: AIChartMetric.cost, label: Text('Cost')),
              ButtonSegment(value: AIChartMetric.tokens, label: Text('Tokens')),
              ButtonSegment(value: AIChartMetric.calls, label: Text('Calls')),
            ],
            selected: {_metric},
            onSelectionChanged: (s) => setState(() => _metric = s.first),
          ),
        ),
        _section(
          'Share',
          AIUsagePieChart(items: items, metric: _metric, currency: _cur),
        ),
        _section(
          'Ranking',
          AIUsageBarList(
            items: items,
            metric: _metric,
            maxItems: 25,
            currency: _cur,
          ),
        ),
        _section('Module › page › section', _tree(_report!.tree)),
        _section(
          'Table',
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columnSpacing: 18,
              headingRowHeight: 36,
              dataRowMinHeight: 32,
              dataRowMaxHeight: 40,
              columns: const [
                DataColumn(label: Text('Name')),
                DataColumn(label: Text('Calls'), numeric: true),
                DataColumn(label: Text('In'), numeric: true),
                DataColumn(label: Text('Out'), numeric: true),
                DataColumn(label: Text('Cost'), numeric: true),
                DataColumn(label: Text('Avg ms'), numeric: true),
                DataColumn(label: Text('Errors'), numeric: true),
              ],
              rows: [
                for (final i in items)
                  DataRow(
                    cells: [
                      DataCell(
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 220),
                          child: Text(i.key, overflow: TextOverflow.ellipsis),
                        ),
                      ),
                      DataCell(Text('${i.totals.calls}')),
                      DataCell(
                        Text(
                          AIFormat.tokens(
                            i.totals.inputTokens + i.totals.cachedInputTokens,
                          ),
                        ),
                      ),
                      DataCell(Text(AIFormat.tokens(i.totals.outputTokens))),
                      DataCell(Text(AIFormat.money(i.totals.cost, _cur))),
                      DataCell(Text(i.totals.avgLatencyMs.toStringAsFixed(0))),
                      DataCell(Text(AIFormat.pct(i.totals.errorRate))),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _tree(List<UsageTreeNode> nodes, [int depth = 0]) {
    if (nodes.isEmpty) {
      return const Text('Tag calls with module/page/section to see this tree.');
    }
    return Column(
      children: [
        for (final n in nodes)
          n.children.isEmpty
              ? ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.only(left: depth * 16.0),
                  title: Text(n.name),
                  trailing: Text(
                    '${AIFormat.money(n.totals.cost, _cur)} · ${AIFormat.tokens(n.totals.totalTokens)}',
                  ),
                )
              : ExpansionTile(
                  dense: true,
                  tilePadding: EdgeInsets.only(left: depth * 16.0, right: 8),
                  title: Text(n.name),
                  subtitle: Text(
                    '${n.totals.calls} calls · ${AIFormat.tokens(n.totals.totalTokens)} tokens',
                  ),
                  trailing: Text(AIFormat.money(n.totals.cost, _cur)),
                  children: [_tree(n.children, depth + 1)],
                ),
      ],
    );
  }

  Widget _trends() {
    final r = _report!;
    final l = r.latency;
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        _section(
          'Tokens per day (with forecast)',
          AIUsageLineChart(
            points: r.daily,
            metric: AIChartMetric.tokens,
            forecast: r.tokenForecast,
          ),
        ),
        _section(
          'Calls per hour (last 48h)',
          AIUsageLineChart(
            points: r.hourly,
            metric: AIChartMetric.calls,
            showHours: true,
            height: 180,
          ),
        ),
        _section(
          'Forecast',
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Next ${r.costForecast.points.length} days: ${AIFormat.money(r.costForecast.total, _cur)} '
                '(range ${AIFormat.money(r.costForecast.totalLower, _cur)} – ${AIFormat.money(r.costForecast.totalUpper, _cur)})',
              ),
              Text(
                'Tokens: ${AIFormat.tokens(r.tokenForecast.total)} · trend ${r.costForecast.trend} · '
                'method ${r.costForecast.method} · confidence ${AIFormat.pct(r.costForecast.confidence)}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        _section(
          'Latency',
          Wrap(
            spacing: 16,
            runSpacing: 8,
            children: [
              for (final e in {
                'p50': l.p50,
                'p90': l.p90,
                'p95': l.p95,
                'p99': l.p99,
                'max': l.max,
                'TTFT p50': l.ttftP50,
                'TTFT p90': l.ttftP90,
              }.entries)
                Column(
                  children: [
                    Text(
                      AIFormat.ms(e.value),
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    Text(e.key, style: Theme.of(context).textTheme.labelSmall),
                  ],
                ),
              Column(
                children: [
                  Text(
                    l.avgOutputTokensPerSecond.toStringAsFixed(1),
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  Text(
                    'tokens/s',
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ],
              ),
            ],
          ),
        ),
        _section(
          'Activity by weekday and hour',
          AIUsageHeatmap(grid: r.heatmap),
        ),
        _section(
          'Anomalies',
          r.anomalies.isEmpty
              ? const Text('No unusual days detected.')
              : Column(
                  children: [
                    for (final a in r.anomalies.reversed.take(10))
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          a.isSpike ? Icons.trending_up : Icons.trending_down,
                        ),
                        title: Text(
                          '${a.date.month}/${a.date.day}: ${AIFormat.money(a.value, _cur)}',
                        ),
                        subtitle: Text(
                          'expected ~${AIFormat.money(a.expected, _cur)} (z=${a.zScore.toStringAsFixed(1)})',
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _calls() {
    final s = _search.toLowerCase();
    final list = s.isEmpty
        ? _records
        : _records.where((r) => UsageQuery(search: s).matches(r)).toList();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Search model, page, error, text…',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: (v) => setState(() => _search = v),
          ),
        ),
        Expanded(
          child: list.isEmpty
              ? const Center(child: Text('No calls'))
              : ListView.separated(
                  itemCount: list.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final r = list[i];
                    return ListTile(
                      dense: true,
                      leading: Icon(
                        r.status == AICallStatus.success
                            ? Icons.check_circle_outline
                            : Icons.error_outline,
                        color: r.status == AICallStatus.success
                            ? Colors.green
                            : Theme.of(context).colorScheme.error,
                      ),
                      title: Text(
                        '${r.provider} · ${r.model}',
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '${AIFormat.time(r.timestamp)}${r.context.isEmpty ? '' : ' · ${r.context}'}\n'
                        'in ${AIFormat.tokens(r.usage.inputTokens + r.usage.cachedInputTokens)} · out ${AIFormat.tokens(r.usage.outputTokens)}'
                        '${r.latencyMs != null ? ' · ${AIFormat.ms(r.latencyMs!)}' : ''}${r.usage.estimated ? ' · est.' : ''}',
                        maxLines: 2,
                      ),
                      isThreeLine: true,
                      trailing: Text(
                        AIFormat.money(r.cost.total, r.cost.currency),
                      ),
                      onTap: () => _detail(r),
                    );
                  },
                ),
        ),
      ],
    );
  }

  void _detail(AIUsageRecord r) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (c) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: .7,
        maxChildSize: .95,
        builder: (c, scroll) => ListView(
          controller: scroll,
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              '${r.provider} · ${r.model}',
              style: Theme.of(c).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            for (final e in {
              'Time': AIFormat.time(r.timestamp),
              'Status':
                  '${r.status.name}${r.httpStatus != null ? ' (${r.httpStatus})' : ''}',
              if (r.errorMessage != null) 'Error': r.errorMessage!,
              'Operation': r.operation,
              'Where': r.context.isEmpty ? '—' : r.context.toString(),
              'Input tokens': '${r.usage.inputTokens}',
              'Cached input': '${r.usage.cachedInputTokens}',
              'Cache write': '${r.usage.cacheWriteTokens}',
              'Output tokens': '${r.usage.outputTokens}',
              'Reasoning': '${r.usage.reasoningTokens}',
              'Estimated': '${r.usage.estimated}',
              'Cost':
                  '${AIFormat.money(r.cost.total, r.cost.currency)}${r.cost.priced ? '' : ' (no price set)'}',
              'Latency': r.latencyMs == null ? '—' : AIFormat.ms(r.latencyMs!),
              if (r.timeToFirstTokenMs != null)
                'First token': AIFormat.ms(r.timeToFirstTokenMs!),
              'Streamed': '${r.streamed}',
              if (r.finishReason != null) 'Finish reason': r.finishReason!,
              if (r.endpoint != null) 'Endpoint': r.endpoint!,
              'Captured by': r.source.name,
              if (r.parameters.isNotEmpty)
                'Parameters': r.parameters.toString(),
              if (r.context.tags.isNotEmpty) 'Tags': r.context.tags.join(', '),
              if (r.context.custom.isNotEmpty || r.customData.isNotEmpty)
                'Custom': {...r.context.custom, ...r.customData}.toString(),
            }.entries)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 120,
                      child: Text(
                        e.key,
                        style: Theme.of(c).textTheme.labelMedium,
                      ),
                    ),
                    Expanded(child: SelectableText(e.value)),
                  ],
                ),
              ),
            if (r.prompt != null) ...[
              const Divider(),
              Text('Prompt', style: Theme.of(c).textTheme.titleSmall),
              SelectableText(r.prompt!),
            ],
            if (r.response != null) ...[
              const Divider(),
              Text('Response', style: Theme.of(c).textTheme.titleSmall),
              SelectableText(r.response!),
            ],
            if (r.prompt == null && r.response == null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  'Prompt text is not stored (promptStorage: metadataOnly).',
                  style: Theme.of(c).textTheme.bodySmall,
                ),
              ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () async {
                await _t.deleteRecord(r.id);
                if (c.mounted) Navigator.pop(c);
                _load();
              },
              icon: const Icon(Icons.delete_outline),
              label: const Text('Delete this record'),
            ),
          ],
        ),
      ),
    );
  }
}
