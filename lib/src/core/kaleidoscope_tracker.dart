import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart' show Interceptor;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../analytics/ai_usage_analytics.dart';
import '../capture/adapters/anthropic_adapter.dart';
import '../capture/adapters/cohere_adapter.dart';
import '../capture/adapters/gemini_adapter.dart';
import '../capture/adapters/generic_adapter.dart';
import '../capture/adapters/ollama_adapter.dart';
import '../capture/adapters/openai_compatible_adapter.dart';
import '../capture/ai_dio_interceptor.dart';
import '../capture/ai_http_client.dart';
import '../capture/http_capture.dart';
import '../capture/provider_adapter.dart';
import '../capture/token_estimator.dart';
import '../config/redaction.dart';
import '../config/tracker_config.dart';
import '../debug/ai_debug_logger.dart';
import '../models/ai_usage_context.dart';
import '../models/ai_usage_record.dart';
import '../pricing/pricing_table.dart';
import '../sinks/ai_usage_sink.dart';
import '../storage/secure_sqlite_store.dart';
import '../storage/usage_store.dart';
import 'usage_draft.dart';

/// Pre-call estimate of tokens and cost.
class AICostEstimate {
  const AICostEstimate({
    required this.model,
    required this.inputTokens,
    required this.outputTokens,
    required this.cost,
  });
  final String model;
  final int inputTokens;
  final int outputTokens;
  final AICost cost;
  int get totalTokens => inputTokens + outputTokens;
  @override
  String toString() =>
      '$model: ~$inputTokens in / ~$outputTokens out ≈ ${cost.priced ? '${cost.total.toStringAsFixed(6)} ${cost.currency}' : 'unpriced'}';
}

/// Handle for a call you report manually: `final h = tracker.begin(...);`
/// then `h.complete(...)` or `h.fail(error)`.
class AICallHandle {
  AICallHandle._(this._tracker, this._draft);
  final KaleidoscopeTracker _tracker;
  final AIUsageDraft _draft;
  final _sw = Stopwatch()..start();
  bool _done = false;

  /// Call when the first streamed token arrives (for time-to-first-token).
  void markFirstToken() =>
      _draft.timeToFirstTokenMs ??= _sw.elapsedMilliseconds;

  void complete({
    AITokenUsage? usage,
    int? inputTokens,
    int? outputTokens,
    String? responseText,
    String? model,
    String? finishReason,
    Map<String, Object?>? customData,
  }) {
    if (_done) return;
    _done = true;
    _draft
      ..latencyMs = _sw.elapsedMilliseconds
      ..usage =
          usage ??
          ((inputTokens != null || outputTokens != null)
              ? AITokenUsage(
                  inputTokens: inputTokens ?? 0,
                  outputTokens: outputTokens ?? 0,
                )
              : null)
      ..response = responseText
      ..model = model ?? _draft.model
      ..finishReason = finishReason;
    if (customData != null) {
      _draft.customData = {..._draft.customData, ...customData};
    }
    _tracker.submit(_draft);
  }

  void fail(Object error, {AICallStatus status = AICallStatus.error}) {
    if (_done) return;
    _done = true;
    _draft
      ..latencyMs = _sw.elapsedMilliseconds
      ..status = status
      ..errorMessage = error.toString();
    _tracker.submit(_draft);
  }
}

/// The tracker. Most apps use the [Kaleidoscope] shortcuts instead of this
/// class directly.
///
/// Fail-safe by design: every internal error is caught and reported to
/// `onError` / the debug console. Your AI calls always run and return
/// exactly what they would without the tracker.
class KaleidoscopeTracker implements AICaptureHost {
  KaleidoscopeTracker();

  static final KaleidoscopeTracker instance = KaleidoscopeTracker();

  KaleidoscopeConfig _config = const KaleidoscopeConfig();
  KaleidoscopeConfig get config => _config;

  late PricingTable _pricing = PricingTable.withDefaults();
  PricingTable get pricing => _pricing;

