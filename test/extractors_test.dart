import 'package:kaleidoscope/kaleidoscope.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('OpenAI chat usage separates cached and reasoning tokens', () {
    final u = UsageExtractors.openAI({
      'usage': {
        'prompt_tokens': 1000,
        'completion_tokens': 200,
        'total_tokens': 1200,
        'prompt_tokens_details': {'cached_tokens': 400},
        'completion_tokens_details': {'reasoning_tokens': 50},
      },
    })!;
    expect(u.inputTokens, 600);
    expect(u.cachedInputTokens, 400);
    expect(u.outputTokens, 200);
    expect(u.reasoningTokens, 50);
    expect(u.totalTokens, 1200);
  });

  test('OpenAI Responses API usage', () {
    final u = UsageExtractors.openAI({
      'usage': {
        'input_tokens': 30,
        'output_tokens': 10,
        'input_tokens_details': {'cached_tokens': 10},
      },
    })!;
    expect(u.inputTokens, 20);
    expect(u.cachedInputTokens, 10);
    expect(u.outputTokens, 10);
  });

  test('Anthropic usage with cache read and write', () {
    final u = UsageExtractors.anthropic({
      'usage': {
        'input_tokens': 12,
        'output_tokens': 40,
        'cache_read_input_tokens': 900,
        'cache_creation_input_tokens': 100,
      },
    })!;
    expect(u.inputTokens, 12);
    expect(u.cachedInputTokens, 900);
    expect(u.cacheWriteTokens, 100);
    expect(u.totalTokens, 1052);
  });

  test('Gemini usage counts thoughts as output', () {
    final u = UsageExtractors.gemini({
      'usageMetadata': {
        'promptTokenCount': 100,
        'cachedContentTokenCount': 40,
        'candidatesTokenCount': 20,
        'thoughtsTokenCount': 30,
        'totalTokenCount': 150,
      },
    })!;
    expect(u.inputTokens, 60);
    expect(u.cachedInputTokens, 40);
    expect(u.outputTokens, 50);
    expect(u.reasoningTokens, 30);
  });

  test('Ollama and Cohere', () {
    expect(
      UsageExtractors.ollama({
        'prompt_eval_count': 5,
        'eval_count': 7,
      })!.outputTokens,
      7,
    );
    expect(
      UsageExtractors.cohere({
        'usage': {
          'tokens': {'input_tokens': 3, 'output_tokens': 4},
        },
      })!.inputTokens,
      3,
    );
  });

  test('auto detects shapes', () {
    expect(
      UsageExtractors.auto({
        'usageMetadata': {'promptTokenCount': 2},
      })!.inputTokens,
      2,
    );
    expect(UsageExtractors.auto({'eval_count': 9})!.outputTokens, 9);
    expect(
      UsageExtractors.auto({
        'usage': {'prompt_tokens': 3, 'completion_tokens': 1},
      })!.outputTokens,
      1,
    );
    expect(
      UsageExtractors.auto({
        'usage': {'input_tokens': 3, 'output_tokens': 1},
      })!.inputTokens,
      3,
    );
    expect(UsageExtractors.auto({'nothing': true}), isNull);
    expect(UsageExtractors.auto('not a map'), isNull);
  });

  test('token estimator', () {
    expect(TokenEstimator.estimate(''), 0);
    expect(TokenEstimator.estimate('abcd' * 25), 25);
    expect(TokenEstimator.estimate('你好世界'), 4);
  });

  test('redactors scrub PII', () {
    final out = Redactors.applyAll(
      'mail me at a.b@example.com or +1 (555) 123-4567, key sk-abcdefghijklmnopqrstuv',
      Redactors.defaults,
    );
    expect(out, isNot(contains('example.com')));
    expect(out, isNot(contains('555')));
    expect(out, isNot(contains('sk-abc')));
    expect(out, contains('[EMAIL]'));
  });
}
