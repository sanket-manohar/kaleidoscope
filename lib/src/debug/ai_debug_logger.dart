import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

import '../config/redaction.dart';
import '../config/tracker_config.dart';
import '../models/ai_usage_record.dart';

/// Pretty, colour-coded console lines for each AI call. Prints only in
/// debug builds unless configured otherwise.
class AIDebugLogger {
  AIDebugLogger(this.config, {this.redactors = Redactors.defaults});

  AIDebugLogConfig config;
  List<Redactor> redactors;

  static const _reset = '\x1B[0m';
  static const _dim = '\x1B[2m';
  static const _green = '\x1B[32m';
  static const _red = '\x1B[31m';
  static const _yellow = '\x1B[33m';
  static const _cyan = '\x1B[36m';
  static const _magenta = '\x1B[35m';

  bool get _active =>
      config.level != AIDebugLogLevel.off &&
      (!config.onlyInDebugMode || kDebugMode);

  String _c(String color, String s) => config.useColors ? '$color$s$_reset' : s;

  void record(AIUsageRecord r) {
    if (!_active) return;
    if (config.level == AIDebugLogLevel.errors && !r.isError) return;
    try {
      final u = r.usage;
      final ok = r.status == AICallStatus.success;
      final icon = ok ? _c(_green, '✔') : _c(_red, '✖');
      final where = r.context.toString();
      final cost = r.cost.priced
          ? '${r.cost.currency == 'USD' ? r'$' : '${r.cost.currency} '}${r.cost.total.toStringAsFixed(r.cost.total < 0.01 ? 6 : 4)}'
          : 'unpriced';
      final b = StringBuffer()
        ..write('$icon ${_c(_cyan, '[AI]')} ')
        ..write(_c(_magenta, '${r.provider}/${r.model}'))
        ..write(' ${r.operation}${r.streamed ? ' (stream)' : ''}')
        ..write(where.isEmpty ? '' : ' ${_c(_dim, '@ $where')}')
        ..write(' • in ${u.inputTokens}')
        ..write(
          u.cachedInputTokens > 0 ? ' (+${u.cachedInputTokens} cached)' : '',
        )
        ..write(' / out ${u.outputTokens}')
        ..write(
          u.reasoningTokens > 0 ? ' (${u.reasoningTokens} reasoning)' : '',
        )
        ..write(u.estimated ? _c(_yellow, ' ~est') : '')
        ..write(' • ${_c(_yellow, cost)}')
        ..write(r.latencyMs != null ? ' • ${r.latencyMs}ms' : '')
        ..write(
          r.timeToFirstTokenMs != null
              ? ' (ttft ${r.timeToFirstTokenMs}ms)'
              : '',
        );
      if (!ok) {
        b.write(
          _c(
            _red,
            ' • ${r.status.name}${r.httpStatus != null ? ' ${r.httpStatus}' : ''}: ${r.errorMessage ?? ''}',
          ),
        );
      }
      _emit(b.toString(), isError: !ok);

      if (config.level == AIDebugLogLevel.verbose) {
        if (r.parameters.isNotEmpty) {
          _emit(_c(_dim, '   params: ${r.parameters}'));
        }
        if (r.context.custom.isNotEmpty || r.customData.isNotEmpty) {
          _emit(
            _c(_dim, '   custom: ${{...r.context.custom, ...r.customData}}'),
          );
        }
        if (config.showPromptText) {
          if (r.prompt != null) {
            _emit(_c(_dim, '   prompt: ${_short(r.prompt!)}'));
          }
          if (r.response != null) {
            _emit(_c(_dim, '   answer: ${_short(r.response!)}'));
          }
        }
      }
    } catch (_) {}
  }

  /// Logs tracker-internal problems (never thrown to the app).
  void internal(String message, [Object? error]) {
    if (!_active) return;
    _emit(
      _c(
        _yellow,
        '⚠ [kaleidoscope] $message${error != null ? ': $error' : ''}',
      ),
      isError: true,
    );
  }

  void info(String message) {
    if (!_active || config.level.index < AIDebugLogLevel.summary.index) return;
    _emit(_c(_dim, 'ℹ [kaleidoscope] $message'));
  }

  String _short(String s) {
    final clean = Redactors.applyAll(s, redactors).replaceAll('\n', ' ⏎ ');
    return clean.length > 300 ? '${clean.substring(0, 300)}…' : clean;
  }

  void _emit(String line, {bool isError = false}) {
    debugPrint(line);
    developer.log(
      line.replaceAll(RegExp(r'\x1B\[[0-9;]*m'), ''),
      name: 'Kaleidoscope',
      level: isError ? 1000 : 800,
    );
  }
}