  UsageStore? _store;
  UsageStore? get store => _store;

  late final AIDebugLogger _logger = AIDebugLogger(_config.debugLog);
  AIDebugLogger get logger => _logger;

  late final AIUsageAnalytics analytics = AIUsageAnalytics(this);

  final _adapters = <AIProviderAdapter>[
    const AnthropicAdapter(),
    const GeminiAdapter(),
    const OllamaAdapter(),
    const CohereAdapter(),
    const OpenAICompatibleAdapter(),
  ];

  final _pending = <AIUsageRecord>[];
  final _controller = StreamController<AIUsageRecord>.broadcast();
  final _sinks = <SinkDispatcher>[];
  final ValueNotifier<int> revision = ValueNotifier(0);
  Future<void> _writeChain = Future.value();
  Timer? _retentionTimer;
  Timer? _pricingTimer;
  bool _ready = false;
  Future<void>? _initFuture;

  /// True once storage is open.
  bool get isReady => _ready;

  /// Live stream of every saved record (used by the debug overlay).
  Stream<AIUsageRecord> get onRecord => _controller.stream;

  /// Initialise once, early in `main()`. Safe to call more than once.
  Future<void> initialize([
    KaleidoscopeConfig config = const KaleidoscopeConfig(),
  ]) {
    return _initFuture ??= _init(config);
  }

  Future<void> _init(KaleidoscopeConfig config) async {
    _config = config;
    _logger
      ..config = config.debugLog
      ..redactors = config.redactors;
    if (config.pricing != null) _pricing = config.pricing!;
    try {
      final store =
          config.store ??
          SecureSqliteUsageStore(databaseName: config.databaseName);
      await store.open();
      _store = store;
      await _restorePricing();
      _ready = true;
      for (final s in _sinks) {
        s.attach(store);
      }
      final pending = List.of(_pending);
      _pending.clear();
      for (final r in pending) {
        _enqueueWrite(r);
      }
      unawaited(runRetention());
      _retentionTimer = Timer.periodic(
        config.retention.cleanupInterval,
        (_) => runRetention(),
      );
      if (config.remotePricingUrl != null) {
        unawaited(refreshRemotePricing());
        _pricingTimer = Timer.periodic(
          config.pricingRefreshInterval,
          (_) => refreshRemotePricing(),
        );
      }
      _logger.info(
        'ready (${store.runtimeType}, prompts: ${config.promptStorage.name})',
      );
    } catch (e, st) {
      // Fall back to memory so the app keeps working and analytics still show
      // this session's data.
      reportInternalError(e, st);
      _store = InMemoryUsageStore();
      _ready = true;
      for (final r in _pending) {
        await _store!.insert(r);
      }
      _pending.clear();
      _logger.internal('secure storage unavailable, using memory only', e);
    }
  }

  // ---------------------------------------------------------------- capture

  /// An `http.Client` that tracks AI calls. Pass your own [inner] client to
  /// keep its configuration.
  http.Client httpClient([http.Client? inner]) =>
      AITrackingHttpClient(this, inner: inner);

  /// A Dio interceptor that tracks AI calls.
  Interceptor dioInterceptor() => AITrackingDioInterceptor(this);

