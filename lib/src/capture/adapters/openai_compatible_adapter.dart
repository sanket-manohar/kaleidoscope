import '../provider_adapter.dart';
import '../usage_extractors.dart';

/// OpenAI and any OpenAI-compatible API, matched by URL path so it works on
/// any host (Azure, Groq, Mistral, DeepSeek, OpenRouter, xAI, Together,
/// Fireworks, Perplexity, vLLM, LM Studio, LiteLLM, Helicone gateway...).
class OpenAICompatibleAdapter extends AIProviderAdapter {
  const OpenAICompatibleAdapter();

  static const _paths = [
    '/chat/completions',
    '/completions',
    '/responses',
    '/embeddings',
    '/images/generations',
    '/audio/transcriptions',
    '/audio/speech',
    '/moderations',
  ];

  static const _hostNames = {
    'api.openai.com': 'openai',
    'openai.azure.com': 'azure-openai',
    'api.groq.com': 'groq',
    'api.mistral.ai': 'mistral',
    'api.deepseek.com': 'deepseek',
    'api.together.xyz': 'together',
    'openrouter.ai': 'openrouter',
    'api.x.ai': 'xai',
    'api.perplexity.ai': 'perplexity',
    'api.fireworks.ai': 'fireworks',
    'oai.helicone.ai': 'openai',
    'api.cerebras.ai': 'cerebras',
    'generativelanguage.googleapis.com': 'gemini',
  };

  @override
  String get provider => 'openai';

  @override
  bool matches(Uri uri) {
    final path = uri.path;
    if (path.contains('/api/chat') || path.contains('/api/generate')) {
      return false; // Ollama native
    }
    return _paths.any((p) => path.endsWith(p) || path.contains('$p/'));
  }

  @override
  String providerFor(Uri uri) {
    final host = uri.host.toLowerCase();
    for (final e in _hostNames.entries) {
      if (host == e.key || host.endsWith('.${e.key}')) return e.value;
    }
    if (uri.port == 11434) return 'ollama';
    if (uri.port == 1234) return 'lmstudio';
    if (host == 'localhost' || host == '127.0.0.1' || host == '10.0.2.2') {
      return 'local';
    }
    return host.isEmpty ? provider : host;
  }

  String _operation(Uri uri) {
    final p = uri.path;
    if (p.contains('/embeddings')) return 'embedding';
    if (p.contains('/images/')) return 'image';
    if (p.contains('/audio/')) return 'audio';
    if (p.contains('/moderations')) return 'moderation';
    if (p.contains('/responses')) return 'responses';
    if (p.endsWith('/completions') && !p.endsWith('/chat/completions')) {
      return 'completion';
    }
    return 'chat';
  }

  @override
  AIRequestInfo parseRequest(Uri uri, Map<String, Object?>? body) {
    final params = AdapterUtils.pick(body, const [
      'temperature',
      'top_p',
      'max_tokens',
      'max_completion_tokens',
      'max_output_tokens',
      'n',
      'presence_penalty',
      'frequency_penalty',
      'seed',
      'stop',
      'response_format',
      'reasoning_effort',
      'reasoning',
      'tool_choice',
      'parallel_tool_calls',
      'service_tier',
      'user',
      'dimensions',
      'size',
      'quality',
    ]);
    final tools = AdapterUtils.list(body?['tools']);
    if (tools.isNotEmpty) params['tools_count'] = tools.length;

    final text = StringBuffer();
    if (body?['instructions'] is String) text.writeln(body!['instructions']);
    for (final m in AdapterUtils.list(body?['messages'])) {
      final mm = AdapterUtils.map(m);
      if (mm == null) continue;
      final t = AdapterUtils.contentText(mm['content']);
      if (t.isNotEmpty) text.writeln('[${mm['role'] ?? 'user'}] $t');
    }
    final input = body?['input'] ?? body?['prompt'];
    if (input is String) {
      text.writeln(input);
    } else if (input is List) {
      for (final item in input) {
        final mm = AdapterUtils.map(item);
        if (mm != null) {
          final t = AdapterUtils.contentText(mm['content'] ?? mm['text']);
          if (t.isNotEmpty) text.writeln('[${mm['role'] ?? 'user'}] $t');
        } else if (item is String) {
          text.writeln(item);
        }
      }
    }
    return AIRequestInfo(
      model: body?['model'] as String? ?? _azureDeployment(uri),
      parameters: params,
      promptText: text.isEmpty ? null : text.toString().trim(),
      stream: body?['stream'] == true,
      operation: _operation(uri),
    );
  }

  String? _azureDeployment(Uri uri) {
    final i = uri.pathSegments.indexOf('deployments');
    return i >= 0 && i + 1 < uri.pathSegments.length
        ? uri.pathSegments[i + 1]
        : null;
  }

  @override
  AIResponseInfo parseResponse(Uri uri, Object? json) {
    final root = AdapterUtils.map(json);
    final info = AIResponseInfo(
      model: root?['model'] as String?,
      usage: UsageExtractors.openAI(root),
      responseId: root?['id'] as String?,
    );
    final choices = AdapterUtils.list(root?['choices']);
    if (choices.isNotEmpty) {
      final c = AdapterUtils.map(choices.first);
      final msg = AdapterUtils.map(c?['message']);
      info.text = msg != null
          ? AdapterUtils.contentText(msg['content'])
          : c?['text'] as String?;
      info.finishReason = c?['finish_reason'] as String?;
    } else if (root?['output_text'] is String) {
      info.text = root!['output_text'] as String;
    } else if (root?['output'] is List) {
      final buf = StringBuffer();
      for (final o in root!['output'] as List) {
        final om = AdapterUtils.map(o);
        for (final c in AdapterUtils.list(om?['content'])) {
          final t = AdapterUtils.map(c)?['text'];
          if (t is String) buf.write(t);
        }
      }
      if (buf.isNotEmpty) info.text = buf.toString();
      info.finishReason = root['status'] as String?;
    }
    return info;
  }

  @override
  void onStreamEvent(Uri uri, Object? json, AIStreamAccumulator acc) {
    final root = AdapterUtils.map(json);
    if (root == null) return;
    acc.events++;
    final type = root['type'];
    if (type is String && type.startsWith('response.')) {
      // Responses API events.
      if (type == 'response.output_text.delta' && root['delta'] is String) {
        acc.text.write(root['delta']);
      }
      final resp = AdapterUtils.map(root['response']);
      if (resp != null) {
        acc.model ??= resp['model'] as String?;
        acc.responseId ??= resp['id'] as String?;
        final u = UsageExtractors.openAI({'usage': resp['usage']});
        if (u != null) acc.usage = u;
        if (type == 'response.completed') acc.finishReason = 'completed';
      }
      return;
    }
    acc.model ??= root['model'] as String?;
    acc.responseId ??= root['id'] as String?;
    for (final c in AdapterUtils.list(root['choices'])) {
      final cm = AdapterUtils.map(c);
      final delta = AdapterUtils.map(cm?['delta']);
      final content = delta?['content'];
      if (content is String) acc.text.write(content);
      if (cm?['text'] is String) acc.text.write(cm!['text']);
      final fr = cm?['finish_reason'];
      if (fr is String) acc.finishReason = fr;
    }
    final u = UsageExtractors.openAI(root);
    if (u != null) acc.usage = u;
  }
}
