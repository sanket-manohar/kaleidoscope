import 'dart:convert';

import 'package:kaleidoscope/kaleidoscope.dart';

/// Tracker on an in-memory store with console logging off.
Future<KaleidoscopeTracker> newTracker({
  PromptStorageMode promptStorage = PromptStorageMode.metadataOnly,
  UsageStore? store,
  bool injectStreamUsageOption = false,
  RetentionPolicy retention = const RetentionPolicy(),
  List<String> additionalHosts = const [],
  void Function(Object, StackTrace)? onError,
  AIRecordTransformer? beforeSave,
  double? monthlyBudget,
}) async {
  final t = KaleidoscopeTracker();
  await t.initialize(
    KaleidoscopeConfig(
      store: store ?? InMemoryUsageStore(),
      promptStorage: promptStorage,
      debugLog: AIDebugLogConfig.off,
      injectStreamUsageOption: injectStreamUsageOption,
      retention: retention,
      additionalHostsToTrack: additionalHosts,
      onError: onError,
      beforeSave: beforeSave,
      monthlyBudget: monthlyBudget,
    ),
  );
  return t;
}

String sse(List<Object> events) =>
    events.map((e) => 'data: ${e is String ? e : jsonEncode(e)}\n\n').join();

AIUsageRecord rec({
  required DateTime at,
  String model = 'gpt-4o-mini',
  String provider = 'openai',
  int input = 100,
  int output = 50,
  double cost = 0.01,
  int? latency = 500,
  AICallStatus status = AICallStatus.success,
  AIUsageContext context = AIUsageContext.empty,
  String? prompt,
}) => AIUsageRecord(
  id: '${at.microsecondsSinceEpoch}-$model-$input',
  timestamp: at,
  provider: provider,
  model: model,
  usage: AITokenUsage(inputTokens: input, outputTokens: output),
  cost: AICost(input: cost),
  latencyMs: latency,
  status: status,
  context: context,
  prompt: prompt,
);

/// A store whose writes always fail.
class BrokenStore extends InMemoryUsageStore {
  @override
  Future<void> insert(AIUsageRecord record) async =>
      throw StateError('disk full');
  @override
  Future<List<AIUsageRecord>> query(UsageQuery q) async =>
      throw StateError('corrupt');
}