  /// Wrap any SDK call (any provider, any package):
  ///
  /// ```dart
  /// final res = await tracker.track(
  ///   provider: 'gemini', model: 'gemini-2.5-flash',
  ///   prompt: question,
  ///   call: () => model.generateContent([Content.text(question)]),
  ///   usage: (r) => AITokenUsage(
  ///     inputTokens: r.usageMetadata?.promptTokenCount ?? 0,
  ///     outputTokens: r.usageMetadata?.candidatesTokenCount ?? 0),
  ///   responseText: (r) => r.text,
  /// );
  /// ```
  /// Errors from [call] are recorded and rethrown unchanged.
  Future<T> track<T>({
    required String provider,
    required String model,
    required Future<T> Function() call,
    AITokenUsage? Function(T result)? usage,
    String? Function(T result)? responseText,
    String? prompt,
    String operation = 'chat',
    Map<String, Object?> parameters = const {},
    AIUsageContext? context,
    Map<String, Object?> customData = const {},
  }) async {
    final h = begin(
      provider: provider,
      model: model,
      prompt: prompt,
      operation: operation,
      parameters: parameters,
      context: context,
      customData: customData,
      source: AICaptureSource.wrapper,
    );
    final T result;
    try {
      result = await call();
    } catch (e) {
      h.fail(e);
      rethrow;
    }
    AITokenUsage? u;
    String? text;
    try {
      u = usage?.call(result);
      text = responseText?.call(result);
    } catch (e, st) {
      reportInternalError(e, st);
    }
    h.complete(usage: u, responseText: text);
    return result;
  }

  /// Wrap a streaming SDK call. [onChunk] reads each chunk: return the text
  /// delta and/or usage it carries (the last non-null usage wins).
  Stream<T> trackStream<T>({
    required String provider,
    required String model,
    required Stream<T> Function() call,
    ({String? text, AITokenUsage? usage})? Function(T chunk)? onChunk,
    String? prompt,
    String operation = 'chat',
    Map<String, Object?> parameters = const {},
    AIUsageContext? context,
    Map<String, Object?> customData = const {},
  }) {
    final h = begin(
      provider: provider,
      model: model,
      prompt: prompt,
      operation: operation,
      parameters: parameters,
      context: context,
      customData: customData,
      source: AICaptureSource.wrapper,
    );
    h._draft.streamed = true;
    final buf = StringBuffer();
    AITokenUsage? last;
    late final StreamController<T> c;
    StreamSubscription<T>? sub;
    c = StreamController<T>(
      onListen: () {
        Stream<T> src;
        try {
          src = call();
        } catch (e, st) {
          h.fail(e);
          c.addError(e, st);
          c.close();
          return;
        }
        sub = src.listen(
          (chunk) {
            h.markFirstToken();
            try {
              final info = onChunk?.call(chunk);
              if (info?.text != null) buf.write(info!.text);
              if (info?.usage != null) last = info!.usage;
            } catch (e, st) {
              reportInternalError(e, st);
            }
            c.add(chunk);
          },
          onError: (Object e, StackTrace st) {
            h.fail(e);
            c.addError(e, st);
          },
          onDone: () {
            h.complete(
              usage: last,
              responseText: buf.isEmpty ? null : buf.toString(),
            );
            c.close();
          },
        );
      },
      onPause: () => sub?.pause(),
      onResume: () => sub?.resume(),
      onCancel: () {
        h.complete(
          usage: last,
          responseText: buf.isEmpty ? null : buf.toString(),
        );
        return sub?.cancel();
      },
    );
    return c.stream;
  }

  /// Track an on-device model (Gemini Nano, TFLite, ML Kit, MediaPipe,
  /// llama.cpp...). Give token counts if the runtime reports them, or the
  /// texts and they will be estimated.
  Future<T> trackOnDevice<T>({
    required String model,
    required Future<T> Function() call,
    String runtime = 'on-device',
    String? inputText,
    String? Function(T result)? outputText,
    int? Function(T result)? inputTokens,
    int? Function(T result)? outputTokens,
    String operation = 'inference',
    AIUsageContext? context,
    Map<String, Object?> customData = const {},
  }) {
    return track<T>(
      provider: 'on-device',
      model: model,
      prompt: inputText,
      operation: operation,
      context: context,
      customData: {'runtime': runtime, ...customData},
      call: call,
      responseText: outputText,
      usage: (r) {
        final i = inputTokens?.call(r);
        final o = outputTokens?.call(r);
        if (i == null && o == null) return null;
        return AITokenUsage(inputTokens: i ?? 0, outputTokens: o ?? 0);
      },
    );
  }

