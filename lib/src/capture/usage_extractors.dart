import '../models/ai_usage_record.dart';

int _i(Object? v) => v is num ? v.toInt() : (int.tryParse('$v') ?? 0);
Map<String, Object?>? _m(Object? v) =>
    v is Map ? v.cast<String, Object?>() : null;

/// Ready-made helpers that read token usage from provider response JSON.
///
/// Use them with [KaleidoscopeTracker.track] when you call an SDK directly:
/// `usage: (res) => UsageExtractors.openAI(res.toJson())`.
abstract final class UsageExtractors {
  /// OpenAI and every OpenAI-compatible API (Chat Completions, Responses,
  /// Embeddings): Azure, Groq, Mistral, DeepSeek, Together, OpenRouter, xAI,
  /// Perplexity, Fireworks, LM Studio, vLLM, Ollama `/v1`...
  static AITokenUsage? openAI(Object? json) {
    final root = _m(json);
    if (root == null) return null;
    final u = _m(root['usage']) ?? _m(_m(root['response'])?['usage']);
    if (u == null) return null;
    if (u.containsKey('prompt_tokens') || u.containsKey('completion_tokens')) {
      final prompt = _i(u['prompt_tokens']);
      final cached = _i(_m(u['prompt_tokens_details'])?['cached_tokens']);
      final reasoning = _i(
        _m(u['completion_tokens_details'])?['reasoning_tokens'],
      );
      return AITokenUsage(
        inputTokens: (prompt - cached).clamp(0, prompt),
        cachedInputTokens: cached,
        outputTokens: _i(u['completion_tokens']),
        reasoningTokens: reasoning,
        totalTokens: u['total_tokens'] == null ? null : _i(u['total_tokens']),
      );
    }
    if (u.containsKey('input_tokens') || u.containsKey('output_tokens')) {
      final input = _i(u['input_tokens']);
      final cached = _i(_m(u['input_tokens_details'])?['cached_tokens']);
      return AITokenUsage(
        inputTokens: (input - cached).clamp(0, input),
        cachedInputTokens: cached,
        outputTokens: _i(u['output_tokens']),
        reasoningTokens: _i(
          _m(u['output_tokens_details'])?['reasoning_tokens'],
        ),
        totalTokens: u['total_tokens'] == null ? null : _i(u['total_tokens']),
      );
    }
    return null;
  }

  /// Anthropic Messages API (`usage` on a message, or a stream event).
  /// `input_tokens` already excludes cache reads and writes.
  static AITokenUsage? anthropic(Object? json) {
    final root = _m(json);
    if (root == null) return null;
    final u = _m(root['usage']) ?? _m(_m(root['message'])?['usage']);
    if (u == null) return null;
    return AITokenUsage(
      inputTokens: _i(u['input_tokens']),
      outputTokens: _i(u['output_tokens']),
      cachedInputTokens: _i(u['cache_read_input_tokens']),
      cacheWriteTokens: _i(u['cache_creation_input_tokens']),
    );
  }

  /// Google Gemini / Vertex AI (`usageMetadata`). Thinking tokens are billed
  /// as output, so they are added to output and also reported as reasoning.
  static AITokenUsage? gemini(Object? json) {
    final root = _m(json);
    final u = _m(root?['usageMetadata']);
    if (u == null) return null;
    final prompt = _i(u['promptTokenCount']);
    final cached = _i(u['cachedContentTokenCount']);
    final thoughts = _i(u['thoughtsTokenCount']);
    return AITokenUsage(
      inputTokens: (prompt - cached).clamp(0, prompt),
      cachedInputTokens: cached,
      outputTokens: _i(u['candidatesTokenCount']) + thoughts,
      reasoningTokens: thoughts,
      totalTokens: u['totalTokenCount'] == null
          ? null
          : _i(u['totalTokenCount']),
    );
  }

  /// Ollama native API (`/api/chat`, `/api/generate`).
  static AITokenUsage? ollama(Object? json) {
    final root = _m(json);
    if (root == null ||
        (!root.containsKey('prompt_eval_count') &&
            !root.containsKey('eval_count'))) {
      return null;
    }
    return AITokenUsage(
      inputTokens: _i(root['prompt_eval_count']),
      outputTokens: _i(root['eval_count']),
    );
  }

  /// Cohere v1/v2 chat.
  static AITokenUsage? cohere(Object? json) {
    final root = _m(json);
    if (root == null) return null;
    final usage =
        _m(root['usage']) ??
        _m(_m(root['delta'])?['usage']) ??
        _m(root['meta']);
    final t = _m(usage?['tokens']) ?? _m(usage?['billed_units']);
    if (t == null) return null;
    return AITokenUsage(
      inputTokens: _i(t['input_tokens']),
      outputTokens: _i(t['output_tokens']),
    );
  }

  /// Tries every known shape. Use for unknown or custom gateways.
  static AITokenUsage? auto(Object? json) {
    final root = _m(json);
    if (root == null) return null;
    if (root.containsKey('usageMetadata')) return gemini(root);
    if (root.containsKey('prompt_eval_count') ||
        root.containsKey('eval_count')) {
      return ollama(root);
    }
    final u = _m(root['usage']) ?? _m(_m(root['message'])?['usage']);
    if (u != null) {
      if (u.containsKey('cache_read_input_tokens') ||
          u.containsKey('cache_creation_input_tokens')) {
        return anthropic(root);
      }
      if (u.containsKey('tokens') || u.containsKey('billed_units')) {
        return cohere(root);
      }
      final o = openAI(root);
      if (o != null) return o;
      if (u.containsKey('input_tokens')) return anthropic(root);
    }
    if (root.containsKey('meta')) return cohere(root);
    return openAI(root);
  }
}
