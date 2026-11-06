import 'package:dio/dio.dart' show Interceptor;
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import '../analytics/ai_usage_analytics.dart';
import '../config/tracker_config.dart';
import '../export/usage_exporter.dart';
import '../models/ai_usage_context.dart';
import '../models/ai_usage_record.dart';
import '../pricing/pricing_table.dart';
import '../sinks/ai_usage_sink.dart';
import '../storage/usage_store.dart';
import '../widgets/ai_analytics_screen.dart';
import '../widgets/ai_usage_scope.dart';
import 'kaleidoscope_tracker.dart';

/// The simple API. Everything here forwards to [KaleidoscopeTracker.instance].
///
/// ```dart
/// await Kaleidoscope.init();                       // 1. start
/// final client = Kaleidoscope.httpClient();        // 2. use for AI calls
/// Kaleidoscope.openDashboard(context);             // 3. see the analytics
/// ```
abstract final class Kaleidoscope {
  static KaleidoscopeTracker get instance => KaleidoscopeTracker.instance;

  /// Starts the tracker. All arguments are optional.
  ///
  /// * [storePrompts]: keep prompt/response text (`true` = full text,
  ///   or use [promptStorage] for `redacted`). Default: metadata only.
  /// * [keepFor] / [maxRecords]: your retention policy.
  /// * [monthlyBudget]: enables budget tracking and alerts.
  /// * [debugLog]: console output in debug builds.
  /// * [config]: every advanced option (overrides the shortcuts).
  static Future<void> init({
    bool storePrompts = false,
    PromptStorageMode? promptStorage,
    Duration? keepFor = const Duration(days: 90),
    int? maxRecords = 50000,
    Duration? keepPromptTextFor,
    double? monthlyBudget,
    AIDebugLogLevel debugLog = AIDebugLogLevel.summary,
    Uri? remotePricingUrl,
    AIUsageContext? defaultContext,
    KaleidoscopeConfig? config,
  }) => instance.initialize(
    config ??
        KaleidoscopeConfig(
          promptStorage:
              promptStorage ??
              (storePrompts
                  ? PromptStorageMode.full
                  : PromptStorageMode.metadataOnly),
          retention: RetentionPolicy(
            maxAge: keepFor,
            maxRecords: maxRecords,
            textMaxAge: keepPromptTextFor,
          ),
          monthlyBudget: monthlyBudget,
          debugLog: AIDebugLogConfig(level: debugLog),
          remotePricingUrl: remotePricingUrl,
          defaultContext: defaultContext,
        ),
  );

  /// `http.Client` that tracks AI calls (pass the client your SDK accepts,
  /// e.g. `OpenAIClient(client: Kaleidoscope.httpClient())`).
  static http.Client httpClient([http.Client? inner]) =>
      instance.httpClient(inner);

  /// Dio interceptor: `dio.interceptors.add(Kaleidoscope.dioInterceptor())`.
  static Interceptor dioInterceptor() => instance.dioInterceptor();

  /// Wrap any AI call. See [KaleidoscopeTracker.track].
  static Future<T> track<T>({
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
  }) => instance.track<T>(
    provider: provider,
    model: model,
    call: call,
    usage: usage,
    responseText: responseText,
    prompt: prompt,
    operation: operation,
    parameters: parameters,
    context: context,
    customData: customData,
  );

  /// Wrap a streaming AI call. See [KaleidoscopeTracker.trackStream].
  static Stream<T> trackStream<T>({
    required String provider,
    required String model,
    required Stream<T> Function() call,
    ({String? text, AITokenUsage? usage})? Function(T chunk)? onChunk,
    String? prompt,
    Map<String, Object?> parameters = const {},
    AIUsageContext? context,
  }) => instance.trackStream<T>(
    provider: provider,
    model: model,
    call: call,
    onChunk: onChunk,
    prompt: prompt,
    parameters: parameters,
    context: context,
  );

  /// Record a call you measured yourself (e.g. on-device or server-side).
  static void record({
    required String provider,
    required String model,
    int inputTokens = 0,
    int outputTokens = 0,
    int cachedInputTokens = 0,
    int? latencyMs,
    AIUsageContext? context,
    Map<String, Object?> customData = const {},
  }) => instance.record(
    provider: provider,
    model: model,
    inputTokens: inputTokens,
    outputTokens: outputTokens,
    cachedInputTokens: cachedInputTokens,
    latencyMs: latencyMs,
    context: context,
    customData: customData,
  );

  /// Tag every AI call inside [body] with module / page / section.
  ///
  /// ```dart
  /// final reply = await Kaleidoscope.scope(module: 'support', page: 'chat',
  ///     section: 'composer', () => client.post(...));
  /// ```
  static R scope<R>(
    R Function() body, {
    String? module,
    String? page,
    String? section,
    String? feature,
    String? userId,
    String? conversationId,
    List<String> tags = const [],
    Map<String, Object?> custom = const {},
  }) => KaleidoscopeTracker.runWithContext(
    AIUsageContext(
      module: module,
      page: page,
      section: section,
      feature: feature,
      userId: userId,
      conversationId: conversationId,
      tags: tags,
      custom: custom,
    ),
    body,
  );

  /// Auto-tags calls with the current route name.
  static NavigatorObserver navigatorObserver({
    String? Function(String route)? moduleForRoute,
  }) => AIUsageNavigatorObserver(moduleForRoute: moduleForRoute);

  /// Update prices at runtime: `Kaleidoscope.pricing.setPrice('my-model', ...)`.
  static PricingTable get pricing => instance.pricing;

  /// All analytics: summary, breakdowns, trends, forecasts, anomalies...
  static AIUsageAnalytics get analytics => instance.analytics;

  /// Estimate tokens and cost before sending.
  static AICostEstimate estimate({
    required String model,
    String? prompt,
    int? inputTokens,
    int expectedOutputTokens = 500,
    String? provider,
  }) => instance.estimate(
    model: model,
    prompt: prompt,
    inputTokens: inputTokens,
    expectedOutputTokens: expectedOutputTokens,
    provider: provider,
  );

  /// Send records to your server / PostHog / Mixpanel / OpenTelemetry.
  static void addSink(AIUsageSink sink) => instance.addSink(sink);

  static Future<List<AIUsageRecord>> records([
    UsageQuery query = UsageQuery.all,
  ]) => instance.records(query);

  static Future<String> exportJson({DateTime? from}) async =>
      AIUsageExporter.toJson(await instance.records(UsageQuery(from: from)));

  static Future<String> exportCsv({DateTime? from}) async =>
      AIUsageExporter.toCsv(await instance.records(UsageQuery(from: from)));

  static Future<String> exportHtml({
    DateTime? from,
    String title = 'AI usage report',
  }) async => AIUsageExporter.toHtml(
    await instance.analytics.report(from: from),
    title: title,
  );

  /// Opens the built-in analytics screen.
  static Future<void> openDashboard(
    BuildContext context, {
    String? accessPin,
    bool allowInRelease = false,
  }) => AIAnalyticsScreen.open(
    context,
    accessPin: accessPin,
    allowInRelease: allowInRelease,
  );
}