  /// Start a manually reported call.
  AICallHandle begin({
    required String provider,
    required String model,
    String? prompt,
    String operation = 'chat',
    Map<String, Object?> parameters = const {},
    AIUsageContext? context,
    Map<String, Object?> customData = const {},
    AICaptureSource source = AICaptureSource.manual,
  }) {
    final d = newDraft(
      provider: provider,
      model: model,
      operation: operation,
      parameters: parameters,
      prompt: prompt,
      source: source,
    );
    d.context = d.context.merge(context);
    d.customData = customData;
    return AICallHandle._(this, d);
  }

  /// Record a finished call in one line (e.g. from a backend response).
  void record({
    required String provider,
    required String model,
    int inputTokens = 0,
    int outputTokens = 0,
    int cachedInputTokens = 0,
    int cacheWriteTokens = 0,
    int reasoningTokens = 0,
    AITokenUsage? usage,
    int? latencyMs,
    String? prompt,
    String? response,
    String operation = 'chat',
    AICallStatus status = AICallStatus.success,
    String? errorMessage,
    Map<String, Object?> parameters = const {},
    AIUsageContext? context,
    Map<String, Object?> customData = const {},
  }) {
    final d = newDraft(
      provider: provider,
      model: model,
      operation: operation,
      parameters: parameters,
      prompt: prompt,
      source: AICaptureSource.manual,
    );
    d
      ..context = d.context.merge(context)
      ..customData = customData
      ..usage =
          usage ??
          AITokenUsage(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cachedInputTokens: cachedInputTokens,
            cacheWriteTokens: cacheWriteTokens,
            reasoningTokens: reasoningTokens,
          )
      ..latencyMs = latencyMs
      ..response = response
      ..status = status
      ..errorMessage = errorMessage;
    submit(d);
  }

  /// Estimate tokens and cost before sending a call.
  AICostEstimate estimate({
    required String model,
    String? provider,
    String? prompt,
    int? inputTokens,
    int expectedOutputTokens = 500,
    int messages = 1,
  }) {
    final i =
        inputTokens ?? TokenEstimator.estimate(prompt, messages: messages);
    final usage = AITokenUsage(
      inputTokens: i,
      outputTokens: expectedOutputTokens,
      estimated: true,
    );
    return AICostEstimate(
      model: model,
      inputTokens: i,
      outputTokens: expectedOutputTokens,
      cost: _pricing.costFor(model, usage, provider: provider),
    );
  }

  /// Teach the HTTP interceptors a new API. Custom adapters are checked
  /// before the built-in ones.
  void registerAdapter(AIProviderAdapter adapter) =>
      _adapters.insert(0, adapter);

  // ---------------------------------------------------------------- context

  static final Object _zoneKey = Object();

  /// The context active in the current zone (set by [runWithContext]).
  static AIUsageContext get zoneContext =>
      (Zone.current[_zoneKey] as AIUsageContext?) ?? AIUsageContext.empty;

  /// Runs [body] so that every AI call inside it (including ones captured by
  /// the HTTP interceptors, and across `await`s) is tagged with [context].
  /// Nested calls merge, inner values win.
  static R runWithContext<R>(AIUsageContext context, R Function() body) =>
      runZoned(body, zoneValues: {_zoneKey: zoneContext.merge(context)});

  /// Context of the current screen. Set by [AIUsageNavigatorObserver]; you
  /// can also set it yourself.
  AIUsageContext currentScreen = AIUsageContext.empty;

  AIUsageContext _resolveContext() =>
      (_config.defaultContext ?? AIUsageContext.empty)
          .merge(currentScreen)
          .merge(zoneContext);

  // ---------------------------------------------------------------- host

  @override
  bool get injectStreamUsageOption => _config.injectStreamUsageOption;

  @override
  bool get captureParameters => _config.captureParameters;

