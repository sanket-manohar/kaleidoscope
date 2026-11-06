import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../models/ai_usage_record.dart';
import 'ai_usage_sink.dart';

/// Base for sinks that POST JSON. Non-2xx responses count as failures.
abstract class JsonPostSink extends AIUsageSink {
  JsonPostSink({http.Client? client}) : _client = client;
  final http.Client? _client;

  Future<void> postJson(
    Uri url,
    Object body, {
    Map<String, String> headers = const {},
  }) async {
    final c = _client ?? http.Client();
    try {
      final res = await c.post(
        url,
        headers: {'content-type': 'application/json', ...headers},
        body: jsonEncode(body),
      );
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw http.ClientException(
          'HTTP ${res.statusCode}: ${res.body.length > 200 ? res.body.substring(0, 200) : res.body}',
          url,
        );
      }
    } finally {
      if (_client == null) c.close();
    }
  }
}

/// Syncs records to your own backend in batches:
/// `POST endpoint` with `{"app": ..., "records": [AIUsageRecord.toJson()...]}`.
/// See `example/server/` for a ready-to-run receiver.
class ServerSyncSink extends JsonPostSink {
  ServerSyncSink({
    required this.endpoint,
    this.headers = const {},
    this.appId,
    this.batchSize = 100,
    this.flushInterval = const Duration(seconds: 60),
    this.includeText = false,
    super.client,
  });

  final Uri endpoint;
  final Map<String, String> headers;
  final String? appId;
  @override
  final int batchSize;
  @override
  final Duration flushInterval;
  @override
  final bool includeText;

  @override
  String get name => 'server:${endpoint.host}${endpoint.path}';

  @override
  Future<void> send(List<AIUsageRecord> batch) => postJson(endpoint, {
    if (appId != null) 'app': appId,
    'sentAt': DateTime.now().toUtc().toIso8601String(),
    'records': batch.map((r) => r.toJson()).toList(),
  }, headers: headers);
}

/// Sends `$ai_generation` events to PostHog (LLM analytics properties).
class PostHogSink extends JsonPostSink {
  PostHogSink({
    required this.apiKey,
    this.host = 'https://us.i.posthog.com',
    this.distinctId,
    super.client,
  });

  final String apiKey;
  final String host;

  /// Defaults to the record's `context.userId`, else `anonymous`.
  final String? distinctId;

  @override
  String get name => 'posthog';

  @override
  Future<void> send(List<AIUsageRecord> batch) =>
      postJson(Uri.parse('$host/batch/'), {
        'api_key': apiKey,
        'batch': [
          for (final r in batch)
            {
              'event': '\$ai_generation',
              'distinct_id': distinctId ?? r.context.userId ?? 'anonymous',
              'timestamp': r.timestamp.toUtc().toIso8601String(),
              'properties': {
                '\$ai_trace_id': r.context.conversationId ?? r.id,
                '\$ai_provider': r.provider,
                '\$ai_model': r.model,
                '\$ai_input_tokens':
                    r.usage.inputTokens + r.usage.cachedInputTokens,
                '\$ai_output_tokens': r.usage.outputTokens,
                '\$ai_cache_read_input_tokens': r.usage.cachedInputTokens,
                '\$ai_total_cost_usd': r.cost.total,
                if (r.latencyMs != null) '\$ai_latency': r.latencyMs! / 1000,
                '\$ai_is_error': r.isError,
                if (r.errorMessage != null) '\$ai_error': r.errorMessage,
                '\$ai_http_status': r.httpStatus,
                '\$ai_stream': r.streamed,
                ..._flat(r),
              },
            },
        ],
      });
}

/// Sends `AI Call` events to Mixpanel (`/track`).
class MixpanelSink extends JsonPostSink {
  MixpanelSink({
    required this.projectToken,
    this.host = 'https://api.mixpanel.com',
    this.eventName = 'AI Call',
    super.client,
  });

  final String projectToken;
  final String host;
  final String eventName;

  @override
  String get name => 'mixpanel';

  @override
  Future<void> send(List<AIUsageRecord> batch) =>
      postJson(Uri.parse('$host/track'), [
        for (final r in batch)
          {
            'event': eventName,
            'properties': {
              'token': projectToken,
              'time': r.timestamp.millisecondsSinceEpoch,
              '\$insert_id': r.id,
              'distinct_id': r.context.userId ?? 'anonymous',
              'provider': r.provider,
              'model': r.model,
              'input_tokens': r.usage.inputTokens,
              'output_tokens': r.usage.outputTokens,
              'cached_tokens': r.usage.cachedInputTokens,
              'total_tokens': r.usage.totalTokens,
              'cost': r.cost.total,
              'currency': r.cost.currency,
              'latency_ms': r.latencyMs,
              'status': r.status.name,
              ..._flat(r),
            },
          },
      ]);
}

Map<String, Object?> _flat(AIUsageRecord r) => {
  'operation': r.operation,
  if (r.context.module != null) 'module': r.context.module,
  if (r.context.page != null) 'page': r.context.page,
  if (r.context.section != null) 'section': r.context.section,
  if (r.context.feature != null) 'feature': r.context.feature,
  if (r.context.tags.isNotEmpty) 'tags': r.context.tags,
  ...r.context.custom.map((k, v) => MapEntry('custom_$k', v)),
  ...r.customData.map((k, v) => MapEntry('custom_$k', v)),
};

