import 'dart:convert';

import 'package:kaleidoscope/kaleidoscope.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'helpers.dart';

void main() {
  test('callback sink receives batches without prompt text', () async {
    final t = await newTracker(promptStorage: PromptStorageMode.full);
    final got = <AIUsageRecord>[];
    t.addSink(CallbackSink('cb', (b) async => got.addAll(b), batchSize: 2));
    t.record(provider: 'p', model: 'm', prompt: 'secret');
    t.record(provider: 'p', model: 'm', prompt: 'secret');
    await t.flush();
    expect(got, hasLength(2));
    expect(got.first.prompt, isNull);
    final stored = await t.records();
    expect(stored.first.prompt, 'secret');
    await t.dispose();
  });

  test('failed sends are kept, persisted and retried', () async {
    final store = InMemoryUsageStore();
    final t = await newTracker(store: store);
    var fail = true;
    final got = <AIUsageRecord>[];
    final sink = CallbackSink('flaky', (b) async {
      if (fail) throw StateError('offline');
      got.addAll(b);
    });
    t.addSink(sink);
    t.record(provider: 'p', model: 'm');
    await t.flush();
    expect(got, isEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final saved = await store.readValue('sink_queue.flaky');
    expect(jsonDecode(saved!) as List, hasLength(1));
    // A new tracker (app restart) picks up the queue.
    final t2 = await newTracker(store: store);
    t2.addSink(CallbackSink('flaky', (b) async => got.addAll(b)));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await t2.flush();
    fail = false;
    expect(got, hasLength(1));
    t.removeSink(sink);
    await t.dispose();
    await t2.dispose();
  });

  test('PostHog, Mixpanel, OTel and server payloads', () async {
    final bodies = <String, Object?>{};
    final client = MockClient((req) async {
      bodies[req.url.toString()] = jsonDecode(req.body);
      return http.Response('{}', 200);
    });
    final r = rec(
      at: DateTime.utc(2026, 11, 1),
      context: const AIUsageContext(module: 'chat', userId: 'u1'),
    );
    await PostHogSink(apiKey: 'phc', client: client).send([r]);
    await MixpanelSink(projectToken: 'mp', client: client).send([r]);
    await OpenTelemetrySink.langfuse(
      publicKey: 'pk',
      secretKey: 'sk',
      client: client,
    ).send([r]);
    await ServerSyncSink(
      endpoint: Uri.parse('https://api.example.com/ai-usage'),
      appId: 'demo',
      client: client,
    ).send([r]);
    final ph = bodies['https://us.i.posthog.com/batch/'] as Map;
    final ev = (ph['batch'] as List).single as Map;
    expect(ev['event'], r'$ai_generation');
    expect(ev['distinct_id'], 'u1');
    expect((ev['properties'] as Map)[r'$ai_model'], 'gpt-4o-mini');
    final mp = (bodies['https://api.mixpanel.com/track'] as List).single as Map;
    expect((mp['properties'] as Map)['module'], 'chat');
    final otel =
        bodies['https://cloud.langfuse.com/api/public/otel/v1/traces'] as Map;
    final span =
        (((otel['resourceSpans'] as List).single as Map)['scopeSpans'] as List)
                .single
            as Map;
    final attrs = ((span['spans'] as List).single as Map)['attributes'] as List;
    expect(
      attrs.any((a) => (a as Map)['key'] == 'gen_ai.usage.input_tokens'),
      isTrue,
    );
    final server = bodies['https://api.example.com/ai-usage'] as Map;
    expect(server['app'], 'demo');
    expect((server['records'] as List), hasLength(1));
  });

  test('non-2xx counts as failure', () async {
    final client = MockClient((req) async => http.Response('nope', 503));
    await expectLater(
      ServerSyncSink(
        endpoint: Uri.parse('https://x/y'),
        client: client,
      ).send([rec(at: DateTime.now())]),
      throwsA(isA<http.ClientException>()),
    );
  });
}