  @override
  AIProviderAdapter? adapterFor(Uri uri) {
    if (!_config.enabled) return null;
    final host = uri.host.toLowerCase();
    if (_config.ignoredHosts.any((h) => host == h || host.endsWith('.$h'))) {
      return null;
    }
    for (final a in _adapters) {
      try {
        if (a.matches(uri)) return a;
      } catch (_) {}
    }
    if (_config.additionalHostsToTrack.any(
      (h) => host == h || host.endsWith('.$h'),
    )) {
      return const GenericAdapter();
    }
    return null;
  }

  @override
  AIUsageDraft newDraft({
    required String provider,
    String? model,
    String operation = 'chat',
    String? endpoint,
    Map<String, Object?> parameters = const {},
    String? prompt,
    AICaptureSource source = AICaptureSource.manual,
  }) => AIUsageDraft(
    provider: provider,
    model: model,
    operation: operation,
    endpoint: endpoint,
    parameters: parameters,
    prompt: prompt,
    source: source,
    context: _resolveContext(),
  );

  @override
  void submit(AIUsageDraft d) {
    if (!_config.enabled) return;
    try {
      final record = _build(d);
      if (record == null) return;
      _logger.record(record);
      if (!_controller.isClosed) _controller.add(record);
      for (final s in _sinks) {
        s.add(record);
      }
      if (_ready) {
        _enqueueWrite(record);
      } else {
        if (_pending.length >= 1000) _pending.removeAt(0);
        _pending.add(record);
      }
    } catch (e, st) {
      reportInternalError(e, st);
    }
  }

  @override
  void reportInternalError(Object error, StackTrace stack) {
    try {
      _logger.internal('internal error (your AI call was not affected)', error);
      _config.onError?.call(error, stack);
    } catch (_) {}
  }

  AIUsageRecord? _build(AIUsageDraft d) {
    var usage = d.usage;
    if (usage == null && _config.estimateMissingTokens) {
      final i = TokenEstimator.estimate(d.prompt);
      final o = TokenEstimator.estimate(d.response);
      if (i > 0 || o > 0) {
        usage = AITokenUsage(inputTokens: i, outputTokens: o, estimated: true);
      }
    }
    usage ??= AITokenUsage.zero;
    final model = (d.model == null || d.model!.isEmpty) ? 'unknown' : d.model!;
    final cost = _pricing.costFor(model, usage, provider: d.provider);
    var record = AIUsageRecord(
      id: _newId(),
      timestamp: d.startedAt,
      provider: d.provider,
      model: model,
      operation: d.operation,
      endpoint: d.endpoint,
      usage: usage,
      cost: cost,
      latencyMs: d.latencyMs,
      timeToFirstTokenMs: d.timeToFirstTokenMs,
      status: d.status,
      errorMessage: d.errorMessage == null
          ? null
          : Redactors.applyAll(d.errorMessage!, _config.redactors),
      httpStatus: d.httpStatus,
      streamed: d.streamed,
      finishReason: d.finishReason,
      responseId: d.responseId,
      parameters: d.parameters,
      context: d.context,
      customData: d.customData,
      prompt: _storeText(d.prompt),
      response: _storeText(d.response),
      source: d.source,
    );
    final hook = _config.beforeSave;
    if (hook != null) {
      final changed = hook(record);
      if (changed == null) return null;
      record = changed;
    }
    return record;
  }

  String? _storeText(String? text) {
    if (text == null || text.isEmpty) return null;
    switch (_config.promptStorage) {
      case PromptStorageMode.metadataOnly:
        return null;
      case PromptStorageMode.redacted:
        text = Redactors.applyAll(text, _config.redactors);
      case PromptStorageMode.full:
        break;
    }
    final max = _config.maxStoredTextLength;
    return text.length > max ? '${text.substring(0, max)}…' : text;
  }

