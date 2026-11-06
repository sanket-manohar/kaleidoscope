import 'dart:convert';

import '../analytics/analytics_models.dart';
import '../models/ai_usage_record.dart';

/// Turns records and reports into JSON, CSV or a self-contained HTML page.
abstract final class AIUsageExporter {
  static String toJson(List<AIUsageRecord> records, {bool pretty = true}) {
    final data = records.map((r) => r.toJson()).toList();
    return pretty
        ? const JsonEncoder.withIndent('  ').convert(data)
        : jsonEncode(data);
  }

  static const csvColumns = [
    'id',
    'timestamp',
    'provider',
    'model',
    'operation',
    'module',
    'page',
    'section',
    'feature',
    'input_tokens',
    'cached_input_tokens',
    'cache_write_tokens',
    'output_tokens',
    'reasoning_tokens',
    'total_tokens',
    'estimated',
    'cost',
    'currency',
    'latency_ms',
    'ttft_ms',
    'status',
    'http_status',
    'error',
    'streamed',
    'finish_reason',
    'tags',
  ];

  static String toCsv(List<AIUsageRecord> records) {
    String esc(Object? v) {
      final s = v?.toString() ?? '';
      return s.contains(RegExp('[",\n\r]'))
          ? '"${s.replaceAll('"', '""')}"'
          : s;
    }

    final b = StringBuffer()..writeln(csvColumns.join(','));
    for (final r in records) {
      b.writeln(
        [
          r.id,
          r.timestamp.toUtc().toIso8601String(),
          r.provider,
          r.model,
          r.operation,
          r.context.module,
          r.context.page,
          r.context.section,
          r.context.feature,
          r.usage.inputTokens,
          r.usage.cachedInputTokens,
          r.usage.cacheWriteTokens,
          r.usage.outputTokens,
          r.usage.reasoningTokens,
          r.usage.totalTokens,
          r.usage.estimated,
          r.cost.total.toStringAsFixed(8),
          r.cost.currency,
          r.latencyMs,
          r.timeToFirstTokenMs,
          r.status.name,
          r.httpStatus,
          r.errorMessage,
          r.streamed,
          r.finishReason,
          r.context.tags.join('|'),
        ].map(esc).join(','),
      );
    }
    return b.toString();
  }

  static String _e(Object? s) =>
      const HtmlEscape().convert(s?.toString() ?? '');

