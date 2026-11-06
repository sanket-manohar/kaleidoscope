import '../provider_adapter.dart';
import '../usage_extractors.dart';

/// Ollama native API (`/api/chat`, `/api/generate`, `/api/embed`).
/// Streams NDJSON by default.
class OllamaAdapter extends AIProviderAdapter {
  const OllamaAdapter();

  @override
  String get provider => 'ollama';

  @override
  bool matches(Uri uri) {
    final p = uri.path;
    return p.endsWith('/api/chat') ||
        p.endsWith('/api/generate') ||
        p.endsWith('/api/embed') ||
        p.endsWith('/api/embeddings');
  }

  @override
  bool isStreaming(Uri uri, Map<String, Object?>? body) =>
      !uri.path.contains('/api/embed') && body?['stream'] != false;

  @override
  AIRequestInfo parseRequest(Uri uri, Map<String, Object?>? body) {
    final params = AdapterUtils.pick(AdapterUtils.map(body?['options']), const [
      'temperature',
      'top_p',
      'top_k',
      'num_predict',
      'num_ctx',
      'seed',
    ]);
    final text = StringBuffer();
    if (body?['system'] is String) text.writeln('[system] ${body!['system']}');
    if (body?['prompt'] is String) text.writeln(body!['prompt']);
    for (final m in AdapterUtils.list(body?['messages'])) {
      final mm = AdapterUtils.map(m);
      final t = AdapterUtils.contentText(mm?['content']);
      if (t.isNotEmpty) text.writeln('[${mm?['role'] ?? 'user'}] $t');
    }
    return AIRequestInfo(
      model: body?['model'] as String?,
      parameters: params,
      promptText: text.isEmpty ? null : text.toString().trim(),
      stream: isStreaming(uri, body),
      operation: uri.path.contains('/api/embed') ? 'embedding' : 'chat',
    );
  }

  @override
  AIResponseInfo parseResponse(Uri uri, Object? json) {
    final root = AdapterUtils.map(json);
    final msg = AdapterUtils.map(root?['message']);
    return AIResponseInfo(
      model: root?['model'] as String?,
      usage: UsageExtractors.ollama(root),
      text: (msg?['content'] ?? root?['response']) as String?,
      finishReason: root?['done_reason'] as String?,
    );
  }

  @override
  void onStreamEvent(Uri uri, Object? json, AIStreamAccumulator acc) {
    final root = AdapterUtils.map(json);
    if (root == null) return;
    acc.events++;
    final r = parseResponse(uri, root);
    if (r.text != null) acc.text.write(r.text);
    acc.model ??= r.model;
    if (root['done'] == true) {
      acc.usage = r.usage ?? acc.usage;
      acc.finishReason = r.finishReason ?? 'stop';
    }
  }
}
