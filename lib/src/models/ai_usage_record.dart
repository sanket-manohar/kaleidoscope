import 'ai_usage_context.dart';

/// Outcome of a tracked AI call.
enum AICallStatus { success, error, cancelled }

/// How the record was captured.
enum AICaptureSource { manual, wrapper, httpClient, dio, custom }

/// Token usage reported by (or estimated for) a single AI call.
class AITokenUsage {
  const AITokenUsage({
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.cachedInputTokens = 0,
    this.cacheWriteTokens = 0,
    this.reasoningTokens = 0,
    int? totalTokens,
    this.estimated = false,
  }) : _total = totalTokens;

  /// Prompt / question tokens (not counting cached reads).
  final int inputTokens;

  /// Completion / answer tokens.
  final int outputTokens;

  /// Prompt tokens served from the provider's cache.
  final int cachedInputTokens;

  /// Prompt tokens written to the provider's cache.
  final int cacheWriteTokens;

  /// Reasoning / thinking tokens, when reported separately.
  final int reasoningTokens;

  final int? _total;

  /// True when the numbers came from a character-based estimate because the
  /// provider did not report usage.
  final bool estimated;

  int get totalTokens =>
      _total ??
      inputTokens + outputTokens + cachedInputTokens + cacheWriteTokens;

  static const zero = AITokenUsage();

  AITokenUsage operator +(AITokenUsage o) => AITokenUsage(
    inputTokens: inputTokens + o.inputTokens,
    outputTokens: outputTokens + o.outputTokens,
    cachedInputTokens: cachedInputTokens + o.cachedInputTokens,
    cacheWriteTokens: cacheWriteTokens + o.cacheWriteTokens,
    reasoningTokens: reasoningTokens + o.reasoningTokens,
    totalTokens: totalTokens + o.totalTokens,
    estimated: estimated || o.estimated,
  );

  Map<String, Object?> toJson() => {
    'input': inputTokens,
    'output': outputTokens,
    'cachedInput': cachedInputTokens,
    'cacheWrite': cacheWriteTokens,
    'reasoning': reasoningTokens,
    'total': totalTokens,
    'estimated': estimated,
  };

  factory AITokenUsage.fromJson(Map<String, Object?> j) => AITokenUsage(
    inputTokens: (j['input'] as num?)?.toInt() ?? 0,
    outputTokens: (j['output'] as num?)?.toInt() ?? 0,
    cachedInputTokens: (j['cachedInput'] as num?)?.toInt() ?? 0,
    cacheWriteTokens: (j['cacheWrite'] as num?)?.toInt() ?? 0,
    reasoningTokens: (j['reasoning'] as num?)?.toInt() ?? 0,
    totalTokens: (j['total'] as num?)?.toInt(),
    estimated: j['estimated'] == true,
  );
}

/// Cost of a call, computed from the pricing table at capture time.
class AICost {
  const AICost({
    this.input = 0,
    this.output = 0,
    this.cached = 0,
    this.currency = 'USD',
    this.priced = true,
  });

  final double input;
  final double output;
  final double cached;
  final String currency;

  /// False when no pricing entry matched the model (cost is 0).
  final bool priced;

  double get total => input + output + cached;

  static const unpriced = AICost(priced: false);

  Map<String, Object?> toJson() => {
    'input': input,
    'output': output,
    'cached': cached,
    'total': total,
    'currency': currency,
    'priced': priced,
  };

  factory AICost.fromJson(Map<String, Object?> j) => AICost(
    input: (j['input'] as num?)?.toDouble() ?? 0,
    output: (j['output'] as num?)?.toDouble() ?? 0,
    cached: (j['cached'] as num?)?.toDouble() ?? 0,
    currency: j['currency'] as String? ?? 'USD',
    priced: j['priced'] != false,
  );
}

/// One logged AI call. Immutable.
class AIUsageRecord {
  AIUsageRecord({
    required this.id,
    required this.timestamp,
    required this.provider,
    required this.model,
    this.operation = 'chat',
    this.endpoint,
    this.usage = AITokenUsage.zero,
    this.cost = AICost.unpriced,
    this.latencyMs,
    this.timeToFirstTokenMs,
    this.status = AICallStatus.success,
    this.errorMessage,
    this.httpStatus,
    this.streamed = false,
    this.finishReason,
    this.responseId,
    this.parameters = const {},
    this.context = AIUsageContext.empty,
    this.customData = const {},
    this.prompt,
    this.response,
    this.source = AICaptureSource.manual,
  });

  final String id;
  final DateTime timestamp;

  /// Provider name, e.g. `openai`, `anthropic`, `gemini`, `ollama`, or any
  /// custom string.
  final String provider;
  final String model;

