import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:http/http.dart' as http;

/// Simulated provider responses so the demo works offline and without keys.
class FakeAIBackend {
  static final _rnd = Random();

  static Future<http.StreamedResponse> handle(
    http.BaseRequest req,
    http.ByteStream body,
  ) async {
    await Future<void>.delayed(Duration(milliseconds: 300 + _rnd.nextInt(600)));
    final json = jsonEncode({
      'id': 'chatcmpl-demo',
      'model': 'gpt-4o-mini-2024-07-18',
      'choices': [
        {
          'message': {
            'role': 'assistant',
            'content': 'Sorry about that! I have re-sent order #123 with express shipping.',
          },
          'finish_reason': 'stop',
        },
      ],
      'usage': {
        'prompt_tokens': 40 + _rnd.nextInt(60),
        'completion_tokens': 20 + _rnd.nextInt(40),
      },
    });
    return http.StreamedResponse(
      Stream.value(utf8.encode(json)),
      200,
      headers: {'content-type': 'application/json'},
    );
  }

  static HttpClientAdapter dioAdapter() => _ClaudeStreamAdapter();
}

class _ClaudeStreamAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    String ev(Map<String, Object?> e) =>
        'event: ${e['type']}\ndata: ${jsonEncode(e)}\n\n';
    final words = [
      'Footprint ',
      'groundsheet, ',
      'LED lantern, ',
      'and a ',
      'repair kit.',
    ];
    Stream<Uint8List> gen() async* {
      yield Uint8List.fromList(
        utf8.encode(
          ev({
            'type': 'message_start',
            'message': {
              'id': 'msg_demo',
              'model': 'claude-haiku-5-5',
              'usage': {
                'input_tokens': 22,
                'output_tokens': 1,
                'cache_read_input_tokens': 1200,
              },
            },
          }),
        ),
      );
      for (final w in words) {
        await Future<void>.delayed(const Duration(milliseconds: 120));
        yield Uint8List.fromList(
          utf8.encode(
            ev({
              'type': 'content_block_delta',
              'index': 0,
              'delta': {'type': 'text_delta', 'text': w},
            }),
          ),
        );
      }
      yield Uint8List.fromList(
        utf8.encode(
          ev({
            'type': 'message_delta',
            'delta': {'stop_reason': 'end_turn'},
            'usage': {'output_tokens': 18},
          }),
        ),
      );
      yield Uint8List.fromList(utf8.encode(ev({'type': 'message_stop'})));
    }

    return ResponseBody(
      gen(),
      200,
      headers: {
        Headers.contentTypeHeader: ['text/event-stream'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Stand-in for an SDK response object (e.g. GenerateContentResponse).
class FakeSdkResponse {
  FakeSdkResponse(this.text, this.promptTokens, this.outputTokens);
  final String text;
  final int promptTokens;
  final int outputTokens;

  static Future<FakeSdkResponse> generate(String prompt) async {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    return FakeSdkResponse(
      'You had 3 meetings and 2 ideas worth following up.',
      180,
      24,
    );
  }
}
