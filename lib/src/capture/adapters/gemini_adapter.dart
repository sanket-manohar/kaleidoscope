import '../provider_adapter.dart';
import '../usage_extractors.dart';

/// Google Gemini API and Vertex AI (`:generateContent`,
/// `:streamGenerateContent`, `:embedContent`).
class GeminiAdapter extends AIProviderAdapter {
  const GeminiAdapter();

  static final _modelRe = RegExp(r'models/([^:/]+)');

  @override
  String get provider => 'gemini';

  @override
  bool matches(Uri uri) {
    final p = uri.path;
    return p.contains(':generateContent') ||
        p.contains(':streamGenerateContent') ||
        p.contains(':embedContent') ||
        p.contains(':batchEmbedContents');
  }

  @override
  String providerFor(Uri uri) =>
      uri.host.contains('aiplatform') ? 'vertex-ai' : 'gemini';

  @override
  bool isStreaming(Uri uri, Map<String, Object?>? body) =>
      uri.path.contains(':streamGenerateContent');

  @override
  AIRequestInfo parseRequest(Uri uri, Map<String, Object?>? body) {
    final cfg = AdapterUtils.map(body?['generationConfig']);
    final params = AdapterUtils.pick(cfg, const [
      'temperature',
      'topP',
      'topK',
      'maxOutputTokens',
      'candidateCount',
      'stopSequences',
      'responseMimeType',
      'thinkingConfig',
      'seed',
    ]);
    final tools = AdapterUtils.list(body?['tools']);
    if (tools.isNotEmpty) params['tools_count'] = tools.length;
    final text = StringBuffer();
    final sys = AdapterUtils.map(body?['systemInstruction']);
    final sysText = _parts(sys?['parts']);
    if (sysText.isNotEmpty) text.writeln('[system] $sysText');
    for (final c in AdapterUtils.list(body?['contents'])) {
      final cm = AdapterUtils.map(c);
      final t = _parts(cm?['parts']);
      if (t.isNotEmpty) text.writeln('[${cm?['role'] ?? 'user'}] $t');
    }
    final p = uri.path;
    return AIRequestInfo(
      model: _modelRe.firstMatch(p)?.group(1),
      parameters: params,
      promptText: text.isEmpty ? null : text.toString().trim(),
      stream: isStreaming(uri, body),
      operation: p.contains('mbedContent') ? 'embedding' : 'chat',
    );
  }

  String _parts(Object? parts) => AdapterUtils.list(
    parts,
  ).map((p) => AdapterUtils.map(p)?['text']).whereType<String>().join('\n');

  @override
  AIResponseInfo parseResponse(Uri uri, Object? json) {
    final root = AdapterUtils.map(json);
    final cands = AdapterUtils.list(root?['candidates']);
    final first = cands.isEmpty ? null : AdapterUtils.map(cands.first);
    final text = _parts(AdapterUtils.map(first?['content'])?['parts']);
    return AIResponseInfo(
      model: root?['modelVersion'] as String?,
      usage: UsageExtractors.gemini(root),
      text: text.isEmpty ? null : text,
      finishReason: first?['finishReason'] as String?,
      responseId: root?['responseId'] as String?,
    );
  }

  @override
  void onStreamEvent(Uri uri, Object? json, AIStreamAccumulator acc) {
    if (json is List) {
      for (final e in json) {
        onStreamEvent(uri, e, acc);
      }
      return;
    }
    final r = parseResponse(uri, json);
    acc.events++;
    if (r.text != null) acc.text.write(r.text);
    acc.model ??= r.model;
    acc.responseId ??= r.responseId;
    acc.finishReason = r.finishReason ?? acc.finishReason;
    // Each chunk carries cumulative usage; the last one wins.
    if (r.usage != null) acc.usage = r.usage;
  }
}
