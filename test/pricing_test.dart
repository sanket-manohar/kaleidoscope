import 'dart:convert';

import 'package:kaleidoscope/kaleidoscope.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('longest pattern wins', () {
    final p = PricingTable.withDefaults();
    expect(p.lookup('gpt-4o-mini-2024-07-18')!.inputPerMillion, 0.15);
    expect(p.lookup('gpt-4o-2024-08-06')!.inputPerMillion, 2.5);
    expect(p.lookup('claude-opus-5-5')!.inputPerMillion, 4);
    expect(p.lookup('claude-opus-5')!.inputPerMillion, 5);
    expect(p.lookup('claude-haiku-5-5')!.outputPerMillion, 0.5);
    expect(p.lookup('totally-unknown'), isNull);
  });

  test('vendor prefixes and provider scope', () {
    final p = PricingTable.withDefaults();
    expect(p.lookup('openai/gpt-4o-mini')!.inputPerMillion, 0.15);
    expect(p.lookup('anthropic.claude-sonnet-5-5')!.inputPerMillion, 2);
    expect(p.lookup('llama3.2', provider: 'ollama')!.inputPerMillion, 0);
    expect(p.lookup('llama3.2'), isNull);
  });

  test('cost uses cache discount', () {
    final p = PricingTable({
      'm': const ModelPrice(
        inputPerMillion: 10,
        outputPerMillion: 20,
        cachedInputPerMillion: 1,
        currency: 'EUR',
      ),
    });
    final c = p.costFor(
      'm',
      const AITokenUsage(
        inputTokens: 1000000,
        outputTokens: 500000,
        cachedInputTokens: 1000000,
      ),
    );
    expect(c.input, 10);
    expect(c.output, 10);
    expect(c.cached, 1);
    expect(c.total, 21);
    expect(c.currency, 'EUR');
    expect(p.costFor('nope', AITokenUsage.zero).priced, isFalse);
  });

  test('runtime and remote updates', () async {
    final p = PricingTable();
    var changes = 0;
    p.addListener(() => changes++);
    p.setPrice(
      'my-model*',
      const ModelPrice(inputPerMillion: 1, outputPerMillion: 2),
    );
    expect(p.lookup('my-model-v2')!.outputPerMillion, 2);
    final client = MockClient(
      (req) async => http.Response(
        jsonEncode({
          'version': '2026-11',
          'currency': 'INR',
          'models': {
            'my-model*': {'input': 80, 'output': 160},
          },
        }),
        200,
      ),
    );
    expect(
      await p.loadFromUrl(Uri.parse('https://x/prices.json'), client: client),
      isTrue,
    );
    expect(p.lookup('my-model-v2')!.inputPerMillion, 80);
    expect(p.lookup('my-model-v2')!.currency, 'INR');
    expect(p.version, '2026-11');
    final bad = MockClient((req) async => http.Response('oops', 500));
    expect(
      await p.loadFromUrl(Uri.parse('https://x/prices.json'), client: bad),
      isFalse,
    );
    expect(p.lookup('my-model-v2')!.inputPerMillion, 80);
    expect(changes, 2);
    final roundTrip = PricingTable()..loadJson(jsonDecode(p.toJsonString()));
    expect(roundTrip.lookup('my-model-x')!.inputPerMillion, 80);
  });
}
