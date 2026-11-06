import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:kaleidoscope/kaleidoscope.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'helpers.dart';

final openAIUrl = Uri.parse('https://api.openai.com/v1/chat/completions');

http.Response openAIResponse() => http.Response(
  jsonEncode({
    'id': 'chatcmpl-1',
    'model': 'gpt-4o-mini-2024-07-18',
    'choices': [
      {
        'message': {
          'role': 'assistant',
          'content': 'Hello! Email me at x@y.com',
        },
        'finish_reason': 'stop',
      },
    ],
    'usage': {'prompt_tokens': 12, 'completion_tokens': 8, 'total_tokens': 20},
  }),
  200,
  headers: {'content-type': 'application/json'},
);

String chatBody({bool stream = false}) => jsonEncode({
  'model': 'gpt-4o-mini',
  'temperature': 0.3,
  'max_tokens': 100,
  'stream': stream,
  'messages': [
    {'role': 'system', 'content': 'Be brief'},
    {'role': 'user', 'content': 'Hi, I am bob@corp.com'},
  ],
});

void main() {
  group('http client', () {
    test('records an OpenAI call with tags, params and cost', () async {
      final t = await newTracker();
      final client = t.httpClient(MockClient((_) async => openAIResponse()));
      final res = await KaleidoscopeTracker.runWithContext(
        const AIUsageContext(
          module: 'support',
          page: 'chat',
          section: 'composer',
        ),
        () => client.post(openAIUrl, body: chatBody()),
      );
      expect(jsonDecode(res.body)['id'], 'chatcmpl-1'); // response untouched
      await t.flush();
      final r = (await t.records()).single;
      expect(r.provider, 'openai');
      expect(r.model, 'gpt-4o-mini-2024-07-18');
      expect(r.usage.inputTokens, 12);
      expect(r.usage.outputTokens, 8);
      expect(r.parameters['temperature'], 0.3);
      expect(r.context.module, 'support');
      expect(r.context.section, 'composer');
      expect(r.finishReason, 'stop');
      expect(r.cost.priced, isTrue);
      expect(r.cost.total, closeTo((12 * 0.15 + 8 * 0.6) / 1e6, 1e-12));
      expect(r.prompt, isNull, reason: 'metadata only by default');
      expect(r.latencyMs, isNotNull);
      expect(r.source, AICaptureSource.httpClient);
      await t.dispose();
    });

    test('prompt storage modes', () async {
      for (final mode in PromptStorageMode.values) {
        final t = await newTracker(promptStorage: mode);
        final client = t.httpClient(MockClient((_) async => openAIResponse()));
        await client.post(openAIUrl, body: chatBody());
        await t.flush();
        final r = (await t.records()).single;
        switch (mode) {
          case PromptStorageMode.metadataOnly:
            expect(r.prompt, isNull);
            expect(r.response, isNull);
          case PromptStorageMode.redacted:
            expect(r.prompt, contains('[EMAIL]'));
            expect(r.prompt, isNot(contains('bob@corp.com')));
            expect(r.response, contains('[EMAIL]'));
          case PromptStorageMode.full:
            expect(r.prompt, contains('bob@corp.com'));
            expect(r.prompt, contains('[system] Be brief'));
        }
        await t.dispose();
      }
    });

    test('non-AI requests pass through untracked', () async {
      final t = await newTracker();
      final client = t.httpClient(
        MockClient((_) async => http.Response('{"ok":true}', 200)),
      );
      await client.get(Uri.parse('https://example.com/api/users'));
      await t.flush();
      expect(await t.records(), isEmpty);
      await t.dispose();
    });

    test('HTTP errors are recorded with the provider message', () async {
      final t = await newTracker();
      final client = t.httpClient(
        MockClient(
          (_) async => http.Response(
            jsonEncode({
              'error': {'message': 'Rate limit reached', 'type': 'rate_limit'},
            }),
            429,
          ),
        ),
      );
      final res = await client.post(openAIUrl, body: chatBody());
      expect(res.statusCode, 429);
      await t.flush();
      final r = (await t.records()).single;
      expect(r.status, AICallStatus.error);
      expect(r.httpStatus, 429);
      expect(r.errorMessage, 'Rate limit reached');
      await t.dispose();
    });

    test('network exceptions are recorded and rethrown', () async {
      final t = await newTracker();
      final client = t.httpClient(
        MockClient((_) async => throw http.ClientException('offline')),
      );
      await expectLater(
        client.post(openAIUrl, body: chatBody()),
        throwsA(isA<http.ClientException>()),
      );
      await t.flush();
      expect((await t.records()).single.status, AICallStatus.error);
      await t.dispose();
    });

    test('OpenAI SSE stream with usage, ttft and text', () async {
      final t = await newTracker(promptStorage: PromptStorageMode.full);
      final body = sse([
        {
          'id': 's1',
          'model': 'gpt-4o-mini',
          'choices': [
            {
              'delta': {'content': 'Hel'},
            },
          ],
        },
        {
          'id': 's1',
          'model': 'gpt-4o-mini',
          'choices': [
            {
              'delta': {'content': 'lo'},
              'finish_reason': 'stop',
            },
          ],
        },
        {
          'id': 's1',
          'model': 'gpt-4o-mini',
          'choices': [],
          'usage': {'prompt_tokens': 9, 'completion_tokens': 2},
        },
        '[DONE]',
      ]);
      final client = t.httpClient(
        MockClient.streaming((req, _) async {
          final bytes = utf8.encode(body);
          // Deliver in awkward chunks to test line reassembly.
          final chunks = <List<int>>[];
          for (var i = 0; i < bytes.length; i += 7) {
            chunks.add(
              bytes.sublist(i, i + 7 > bytes.length ? bytes.length : i + 7),
            );
          }
          return http.StreamedResponse(
            Stream.fromIterable(chunks),
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        }),
      );
      final req = http.Request('POST', openAIUrl)
        ..body = chatBody(stream: true);
      final res = await client.send(req);
      final text = await res.stream.bytesToString();
      expect(text, body);
      await t.flush();
      final r = (await t.records()).single;
      expect(r.streamed, isTrue);
      expect(r.response, 'Hello');
      expect(r.usage.inputTokens, 9);
      expect(r.usage.outputTokens, 2);
      expect(r.usage.estimated, isFalse);
      expect(r.timeToFirstTokenMs, isNotNull);
      await t.dispose();
    });

    test('stream without usage falls back to estimate', () async {
      final t = await newTracker();
      final body = sse([
        {
          'model': 'gpt-4o-mini',
          'choices': [
            {
              'delta': {'content': 'abcdefgh'},
            },
          ],
        },
        '[DONE]',
      ]);
      final client = t.httpClient(
        MockClient.streaming(
          (req, _) async => http.StreamedResponse(
            Stream.value(utf8.encode(body)),
            200,
            headers: {'content-type': 'text/event-stream'},
          ),
        ),
      );
      final res = await client.send(
        http.Request('POST', openAIUrl)..body = chatBody(stream: true),
      );
      await res.stream.drain<void>();
      await t.flush();
      final r = (await t.records()).single;
      expect(r.usage.estimated, isTrue);
      expect(r.usage.outputTokens, 2);
      await t.dispose();
    });

    test('injectStreamUsageOption adds stream_options', () async {
      final t = await newTracker(injectStreamUsageOption: true);
      Map<String, Object?>? sent;
      final client = t.httpClient(
        MockClient((req) async {
          sent = jsonDecode(req.body) as Map<String, Object?>;
          return http.Response(
            sse(['[DONE]']),
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        }),
      );
      await client.post(openAIUrl, body: chatBody(stream: true));
      expect((sent!['stream_options'] as Map)['include_usage'], isTrue);
      await t.dispose();
    });

    test('Anthropic stream events', () async {
      final t = await newTracker(promptStorage: PromptStorageMode.full);
      final body = [
        'event: message_start',
        'data: ${jsonEncode({
          'type': 'message_start',
          'message': {
            'id': 'msg_1',
            'model': 'claude-sonnet-5-5',
            'usage': {'input_tokens': 25, 'output_tokens': 1, 'cache_read_input_tokens': 1000},
          },
        })}',
        '',
        'event: content_block_delta',
        'data: ${jsonEncode({
          'type': 'content_block_delta',
          'index': 0,
          'delta': {'type': 'text_delta', 'text': 'Hi there'},
        })}',
        '',
        'event: message_delta',
        'data: ${jsonEncode({
          'type': 'message_delta',
          'delta': {'stop_reason': 'end_turn'},
          'usage': {'output_tokens': 15},
        })}',
        '',
        'event: message_stop',
        'data: {"type":"message_stop"}',
        '',
      ].join('\n');
      final client = t.httpClient(
        MockClient(
          (_) async => http.Response(
            body,
            200,
            headers: {'content-type': 'text/event-stream'},
          ),
        ),
      );
      await client.post(
        Uri.parse('https://api.anthropic.com/v1/messages'),
        body: jsonEncode({
          'model': 'claude-sonnet-5-5',
          'max_tokens': 1024,
          'stream': true,
          'system': 'You are helpful',
          'messages': [
            {'role': 'user', 'content': 'Hello'},
          ],
        }),
      );
      await t.flush();
      final r = (await t.records()).single;
      expect(r.provider, 'anthropic');
      expect(r.model, 'claude-sonnet-5-5');
      expect(r.usage.inputTokens, 25);
      expect(r.usage.cachedInputTokens, 1000);
      expect(r.usage.outputTokens, 15);
      expect(r.response, 'Hi there');
      expect(r.finishReason, 'end_turn');
      expect(r.prompt, contains('[system] You are helpful'));
      expect(r.parameters['max_tokens'], 1024);
      // 25*2 + 15*10 + 1000*0.2 per million
      expect(
        r.cost.total,
        closeTo((25 * 2 + 15 * 10 + 1000 * 0.2) / 1e6, 1e-12),
      );
      await t.dispose();
    });

    test('Gemini SSE and JSON-array streaming, model from URL', () async {
      final chunk1 = {
        'candidates': [
          {
            'content': {
              'parts': [
                {'text': 'A'},
              ],
            },
          },
        ],
        'usageMetadata': {'promptTokenCount': 5, 'candidatesTokenCount': 1},
      };
      final chunk2 = {
        'candidates': [
          {
            'content': {
              'parts': [
                {'text': 'B'},
              ],
            },
            'finishReason': 'STOP',
          },
        ],
        'usageMetadata': {
          'promptTokenCount': 5,
          'candidatesTokenCount': 2,
          'totalTokenCount': 7,
        },
        'modelVersion': 'gemini-2.5-flash',
      };
      for (final body in [
        sse([chunk1, chunk2]),
        const JsonEncoder.withIndent('  ').convert([chunk1, chunk2]),
      ]) {
        final t = await newTracker(promptStorage: PromptStorageMode.full);
        final client = t.httpClient(
          MockClient((_) async => http.Response(body, 200)),
        );
        await client.post(
          Uri.parse(
            'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:streamGenerateContent?alt=sse',
          ),
          body: jsonEncode({
            'contents': [
              {
                'role': 'user',
                'parts': [
                  {'text': 'Q'},
                ],
              },
            ],
            'generationConfig': {'temperature': 0.1},
          }),
        );
        await t.flush();
        final r = (await t.records()).single;
        expect(r.provider, 'gemini');
        expect(r.model, 'gemini-2.5-flash');
        expect(r.usage.inputTokens, 5);
        expect(r.usage.outputTokens, 2);
        expect(r.response, 'AB');
        expect(r.parameters['temperature'], 0.1);
        await t.dispose();
      }
    });

    test('Ollama NDJSON stream is free and tracked', () async {
      final t = await newTracker();
      final body = [
        jsonEncode({
          'model': 'llama3.2',
          'message': {'content': 'Hi'},
          'done': false,
        }),
        jsonEncode({
          'model': 'llama3.2',
          'message': {'content': '!'},
          'done': true,
          'done_reason': 'stop',
          'prompt_eval_count': 11,
          'eval_count': 3,
        }),
      ].join('\n');
      final client = t.httpClient(
        MockClient(
          (_) async => http.Response(
            body,
            200,
            headers: {'content-type': 'application/x-ndjson'},
          ),
        ),
      );
      await client.post(
        Uri.parse('http://localhost:11434/api/chat'),
        body: jsonEncode({
          'model': 'llama3.2',
          'messages': [
            {'role': 'user', 'content': 'hey'},
          ],
        }),
      );
      await t.flush();
      final r = (await t.records()).single;
      expect(r.provider, 'ollama');
      expect(r.usage.inputTokens, 11);
      expect(r.usage.outputTokens, 3);
      expect(r.cost.priced, isTrue);
      expect(r.cost.total, 0);
      await t.dispose();
    });

    test('OpenAI-compatible hosts get the right provider name', () async {
      final t = await newTracker();
      final client = t.httpClient(MockClient((_) async => openAIResponse()));
      await client.post(
        Uri.parse('https://api.groq.com/openai/v1/chat/completions'),
        body: chatBody(),
      );
      await client.post(
        Uri.parse('https://my-gateway.internal/v1/chat/completions'),
        body: chatBody(),
      );
      await t.flush();
      final providers = (await t.records()).map((r) => r.provider).toSet();
      expect(providers, {'groq', 'my-gateway.internal'});
      await t.dispose();
    });

    test('custom host via additionalHostsToTrack + generic adapter', () async {
      final t = await newTracker(additionalHosts: ['ai.mycompany.com']);
      final client = t.httpClient(
        MockClient(
          (_) async => http.Response(
            jsonEncode({
              'output': 'hi',
              'usage': {'input_tokens': 4, 'output_tokens': 2},
            }),
            200,
          ),
        ),
      );
      await client.post(
        Uri.parse('https://ai.mycompany.com/generate'),
        body: jsonEncode({'model': 'in-house-7b', 'prompt': 'x'}),
      );
      await t.flush();
      final r = (await t.records()).single;
      expect(r.model, 'in-house-7b');
      expect(r.usage.outputTokens, 2);
      await t.dispose();
    });
  });

  group('fail-safe', () {
    test('broken storage never breaks the app call', () async {
      final errors = <Object>[];
      final t = await newTracker(
        store: BrokenStore(),
        onError: (e, _) => errors.add(e),
      );
      final client = t.httpClient(MockClient((_) async => openAIResponse()));
      final res = await client.post(openAIUrl, body: chatBody());
      expect(res.statusCode, 200);
      await t.flush();
      expect(errors, isNotEmpty);
      expect(await t.records(), isEmpty); // query also fails, safely
      await t.dispose();
    });

    test('throwing adapter and beforeSave are contained', () async {
      final errors = <Object>[];
      final t = await newTracker(
        onError: (e, _) => errors.add(e),
        beforeSave: (r) => throw StateError('boom'),
      );
      t.registerAdapter(_ThrowingAdapter());
      final client = t.httpClient(MockClient((_) async => openAIResponse()));
      final res = await client.post(
        Uri.parse('https://evil.example/v1/explode'),
        body: '{"model":"x"}',
      );
      expect(res.statusCode, 200);
      final res2 = await client.post(openAIUrl, body: chatBody());
      expect(jsonDecode(res2.body)['id'], 'chatcmpl-1');
      await t.flush();
      expect(errors, isNotEmpty);
      await t.dispose();
    });

    test('malformed bodies are fine', () async {
      final t = await newTracker();
      final client = t.httpClient(
        MockClient((_) async => http.Response('<html>bad gateway</html>', 502)),
      );
      final res = await client.post(openAIUrl, body: 'not json');
      expect(res.statusCode, 502);
      await t.flush();
      expect((await t.records()).single.status, AICallStatus.error);
      await t.dispose();
    });

    test('calls before initialize are buffered', () async {
      final t = KaleidoscopeTracker();
      final client = t.httpClient(MockClient((_) async => openAIResponse()));
      await client.post(openAIUrl, body: chatBody());
      await t.initialize(
        KaleidoscopeConfig(
          store: InMemoryUsageStore(),
          debugLog: AIDebugLogConfig.off,
        ),
      );
      await t.flush();
      expect(await t.records(), hasLength(1));
      await t.dispose();
    });

    test('beforeSave can drop records', () async {
      final t = await newTracker(
        beforeSave: (r) => r.model.contains('mini') ? null : r,
      );
      final client = t.httpClient(MockClient((_) async => openAIResponse()));
      await client.post(openAIUrl, body: chatBody());
      await t.flush();
      expect(await t.records(), isEmpty);
      await t.dispose();
    });
  });

  group('dio', () {
    test('records JSON responses and errors', () async {
      final t = await newTracker();
      final dio = Dio()..httpClientAdapter = _FakeAdapter();
      dio.interceptors.add(t.dioInterceptor());
      final res = await Kaleidoscope.scope(
        module: 'shop',
        page: 'cart',
        () => dio.post<Map<String, dynamic>>(
          openAIUrl.toString(),
          data: jsonDecode(chatBody()),
        ),
      );
      expect(res.data!['id'], 'chatcmpl-1');
      await expectLater(
        dio.post<dynamic>(
          'https://api.openai.com/v1/chat/completions?fail=1',
          data: {'model': 'gpt-4o'},
        ),
        throwsA(isA<DioException>()),
      );
      await t.flush();
      final rs = await t.records(const UsageQuery(newestFirst: false));
      expect(rs, hasLength(2));
      expect(rs[0].usage.inputTokens, 12);
      expect(rs[0].context.page, 'cart');
      expect(rs[0].source, AICaptureSource.dio);
      expect(rs[1].status, AICallStatus.error);
      expect(rs[1].httpStatus, 401);
      expect(rs[1].errorMessage, 'Invalid API key');
      await t.dispose();
    });

    test('stream responses', () async {
      final t = await newTracker();
      final dio = Dio()..httpClientAdapter = _FakeAdapter();
      dio.interceptors.add(t.dioInterceptor());
      final res = await dio.post<ResponseBody>(
        'https://api.openai.com/v1/chat/completions?stream=1',
        data: jsonDecode(chatBody(stream: true)),
        options: Options(responseType: ResponseType.stream),
      );
      final text = await utf8.decodeStream(res.data!.stream);
      expect(text, contains('[DONE]'));
      await t.flush();
      final r = (await t.records()).single;
      expect(r.streamed, isTrue);
      expect(r.usage.outputTokens, 2);
      await t.dispose();
    });
  });

  group('wrappers', () {
    test('track() works with any SDK and rethrows errors', () async {
      final t = await newTracker(promptStorage: PromptStorageMode.full);
      final out = await t.track<Map<String, int>>(
        provider: 'my-sdk',
        model: 'gpt-4o',
        prompt: 'question',
        context: const AIUsageContext(module: 'm', page: 'p'),
        call: () async => {'in': 100, 'out': 20},
        usage: (r) =>
            AITokenUsage(inputTokens: r['in']!, outputTokens: r['out']!),
        responseText: (r) => 'answer',
      );
      expect(out['in'], 100);
      await expectLater(
        t.track<void>(
          provider: 'x',
          model: 'y',
          call: () async => throw const FormatException('bad'),
        ),
        throwsFormatException,
      );
      await t.flush();
      final rs = await t.records(const UsageQuery(newestFirst: false));
      expect(rs[0].usage.inputTokens, 100);
      expect(rs[0].response, 'answer');
      expect(rs[0].source, AICaptureSource.wrapper);
      expect(rs[1].status, AICallStatus.error);
      await t.dispose();
    });

    test('trackStream collects chunks and usage', () async {
      final t = await newTracker(promptStorage: PromptStorageMode.full);
      final chunks = await t
          .trackStream<String>(
            provider: 'gemini',
            model: 'gemini-2.5-flash',
            call: () => Stream.fromIterable(['a', 'b', 'c']),
            onChunk: (c) => (
              text: c,
              usage: c == 'c'
                  ? const AITokenUsage(inputTokens: 3, outputTokens: 3)
                  : null,
            ),
          )
          .toList();
      expect(chunks, ['a', 'b', 'c']);
      await t.flush();
      final r = (await t.records()).single;
      expect(r.response, 'abc');
      expect(r.usage.outputTokens, 3);
      expect(r.streamed, isTrue);
      expect(r.timeToFirstTokenMs, isNotNull);
      await t.dispose();
    });

    test('on-device and manual record', () async {
      final t = await newTracker();
      await t.trackOnDevice<String>(
        model: 'gemini-nano',
        runtime: 'aicore',
        inputText: 'summarise this text please',
        call: () async => 'short',
        outputText: (r) => r,
      );
      t.record(
        provider: 'backend',
        model: 'gpt-4o',
        inputTokens: 1000,
        outputTokens: 100,
        latencyMs: 900,
      );
      await t.flush();
      final rs = await t.records(const UsageQuery(newestFirst: false));
      expect(rs[0].provider, 'on-device');
      expect(rs[0].customData['runtime'], 'aicore');
      expect(rs[0].usage.estimated, isTrue);
      expect(rs[1].cost.total, closeTo((1000 * 2.5 + 100 * 10) / 1e6, 1e-12));
      await t.dispose();
    });

    test('estimate before calling', () async {
      final t = await newTracker();
      final e = t.estimate(
        model: 'gpt-4o',
        prompt: 'x' * 4000,
        expectedOutputTokens: 1000,
      );
      expect(e.inputTokens, 1004);
      expect(e.cost.total, closeTo((1004 * 2.5 + 1000 * 10) / 1e6, 1e-12));
      await t.dispose();
    });

    test('nested scopes merge', () async {
      final t = await newTracker();
      t.currentScreen = const AIUsageContext(page: '/home');
      await Kaleidoscope.scope(module: 'a', () async {
        await Kaleidoscope.scope(section: 's', () async {
          t.record(provider: 'p', model: 'm');
        });
      });
      await t.flush();
      final c = (await t.records()).single.context;
      expect([c.module, c.page, c.section], ['a', '/home', 's']);
      await t.dispose();
    });

    test('fallback router', () async {
      final t = await newTracker();
      final router = AIFallbackRouter(tracker: t, failureThreshold: 1);
      final result = await router.run<String>([
        AIRoute(
          provider: 'openai',
          model: 'gpt-4o',
          call: () async => throw StateError('down'),
        ),
        AIRoute(
          provider: 'anthropic',
          model: 'claude-haiku-5-5',
          call: () async => 'ok',
        ),
      ]);
      expect(result, 'ok');
      expect(router.isOpen('openai/gpt-4o'), isTrue);
      await expectLater(
        router.run<String>([
          AIRoute(
            provider: 'a',
            model: 'b',
            call: () async => throw StateError('x'),
          ),
        ]),
        throwsA(isA<AIAllRoutesFailedException>()),
      );
      await t.flush();
      final rs = await t.records(const UsageQuery(newestFirst: false));
      expect(rs.map((r) => r.status), [
        AICallStatus.error,
        AICallStatus.success,
        AICallStatus.error,
      ]);
      expect(rs[1].customData['fallback'], isTrue);
      await t.dispose();
    });
  });
}

