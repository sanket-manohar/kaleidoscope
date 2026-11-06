import '../models/ai_usage_context.dart';
import '../models/ai_usage_record.dart';

/// Mutable data collected during a call, turned into an [AIUsageRecord]
/// by the tracker.
class AIUsageDraft {
  AIUsageDraft({
    required this.provider,
    this.model,
    this.operation = 'chat',
    this.endpoint,
    this.context = AIUsageContext.empty,
    this.parameters = const {},
    this.customData = const {},
    this.prompt,
    this.source = AICaptureSource.manual,
    DateTime? startedAt,
  }) : startedAt = startedAt ?? DateTime.now();

  String provider;
  String? model;
  String operation;
  String? endpoint;
  AIUsageContext context;
  Map<String, Object?> parameters;
  Map<String, Object?> customData;
  String? prompt;
  String? response;
  AICaptureSource source;
  final DateTime startedAt;

  AITokenUsage? usage;
  int? latencyMs;
  int? timeToFirstTokenMs;
  AICallStatus status = AICallStatus.success;
  String? errorMessage;
  int? httpStatus;
  bool streamed = false;
  String? finishReason;
  String? responseId;
}
