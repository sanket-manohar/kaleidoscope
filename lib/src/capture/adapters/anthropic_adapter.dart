import '../../models/ai_usage_record.dart';
import '../provider_adapter.dart';
import '../usage_extractors.dart';

/// Anthropic Messages API (`/v1/messages`), including streaming events
/// (`message_start`, `content_block_delta`, `message_delta`).
class AnthropicAdapter extends AIProviderAdapter {
  const AnthropicAdapter();

  @override
  String get provider => 'anthropic';

  @override
  bool matches(Uri uri) =>
      uri.path.endsWith('/v1/messages') ||
      (uri.host.endsWith('anthropic.com') && uri.path.contains('/messages'));

  @override
  AIRequestInfo parseRequest(Uri uri, Map<String, Object?>? body) {
    final params = AdapterUtils.pick(body, const [
      'max_tokens',
      'temperature',
      'top_p',
      'top_k',
      'stop_sequences',
      'thinking',
      'output_config',
      'tool_choice',
      'service_tier',
      'speed',
    ]);
    final tools = AdapterUtils.list(body?['tools']);
    if (tools.isNotEmpty) params['tools_count'] = tools.length;
    final text = StringBuffer();
    final system = body?['system'];
    final sys = AdapterUtils.contentText(system);
    if (sys.isNotEmpty) text.writeln('[system] $sys');
    for (final m in AdapterUtils.list(body?['messages'])) {
      final mm = AdapterUtils.map(m);
      final t = AdapterUtils.contentText(mm?['content']);
      if (t.isNotEmpty) text.writeln('[${mm?['role'] ?? 'user'}] $t');
    }
    return AIRequestInfo(
      model: body?['model'] as String?,
      parameters: params,
      promptText: text.isEmpty ? null : text.toString().trim(),
      stream: body?['stream'] == true,
    );
  }

  @override
  AIResponseInfo parseResponse(Uri uri, Object? json) {
    final root = AdapterUtils.map(json);
    final buf = StringBuffer();
    for (final c in AdapterUtils.list(root?['content'])) {
      final cm = AdapterUtils.map(c);
      if (cm?['type'] == 'text' && cm?['text'] is String) {
        buf.write(cm!['text']);
      }
    }
    return AIResponseInfo(
      model: root?['model'] as String?,
      usage: UsageExtractors.anthropic(root),
      text: buf.isEmpty ? null : buf.toString(),
      finishReason: root?['stop_reason'] as String?,
      responseId: root?['id'] as String?,
    );
  }

  @override
  void onStreamEvent(Uri uri, Object? json, AIStreamAccumulator acc) {
    final root = AdapterUtils.map(json);
    if (root == null) return;
    acc.events++;
    switch (root['type']) {
      case 'message_start':
        final msg = AdapterUtils.map(root['message']);
        acc.model ??= msg?['model'] as String?;
        acc.responseId ??= msg?['id'] as String?;
        acc.usage = UsageExtractors.anthropic(msg) ?? acc.usage;
      case 'content_block_delta':
        final d = AdapterUtils.map(root['delta']);
        if (d?['type'] == 'text_delta' && d?['text'] is String) {
          acc.text.write(d!['text']);
        }
      case 'message_delta':
        final d = AdapterUtils.map(root['delta']);
        if (d?['stop_reason'] is String) {
          acc.finishReason = d!['stop_reason'] as String;
        }
        final u = AdapterUtils.map(root['usage']);
        if (u != null) {
          // message_delta usage is cumulative; keep start values when absent.
          final prev = acc.usage ?? AITokenUsage.zero;
          int pick(String k, int fallback) =>
              u[k] is num ? (u[k] as num).toInt() : fallback;
          acc.usage = AITokenUsage(
            inputTokens: pick('input_tokens', prev.inputTokens),
            outputTokens: pick('output_tokens', prev.outputTokens),
            cachedInputTokens: pick(
              'cache_read_input_tokens',
              prev.cachedInputTokens,
            ),
            cacheWriteTokens: pick(
              'cache_creation_input_tokens',
              prev.cacheWriteTokens,
            ),
          );
        }
    }
  }
}