/// Exports each record as an OpenTelemetry span (OTLP/HTTP JSON) using the
/// GenAI semantic conventions (`gen_ai.*`). Works with any OTLP collector,
/// Grafana, Honeycomb, Datadog, and Langfuse ([OpenTelemetrySink.langfuse]).
class OpenTelemetrySink extends JsonPostSink {
  OpenTelemetrySink({
    required this.tracesEndpoint,
    this.headers = const {},
    this.serviceName = 'flutter-app',
    this.includeText = false,
    super.client,
  });

  /// Langfuse cloud or self-hosted (`host` e.g. https://cloud.langfuse.com).
  factory OpenTelemetrySink.langfuse({
    required String publicKey,
    required String secretKey,
    String host = 'https://cloud.langfuse.com',
    String serviceName = 'flutter-app',
    bool includeText = false,
    http.Client? client,
  }) => OpenTelemetrySink(
    tracesEndpoint: Uri.parse('$host/api/public/otel/v1/traces'),
    headers: {
      'Authorization':
          'Basic ${base64Encode(utf8.encode('$publicKey:$secretKey'))}',
    },
    serviceName: serviceName,
    includeText: includeText,
    client: client,
  );

  final Uri tracesEndpoint;
  final Map<String, String> headers;
  final String serviceName;
  @override
  final bool includeText;

  @override
  String get name => 'otel:${tracesEndpoint.host}';

  static final _rnd = Random.secure();
  static String _hex(int bytes) => List.generate(
    bytes,
    (_) => _rnd.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();

  static Map<String, Object?> _attr(String k, Object? v) {
    final Map<String, Object?> value;
    if (v is int) {
      value = {'intValue': '$v'};
    } else if (v is double) {
      value = {'doubleValue': v};
    } else if (v is bool) {
      value = {'boolValue': v};
    } else if (v is List) {
      value = {
        'arrayValue': {
          'values': [
            for (final e in v) {'stringValue': '$e'},
          ],
        },
      };
    } else {
      value = {'stringValue': '$v'};
    }
    return {'key': k, 'value': value};
  }

  Map<String, Object?> span(AIUsageRecord r) {
    final start = r.timestamp.microsecondsSinceEpoch * 1000;
    final end = start + (r.latencyMs ?? 0) * 1000000;
    final p = r.parameters;
    final attrs = <String, Object?>{
      'gen_ai.operation.name': r.operation == 'chat' ? 'chat' : r.operation,
      'gen_ai.provider.name': r.provider,
      'gen_ai.system': r.provider,
      'gen_ai.request.model': r.model,
      'gen_ai.response.model': r.model,
      'gen_ai.usage.input_tokens':
          r.usage.inputTokens + r.usage.cachedInputTokens,
      'gen_ai.usage.output_tokens': r.usage.outputTokens,
      if (r.usage.cachedInputTokens > 0)
        'gen_ai.usage.cache_read.input_tokens': r.usage.cachedInputTokens,
      if (r.responseId != null) 'gen_ai.response.id': r.responseId,
      if (r.finishReason != null)
        'gen_ai.response.finish_reasons': [r.finishReason],
      if (p['temperature'] is num)
        'gen_ai.request.temperature': (p['temperature'] as num).toDouble(),
      if (p['max_tokens'] is int) 'gen_ai.request.max_tokens': p['max_tokens'],
      if (p['top_p'] is num)
        'gen_ai.request.top_p': (p['top_p'] as num).toDouble(),
      if (r.context.conversationId != null)
        'gen_ai.conversation.id': r.context.conversationId,
      if (r.isError) 'error.type': r.httpStatus?.toString() ?? 'error',
      'app.ai.cost': r.cost.total,
      'app.ai.currency': r.cost.currency,
      if (r.timeToFirstTokenMs != null) 'app.ai.ttft_ms': r.timeToFirstTokenMs,
      ..._flat(r).map((k, v) => MapEntry('app.ai.$k', v)),
      if (includeText && r.prompt != null) 'gen_ai.input.messages': r.prompt,
      if (includeText && r.response != null)
        'gen_ai.output.messages': r.response,
    };
    return {
      'traceId': _hex(16),
      'spanId': _hex(8),
      'name': '${r.operation} ${r.model}',
      'kind': 3, // CLIENT
      'startTimeUnixNano': '$start',
      'endTimeUnixNano': '$end',
      'attributes': [for (final e in attrs.entries) _attr(e.key, e.value)],
      'status': {
        'code': r.isError ? 2 : 1,
        if (r.errorMessage != null) 'message': r.errorMessage,
      },
    };
  }

  @override
  Future<void> send(List<AIUsageRecord> batch) => postJson(tracesEndpoint, {
    'resourceSpans': [
      {
        'resource': {
          'attributes': [_attr('service.name', serviceName)],
        },
        'scopeSpans': [
          {
            'scope': {'name': 'kaleidoscope'},
            'spans': batch.map(span).toList(),
          },
        ],
      },
    ],
  }, headers: headers);
}

/// Calls your own function for each batch (e.g. Firebase Analytics,
/// Sentry breadcrumbs, a custom SDK).
class CallbackSink extends AIUsageSink {
  CallbackSink(
    this.name,
    this.onBatch, {
    this.batchSize = 20,
    this.includeText = false,
  });
  @override
  final String name;
  final Future<void> Function(List<AIUsageRecord> batch) onBatch;
  @override
  final int batchSize;
  @override
  final bool includeText;
  @override
  Future<void> send(List<AIUsageRecord> batch) => onBatch(batch);
}
