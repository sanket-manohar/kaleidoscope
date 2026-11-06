import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/kaleidoscope_tracker.dart';
import '../models/ai_usage_record.dart';
import 'ai_analytics_screen.dart';
import 'format.dart';

/// Floating, draggable bubble that shows live AI cost, tokens and speed for
/// this session. Renders only [child] in profile/release builds.
///
/// ```dart
/// MaterialApp(
///   navigatorKey: navKey,
///   builder: (context, child) => AIUsageDebugOverlay(navigatorKey: navKey, child: child!),
/// )
/// ```
class AIUsageDebugOverlay extends StatefulWidget {
  const AIUsageDebugOverlay({
    super.key,
    required this.child,
    this.tracker,
    this.navigatorKey,
    this.enabled = kDebugMode,
    this.initialOffset = const Offset(12, 120),
  });

  final Widget child;
  final KaleidoscopeTracker? tracker;

  /// Needed to open the full dashboard from the bubble.
  final GlobalKey<NavigatorState>? navigatorKey;

  /// Defaults to `kDebugMode`, so it is never shown in release.
  final bool enabled;
  final Offset initialOffset;

  @override
  State<AIUsageDebugOverlay> createState() => _AIUsageDebugOverlayState();
}

class _AIUsageDebugOverlayState extends State<AIUsageDebugOverlay> {
  StreamSubscription<AIUsageRecord>? _sub;
  late Offset _pos = widget.initialOffset;
  bool _expanded = false;
  int _calls = 0, _errors = 0, _tokens = 0;
  double _cost = 0;
  String _currency = 'USD';
  final _recent = <AIUsageRecord>[];
  bool _flash = false;

  KaleidoscopeTracker get _t => widget.tracker ?? KaleidoscopeTracker.instance;

  @override
  void initState() {
    super.initState();
    if (widget.enabled) _sub = _t.onRecord.listen(_onRecord);
  }

  void _onRecord(AIUsageRecord r) {
    if (!mounted) return;
    setState(() {
      _calls++;
      if (r.isError) _errors++;
      _tokens += r.usage.totalTokens;
      _cost += r.cost.total;
      if (r.cost.priced) _currency = r.cost.currency;
      _recent.insert(0, r);
      if (_recent.length > 8) _recent.removeLast();
      _flash = true;
    });
    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted) setState(() => _flash = false);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _openDashboard() {
    final nav = widget.navigatorKey?.currentState;
    nav?.push(
      MaterialPageRoute(
        builder: (_) => AIAnalyticsScreen(tracker: widget.tracker),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    final size = MediaQuery.maybeSizeOf(context) ?? const Size(400, 800);
    final last = _recent.isEmpty ? null : _recent.first;
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Stack(
        children: [
          widget.child,
          Positioned(
            left: _pos.dx.clamp(
              0,
              (size.width - (_expanded ? 304 : 204)).clamp(0, double.infinity),
            ),
            top: _pos.dy.clamp(0, size.height - 60),
            child: GestureDetector(
              onPanUpdate: (d) => setState(() => _pos += d.delta),
              onTap: () => setState(() => _expanded = !_expanded),
              onLongPress: _openDashboard,
              child: Material(
                color: Colors.transparent,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  constraints: BoxConstraints(maxWidth: _expanded ? 300 : 200),
                  decoration: BoxDecoration(
                    color: (_flash
                        ? const Color(0xFF4F46E5)
                        : const Color(0xE6111827)),
                    borderRadius: BorderRadius.circular(14),
                    boxShadow: const [
                      BoxShadow(blurRadius: 8, color: Color(0x33000000)),
                    ],
                  ),
                  child: DefaultTextStyle(
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontFamily: 'monospace',
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'AI ${AIFormat.money(_cost, _currency)} · $_calls calls${_errors > 0 ? ' · $_errors ✖' : ''}',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        Text(
                          '${AIFormat.tokens(_tokens)} tok'
                          '${last?.latencyMs != null ? ' · last ${AIFormat.ms(last!.latencyMs!)}' : ''}',
                        ),
                        if (_expanded) ...[
                          const SizedBox(height: 6),
                          for (final r in _recent)
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Text(
                                '${r.isError ? '✖' : '✔'} ${r.model} ${r.usage.inputTokens}/${r.usage.outputTokens}'
                                ' ${AIFormat.money(r.cost.total, r.cost.currency)}'
                                '${r.latencyMs != null ? ' ${AIFormat.ms(r.latencyMs!)}' : ''}'
                                '${r.context.isEmpty ? '' : '\n   @ ${r.context}'}',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          const SizedBox(height: 4),
                          Text(
                            widget.navigatorKey != null
                                ? 'Long-press for dashboard · drag to move'
                                : 'Drag to move',
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 10,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
