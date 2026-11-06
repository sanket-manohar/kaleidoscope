import '../provider_adapter.dart';
import '../usage_extractors.dart';

/// Cohere chat API (v1 and v2).
class CohereAdapter extends AIProviderAdapter {
  const CohereAdapter();

  @override
  String get provider => 'cohere';

  @override
  bool matches(Uri uri) =>
      uri.host.contains('cohere') &&
      (uri.path.endsWith('/chat') || uri.path.endsWith('/embed'));

  @override
  AIRequestInfo parseRequest(Uri uri, Map<String, Object?>? body) {
    final text = StringBuffer();
    if (body?['message'] is String) text.writeln(body!['message']);
    for (final m in AdapterUtils.list(body?['messages'])) {
      final mm = AdapterUtils.map(m);
      final t = AdapterUtils.contentText(mm?['content']);
      if (t.isNotEmpty) text.writeln('[${mm?['role'] ?? 'user'}] $t');
    }
    return AIRequestInfo(
      model: body?['model'] as String?,
      parameters: AdapterUtils.pick(body, const [
        'temperature',
        'p',
        'k',
        'max_tokens',
        'seed',
        'stop_sequences',
      ]),
      promptText: text.isEmpty ? null : text.toString().trim(),
      stream: body?['stream'] == true,
      operation: uri.path.endsWith('/embed') ? 'embedding' : 'chat',
    );
  }

  @override
  AIResponseInfo parseResponse(Uri uri, Object? json) {
    final root = AdapterUtils.map(json);
    final msg = AdapterUtils.map(root?['message']);
    final text = msg != null
        ? AdapterUtils.contentText(msg['content'])
        : root?['text'] as String?;
    return AIResponseInfo(
      usage: UsageExtractors.cohere(root),
      text: text,
      finishReason: root?['finish_reason'] as String?,
      responseId: (root?['id'] ?? root?['response_id']) as String?,
    );
  }

  @override
  void onStreamEvent(Uri uri, Object? json, AIStreamAccumulator acc) {
    final root = AdapterUtils.map(json);
    if (root == null) return;
    acc.events++;
    final type = root['type'] ?? root['event_type'];
    if (type == 'content-delta') {
      final t = AdapterUtils.map(
        AdapterUtils.map(
          AdapterUtils.map(root['delta'])?['message'],
        )?['content'],
      )?['text'];
      if (t is String) acc.text.write(t);
    } else if (type == 'text-generation' && root['text'] is String) {
      acc.text.write(root['text']);
    } else if (type == 'message-end' || type == 'stream-end') {
      acc.usage =
          UsageExtractors.cohere(root) ??
          UsageExtractors.cohere(AdapterUtils.map(root['response'])) ??
          acc.usage;
      final d = AdapterUtils.map(root['delta']);
      acc.finishReason =
          (d?['finish_reason'] ?? root['finish_reason']) as String?;
    }
  }
}