class _ThrowingAdapter extends AIProviderAdapter {
  @override
  String get provider => 'evil';
  @override
  bool matches(Uri uri) => uri.host == 'evil.example';
  @override
  AIRequestInfo parseRequest(Uri uri, Map<String, Object?>? body) =>
      throw StateError('req');
  @override
  AIResponseInfo parseResponse(Uri uri, Object? json) =>
      throw StateError('res');
  @override
  void onStreamEvent(Uri uri, Object? json, AIStreamAccumulator acc) =>
      throw StateError('evt');
}

class _FakeAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.uri.queryParameters['fail'] == '1') {
      return ResponseBody.fromString(
        jsonEncode({
          'error': {'message': 'Invalid API key'},
        }),
        401,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      );
    }
    if (options.uri.queryParameters['stream'] == '1') {
      final body = sse([
        {
          'model': 'gpt-4o-mini',
          'choices': [
            {
              'delta': {'content': 'yo'},
            },
          ],
        },
        {
          'model': 'gpt-4o-mini',
          'choices': [],
          'usage': {'prompt_tokens': 3, 'completion_tokens': 2},
        },
        '[DONE]',
      ]);
      return ResponseBody(
        Stream.value(Uint8List.fromList(utf8.encode(body))),
        200,
        headers: {
          Headers.contentTypeHeader: ['text/event-stream'],
        },
      );
    }
    return ResponseBody.fromString(
      openAIResponse().body,
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
