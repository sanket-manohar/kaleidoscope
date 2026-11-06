import 'dart:async';
import 'dart:convert';
import 'dart:math';

import '../config/redaction.dart';
import '../debug/ai_debug_logger.dart';
import '../models/ai_usage_record.dart';
import '../storage/usage_store.dart';

/// A destination for usage records (your backend, analytics, tracing...).
///
/// Implement [send]; throw to signal failure and the batch is retried later
/// with exponential backoff. Queued records survive app restarts.
abstract class AIUsageSink {
  const AIUsageSink();

  /// Unique, stable name (used to persist the offline queue).
  String get name;

  int get batchSize => 50;
  Duration get flushInterval => const Duration(seconds: 30);

  /// Max queued records kept while offline (oldest dropped first).
  int get maxQueueSize => 5000;

  /// Send prompt/response text too. Off by default: data leaving the device
  /// carries metadata only.
  bool get includeText => false;

  /// Run the PII redactors over any text that is sent.
  bool get scrubPii => true;

  /// Filter which records this sink receives.
  bool accepts(AIUsageRecord record) => true;

  Future<void> send(List<AIUsageRecord> batch);
}

/// Batching, persistence and retry for one sink. Internal.
class SinkDispatcher {
  SinkDispatcher(this.sink, {required this.onError, required this.logger}) {
    _timer = Timer.periodic(sink.flushInterval, (_) => flush());
  }

  final AIUsageSink sink;
  final void Function(Object, StackTrace) onError;
  final AIDebugLogger logger;
  final _queue = <AIUsageRecord>[];
  UsageStore? _store;
  Timer? _timer;
  Timer? _persistTimer;
  bool _sending = false;
  int _failures = 0;
  DateTime? _retryAt;
  Completer<void>? _inflight;

  String get _key => 'sink_queue.${sink.name}';

  Future<void> attach(UsageStore store) async {
    _store = store;
    try {
      final saved = await store.readValue(_key);
      if (saved != null && saved.isNotEmpty) {
        final list = (jsonDecode(saved) as List).map(
          (e) => AIUsageRecord.fromJson((e as Map).cast<String, Object?>()),
        );
        _queue.insertAll(0, list);
        _trim();
      }
    } catch (e, st) {
      onError(e, st);
    }
  }

  void add(AIUsageRecord r) {
    try {
      if (!sink.accepts(r)) return;
      var out = sink.includeText ? r : r.copyWith(clearText: true);
      if (sink.includeText && sink.scrubPii) {
        out = out.copyWith(
          prompt: out.prompt == null
              ? null
              : Redactors.applyAll(out.prompt!, Redactors.defaults),
          response: out.response == null
              ? null
              : Redactors.applyAll(out.response!, Redactors.defaults),
        );
      }
      _queue.add(out);
      _trim();
      _schedulePersist();
      if (_queue.length >= sink.batchSize) unawaited(flush());
    } catch (e, st) {
      onError(e, st);
    }
  }

  void _trim() {
    final over = _queue.length - sink.maxQueueSize;
    if (over > 0) _queue.removeRange(0, over);
  }

  void _schedulePersist() {
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(seconds: 2), _persist);
  }

  Future<void> _persist() async {
    try {
      await _store?.writeValue(
        _key,
        jsonEncode(_queue.map((e) => e.toJson()).toList()),
      );
    } catch (e, st) {
      onError(e, st);
    }
  }

  /// Sends queued records now (respecting the retry backoff unless [force]).
  Future<void> flush({bool force = false}) async {
    if (_sending) return _inflight?.future;
    if (_queue.isEmpty) return;
    if (!force && _retryAt != null && DateTime.now().isBefore(_retryAt!)) {
      return;
    }
    _sending = true;
    _inflight = Completer<void>();
    try {
      while (_queue.isNotEmpty) {
        final batch = _queue.take(sink.batchSize).toList();
        await sink.send(batch).timeout(const Duration(seconds: 30));
        _queue.removeRange(0, batch.length.clamp(0, _queue.length));
        _failures = 0;
        _retryAt = null;
      }
    } catch (e) {
      _failures++;
      final secs = min(900, 5 * pow(2, min(_failures, 8)).toInt());
      _retryAt = DateTime.now().add(Duration(seconds: secs));
      logger.internal('sink "${sink.name}" failed, retrying in ${secs}s', e);
    } finally {
      _sending = false;
      await _persist();
      _inflight?.complete();
    }
  }

  int get queued => _queue.length;

  void dispose() {
    _timer?.cancel();
    _persistTimer?.cancel();
    unawaited(_persist());
  }
}