  static final _rnd = Random.secure();
  static String _newId() {
    final t = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
    final r = List.generate(
      8,
      (_) => _rnd.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    return '$t-$r';
  }

  void _enqueueWrite(AIUsageRecord r) {
    _writeChain = _writeChain.then((_) async {
      try {
        await _store?.insert(r);
        revision.value++;
      } catch (e, st) {
        reportInternalError(e, st);
      }
    });
  }

  /// Waits until every captured record has been written.
  Future<void> flush() async {
    await _writeChain;
    for (final s in _sinks) {
      await s.flush();
    }
  }

  // ---------------------------------------------------------------- data

  Future<List<AIUsageRecord>> records([
    UsageQuery query = UsageQuery.all,
  ]) async {
    try {
      await _writeChain;
      final s = _store;
      if (s == null) return _pending.where(query.matches).toList();
      return await s.query(query);
    } catch (e, st) {
      reportInternalError(e, st);
      return const [];
    }
  }

  Future<void> deleteRecord(String id) async {
    try {
      await _store?.deleteRecord(id);
      revision.value++;
    } catch (e, st) {
      reportInternalError(e, st);
    }
  }

  /// Deletes every stored record.
  Future<void> clearAll() async {
    try {
      await _writeChain;
      await _store?.clear();
      _pending.clear();
      revision.value++;
    } catch (e, st) {
      reportInternalError(e, st);
    }
  }

  /// Applies the retention policy now.
  Future<void> runRetention() async {
    final s = _store;
    if (s == null) return;
    final p = _config.retention;
    try {
      final now = DateTime.now();
      var removed = 0;
      if (p.maxAge != null) {
        removed += await s.deleteOlderThan(now.subtract(p.maxAge!));
      }
      if (p.maxRecords != null) removed += await s.trimTo(p.maxRecords!);
      if (p.textMaxAge != null) {
        await s.stripTextOlderThan(now.subtract(p.textMaxAge!));
      }
      if (removed > 0) {
        revision.value++;
        _logger.info('retention removed $removed records');
      }
    } catch (e, st) {
      reportInternalError(e, st);
    }
  }

  // ---------------------------------------------------------------- pricing

  static const _pricingKey = 'pricing_overrides.v1';

  Future<void> _restorePricing() async {
    try {
      final saved = await _store?.readValue(_pricingKey);
      if (saved != null) {
        _pricing.loadJson((jsonDecode(saved) as Map).cast<String, Object?>());
      }
    } catch (e, st) {
      reportInternalError(e, st);
    }
    _pricing.addListener(_persistPricing);
  }

  void _persistPricing() {
    final s = _store;
    if (s == null) return;
    unawaited(
      s
          .writeValue(_pricingKey, _pricing.toJsonString())
          .catchError((Object e, StackTrace st) => reportInternalError(e, st)),
    );
  }

  /// Fetch prices from `remotePricingUrl` now. Returns false on failure
  /// (the current table is kept).
  Future<bool> refreshRemotePricing() async {
    final url = _config.remotePricingUrl;
    if (url == null) return false;
    final ok = await _pricing.loadFromUrl(
      url,
      headers: _config.remotePricingHeaders,
    );
    if (!ok) _logger.internal('could not refresh pricing from $url');
    return ok;
  }

  // ---------------------------------------------------------------- sinks

  /// Send records to an external destination (your server, PostHog,
  /// Mixpanel, OpenTelemetry...). Delivery is batched, persisted and retried.
  void addSink(AIUsageSink sink) {
    final d = SinkDispatcher(
      sink,
      onError: reportInternalError,
      logger: _logger,
    );
    _sinks.add(d);
    if (_store != null) d.attach(_store!);
  }

  void removeSink(AIUsageSink sink) {
    _sinks.removeWhere((d) {
      if (d.sink == sink) {
        d.dispose();
        return true;
      }
      return false;
    });
  }

  /// Stops timers and closes storage.
  Future<void> dispose() async {
    _retentionTimer?.cancel();
    _pricingTimer?.cancel();
    await flush();
    for (final s in _sinks) {
      s.dispose();
    }
    await _store?.close();
    await _controller.close();
  }
}