  /// `chat`, `completion`, `embedding`, `image`, `audio`, ... (free-form).
  final String operation;
  final String? endpoint;
  final AITokenUsage usage;
  final AICost cost;
  final int? latencyMs;
  final int? timeToFirstTokenMs;
  final AICallStatus status;
  final String? errorMessage;
  final int? httpStatus;
  final bool streamed;
  final String? finishReason;
  final String? responseId;

  /// Request parameters such as temperature, max_tokens, top_p, tools.
  final Map<String, Object?> parameters;
  final AIUsageContext context;

  /// Your own data for this call.
  final Map<String, Object?> customData;

  /// Prompt text, only present when prompt storage is enabled.
  final String? prompt;

  /// Response text, only present when prompt storage is enabled.
  final String? response;
  final AICaptureSource source;

  bool get isError => status == AICallStatus.error;

  AIUsageRecord copyWith({
    AITokenUsage? usage,
    AICost? cost,
    AIUsageContext? context,
    String? prompt,
    String? response,
    bool clearText = false,
    Map<String, Object?>? customData,
    Map<String, Object?>? parameters,
  }) => AIUsageRecord(
    id: id,
    timestamp: timestamp,
    provider: provider,
    model: model,
    operation: operation,
    endpoint: endpoint,
    usage: usage ?? this.usage,
    cost: cost ?? this.cost,
    latencyMs: latencyMs,
    timeToFirstTokenMs: timeToFirstTokenMs,
    status: status,
    errorMessage: errorMessage,
    httpStatus: httpStatus,
    streamed: streamed,
    finishReason: finishReason,
    responseId: responseId,
    parameters: parameters ?? this.parameters,
    context: context ?? this.context,
    customData: customData ?? this.customData,
    prompt: clearText ? null : (prompt ?? this.prompt),
    response: clearText ? null : (response ?? this.response),
    source: source,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'timestamp': timestamp.toUtc().toIso8601String(),
    'provider': provider,
    'model': model,
    'operation': operation,
    if (endpoint != null) 'endpoint': endpoint,
    'usage': usage.toJson(),
    'cost': cost.toJson(),
    if (latencyMs != null) 'latencyMs': latencyMs,
    if (timeToFirstTokenMs != null) 'ttftMs': timeToFirstTokenMs,
    'status': status.name,
    if (errorMessage != null) 'error': errorMessage,
    if (httpStatus != null) 'httpStatus': httpStatus,
    'streamed': streamed,
    if (finishReason != null) 'finishReason': finishReason,
    if (responseId != null) 'responseId': responseId,
    if (parameters.isNotEmpty) 'parameters': parameters,
    'context': context.toJson(),
    if (customData.isNotEmpty) 'customData': customData,
    if (prompt != null) 'prompt': prompt,
    if (response != null) 'response': response,
    'source': source.name,
  };

  factory AIUsageRecord.fromJson(Map<String, Object?> j) => AIUsageRecord(
    id: j['id'] as String,
    timestamp: DateTime.parse(j['timestamp'] as String).toLocal(),
    provider: j['provider'] as String? ?? 'unknown',
    model: j['model'] as String? ?? 'unknown',
    operation: j['operation'] as String? ?? 'chat',
    endpoint: j['endpoint'] as String?,
    usage: AITokenUsage.fromJson(
      (j['usage'] as Map?)?.cast<String, Object?>() ?? const {},
    ),
    cost: AICost.fromJson(
      (j['cost'] as Map?)?.cast<String, Object?>() ?? const {},
    ),
    latencyMs: (j['latencyMs'] as num?)?.toInt(),
    timeToFirstTokenMs: (j['ttftMs'] as num?)?.toInt(),
    status: AICallStatus.values.firstWhere(
      (s) => s.name == j['status'],
      orElse: () => AICallStatus.success,
    ),
    errorMessage: j['error'] as String?,
    httpStatus: (j['httpStatus'] as num?)?.toInt(),
    streamed: j['streamed'] == true,
    finishReason: j['finishReason'] as String?,
    responseId: j['responseId'] as String?,
    parameters: (j['parameters'] as Map?)?.cast<String, Object?>() ?? const {},
    context: AIUsageContext.fromJson(
      (j['context'] as Map?)?.cast<String, Object?>() ?? const {},
    ),
    customData: (j['customData'] as Map?)?.cast<String, Object?>() ?? const {},
    prompt: j['prompt'] as String?,
    response: j['response'] as String?,
    source: AICaptureSource.values.firstWhere(
      (s) => s.name == j['source'],
      orElse: () => AICaptureSource.manual,
    ),
  );
}
