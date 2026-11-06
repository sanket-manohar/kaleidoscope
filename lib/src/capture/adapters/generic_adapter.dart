import '../provider_adapter.dart';
import '../usage_extractors.dart';
import 'openai_compatible_adapter.dart';

/// Fallback for hosts you list in `additionalHostsToTrack` that no other
/// adapter understands. It reads common field names and tries every known
/// usage shape.
class GenericAdapter extends AIProviderAdapter {
  const GenericAdapter();

  @override
  String get provider => 'custom';

  @override
  bool matches(Uri uri) => false; // Only used explicitly.

  @override
  String providerFor(Uri uri) => uri.host;

  @override
  AIRequestInfo parseRequest(Uri uri, Map<String, Object?>? body) {
    final info = const OpenAICompatibleAdapter().parseRequest(uri, body);
    info.model ??= (body?['model_id'] ?? body?['modelId']) as String?;
    return info;
  }

  @override
  AIResponseInfo parseResponse(Uri uri, Object? json) {
    final info = const OpenAICompatibleAdapter().parseResponse(uri, json);
    info.usage ??= UsageExtractors.auto(json);
    final root = AdapterUtils.map(json);
    info.text ??=
        (root?['text'] ??
                root?['output'] ??
                root?['response'] ??
                root?['completion'])
            is String
        ? (root?['text'] ??
                  root?['output'] ??
                  root?['response'] ??
                  root?['completion'])
              as String
        : null;
    return info;
  }

  @override
  void onStreamEvent(Uri uri, Object? json, AIStreamAccumulator acc) {
    const OpenAICompatibleAdapter().onStreamEvent(uri, json, acc);
    acc.usage = UsageExtractors.auto(json) ?? acc.usage;
  }
}