  /// A single shareable HTML file with charts (inline SVG, no scripts).
  static String toHtml(
    AIUsageReport r, {
    String title = 'AI usage report',
    String? appName,
  }) {
    final t = r.totals;
    String money(double v) =>
        '${t.currency == 'USD' ? r'$' : '${t.currency} '}${v.toStringAsFixed(v < 1 ? 4 : 2)}';
    String n(num v) => v >= 1e6
        ? '${(v / 1e6).toStringAsFixed(2)}M'
        : v >= 1e3
        ? '${(v / 1e3).toStringAsFixed(1)}k'
        : v.toStringAsFixed(v is int ? 0 : 1);

    String bars(List<BreakdownItem> items, {bool byCost = true}) {
      if (items.isEmpty) return '<p class="muted">No data</p>';
      final top = items.take(10).toList();
      final maxV = top
          .map((e) => byCost ? e.totals.cost : e.totals.totalTokens.toDouble())
          .fold<double>(0, (a, b) => b > a ? b : a);
      final rows = StringBuffer();
      for (final i in top) {
        final v = byCost ? i.totals.cost : i.totals.totalTokens.toDouble();
        final w = maxV == 0 ? 0 : (v / maxV * 100);
        rows.write(
          '<tr><td>${_e(i.key)}</td><td class="bar"><div style="width:${w.toStringAsFixed(1)}%"></div></td>'
          '<td class="num">${money(i.totals.cost)}</td><td class="num">${n(i.totals.totalTokens)}</td>'
          '<td class="num">${i.totals.calls}</td><td class="num">${(i.totals.errorRate * 100).toStringAsFixed(1)}%</td></tr>',
        );
      }
      return '<table><tr><th>Name</th><th></th><th>Cost</th><th>Tokens</th><th>Calls</th><th>Errors</th></tr>$rows</table>';
    }

    String line(List<TimePoint> pts, UsageForecast? fc) {
      if (pts.isEmpty) return '<p class="muted">No data</p>';
      final vals = pts.map((p) => p.totals.cost).toList();
      final fv = fc?.points.map((p) => p.value).toList() ?? const <double>[];
      final all = [...vals, ...fv];
      final maxV = all.fold<double>(0, (a, b) => b > a ? b : a);
      const w = 720.0, h = 180.0;
      final count = vals.length + fv.length;
      double x(int i) => count <= 1 ? 0 : i / (count - 1) * w;
      double y(double v) => maxV == 0 ? h : h - v / maxV * (h - 10);
      final hist = [
        for (var i = 0; i < vals.length; i++)
          '${x(i).toStringAsFixed(1)},${y(vals[i]).toStringAsFixed(1)}',
      ].join(' ');
      final fut = [
        if (vals.isNotEmpty)
          '${x(vals.length - 1).toStringAsFixed(1)},${y(vals.last).toStringAsFixed(1)}',
        for (var i = 0; i < fv.length; i++)
          '${x(vals.length + i).toStringAsFixed(1)},${y(fv[i]).toStringAsFixed(1)}',
      ].join(' ');
      return '<svg viewBox="0 0 $w ${h + 4}" preserveAspectRatio="none" class="chart">'
          '<polyline fill="none" stroke="var(--accent)" stroke-width="2" points="$hist"/>'
          '${fv.isEmpty ? '' : '<polyline fill="none" stroke="var(--accent2)" stroke-width="2" stroke-dasharray="6 4" points="$fut"/>'}'
          '</svg><p class="muted">Solid: daily cost. Dashed: ${fc?.method ?? ''} forecast (${fc?.trend ?? ''}).</p>';
    }

    String tree(List<UsageTreeNode> nodes, [int depth = 0]) {
      if (nodes.isEmpty) return '';
      final b = StringBuffer('<ul>');
      for (final node in nodes) {
        b.write(
          '<li><b>${_e(node.name)}</b> <span class="muted">${money(node.totals.cost)} · ${n(node.totals.totalTokens)} tokens · ${node.totals.calls} calls</span>',
        );
        b.write(tree(node.children, depth + 1));
        b.write('</li>');
      }
      return '$b</ul>';
    }

    String heat() {
      final maxV = r.heatmap
          .expand((e) => e)
          .fold<int>(0, (a, b) => b > a ? b : a);
      const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
      final b = StringBuffer('<table class="heat"><tr><th></th>');
      for (var hr = 0; hr < 24; hr++) {
        b.write('<th>${hr % 3 == 0 ? hr : ''}</th>');
      }
      b.write('</tr>');
      for (var d = 0; d < 7; d++) {
        b.write('<tr><th>${days[d]}</th>');
        for (var hr = 0; hr < 24; hr++) {
          final v = r.heatmap[d][hr];
          final a = maxV == 0 ? 0 : v / maxV;
          b.write(
            '<td title="$v calls" style="background:rgba(99,102,241,${(0.08 + a * 0.92).toStringAsFixed(2)})"></td>',
          );
        }
        b.write('</tr>');
      }
      return '$b</table>';
    }

    final l = r.latency;
    final insights = r.insights.isEmpty
        ? '<p class="muted">Nothing unusual.</p>'
        : '<ul>${r.insights.map((i) => '<li class="${i.level.name}"><b>${_e(i.title)}</b><br>${_e(i.detail)}</li>').join()}</ul>';
    final range =
        '${r.from?.toIso8601String().substring(0, 10) ?? 'all time'} → ${(r.to ?? r.generatedAt).toIso8601String().substring(0, 10)}';

    return '''<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${_e(title)}</title><style>
:root{--bg:#fff;--fg:#111827;--muted:#6b7280;--card:#f9fafb;--line:#e5e7eb;--accent:#6366f1;--accent2:#f59e0b}
@media (prefers-color-scheme:dark){:root{--bg:#0b0f17;--fg:#e5e7eb;--muted:#9ca3af;--card:#111827;--line:#1f2937}}
body{font:14px/1.5 system-ui,-apple-system,Segoe UI,Roboto,sans-serif;background:var(--bg);color:var(--fg);margin:0;padding:16px;max-width:980px;margin:auto}
h1{font-size:22px;margin:8px 0}h2{font-size:16px;margin:24px 0 8px}.muted{color:var(--muted)}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:10px}
.card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:12px}.card b{display:block;font-size:20px}
table{width:100%;border-collapse:collapse}td,th{padding:6px;border-bottom:1px solid var(--line);text-align:left;font-size:13px}
.num{text-align:right;white-space:nowrap}.bar{width:35%}.bar div{height:10px;background:var(--accent);border-radius:4px}
.chart{width:100%;height:190px;background:var(--card);border-radius:10px}.heat td{height:14px;padding:0;border:1px solid var(--bg)}.heat th{font-size:10px;padding:0 2px}
li.warning b{color:#d97706}li.critical b{color:#dc2626}ul{padding-left:18px}section{overflow-x:auto}
</style></head><body>
<h1>${_e(title)}</h1><p class="muted">${_e(appName ?? '')} $range · generated ${r.generatedAt.toIso8601String().substring(0, 16)}</p>
<div class="grid">
<div class="card">Cost<b>${money(t.cost)}</b></div>
<div class="card">Calls<b>${t.calls}</b><span class="muted">${(t.errorRate * 100).toStringAsFixed(1)}% errors</span></div>
<div class="card">Input tokens<b>${n(t.inputTokens + t.cachedInputTokens)}</b><span class="muted">${(t.cacheHitRate * 100).toStringAsFixed(0)}% cached</span></div>
<div class="card">Output tokens<b>${n(t.outputTokens)}</b></div>
<div class="card">Latency p50 / p99<b>${n(l.p50)} / ${n(l.p99)} ms</b></div>
<div class="card">Forecast ${r.costForecast.points.length}d<b>${money(r.costForecast.total)}</b><span class="muted">${r.costForecast.trend}</span></div>
${r.budget == null ? '' : '<div class="card">Budget<b>${(r.budget!.percentUsed * 100).toStringAsFixed(0)}%</b><span class="muted">projected ${money(r.budget!.projected)}</span></div>'}
</div>
<h2>Insights</h2>$insights
<h2>Daily cost and forecast</h2><section>${line(r.daily, r.costForecast)}</section>
<h2>By model</h2><section>${bars(r.byModel)}</section>
<h2>By provider</h2><section>${bars(r.byProvider)}</section>
<h2>By module › page › section</h2><section>${tree(r.tree)}</section>
<h2>By page</h2><section>${bars(r.byPage)}</section>
<h2>By section</h2><section>${bars(r.bySection)}</section>
<h2>Latency</h2><table><tr><th>p50</th><th>p90</th><th>p95</th><th>p99</th><th>TTFT p50</th><th>TTFT p90</th><th>tokens/s</th></tr>
<tr><td>${n(l.p50)} ms</td><td>${n(l.p90)} ms</td><td>${n(l.p95)} ms</td><td>${n(l.p99)} ms</td><td>${n(l.ttftP50)} ms</td><td>${n(l.ttftP90)} ms</td><td>${l.avgOutputTokensPerSecond.toStringAsFixed(1)}</td></tr></table>
<h2>Activity (weekday × hour)</h2><section>${heat()}</section>
<h2>Recent errors</h2>${r.recentErrors.isEmpty ? '<p class="muted">None</p>' : '<table><tr><th>Time</th><th>Model</th><th>Where</th><th>Error</th></tr>${r.recentErrors.map((e) => '<tr><td>${_e(e['time'].toString().substring(0, 16))}</td><td>${_e(e['model'])}</td><td>${_e(e['where'])}</td><td>${_e(e['error'])}</td></tr>').join()}</table>'}
<p class="muted">Generated by kaleidoscope. Contains usage metadata only.</p>
</body></html>''';
  }
}
