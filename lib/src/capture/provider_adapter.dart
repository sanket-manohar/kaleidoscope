import '../models/ai_usage_record.dart';

/// What an adapter could read from an outgoing request.
class AIRequestInfo {
  AIRequestInfo({
    this.model,
    this.parameters = const {},
    this.promptText,
    this.stream = false,
    this.operation = 'chat',
  });

  String? model;
  Map<String, Object?> parameters;
  String? promptText;
  bool stream;
  String operation;
}

/// What an adapter could read from a response (or accumulated stream).
class AIResponseInfo {
  AIResponseInfo({
    this.model,
    this.usage,
    this.text,
    this.finishReason,
    this.responseId,
  });

  String? model;
  AITokenUsage? usage;
  String? text;
  String? finishReason;
  String? responseId;
}

/// Collects data from stream events.
class AIStreamAccumulator {
  final text = StringBuffer();
  String? model;
  AITokenUsage? usage;
  String? finishReason;
  String? responseId;
  int events = 0;

  AIResponseInfo toResponse() => AIResponseInfo(
    model: model,
    usage: usage,
    text: text.isEmpty ? null : text.toString(),
    finishReason: finishReason,
    responseId: responseId,
  );
}

/// Teaches the HTTP interceptors how to read one provider's API.
/// Register your own with `KaleidoscopeTracker.registerAdapter`.
abstract class AIProviderAdapter {
  const AIProviderAdapter();

  /// Default provider name (adapters may refine it per host).
  String get provider;

  /// Whether this adapter understands requests to [uri].
  bool matches(Uri uri);

  /// Provider name for [uri] (e.g. `groq` for an OpenAI-compatible host).
  String providerFor(Uri uri) => provider;

  AIRequestInfo parseRequest(Uri uri, Map<String, Object?>? body);
  AIResponseInfo parseResponse(Uri uri, Object? json);

  /// Called with each decoded event of a streamed response.
  void onStreamEvent(Uri uri, Object? json, AIStreamAccumulator acc);

  /// Whether [uri]/[body] describe a streaming request.
  bool isStreaming(Uri uri, Map<String, Object?>? body) =>
      body?['stream'] == true;
}

/// Shared helpers for adapters.
abstract final class AdapterUtils {
  static Map<String, Object?>? map(Object? v) =>
      v is Map ? v.cast<String, Object?>() : null;
  static List<Object?> list(Object? v) => v is List ? v : const [];

  /// Copies selected keys from [src] when present.
  static Map<String, Object?> pick(
    Map<String, Object?>? src,
    List<String> keys,
  ) {
    final out = <String, Object?>{};
    if (src == null) return out;
    for (final k in keys) {
      if (src.containsKey(k) && src[k] != null) out[k] = _small(src[k]);
    }
    return out;
  }

  /// Keeps parameter values small (no huge schemas in records).
  static Object? _small(Object? v) {
    if (v is String && v.length > 200) return '${v.substring(0, 200)}…';
    if (v is Map || v is List) {
      final s = v.toString();
      return s.length > 300 ? '${s.substring(0, 300)}…' : v;
    }
    return v;
  }

  /// Extracts text from OpenAI/Anthropic-style message content.
  static String contentText(Object? content) {
    if (content is String) return content;
    if (content is List) {
      return content
          .map((p) {
            final m = map(p);
            if (m == null) return p is String ? p : '';
            return m['text'] ?? m['input_text'] ?? '';
          })
          .where((e) => '$e'.isNotEmpty)
          .join('\n');
    }
    return '';
  }
}
