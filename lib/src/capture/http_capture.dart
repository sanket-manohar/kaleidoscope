import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../core/usage_draft.dart';
import '../models/ai_usage_record.dart';
import 'provider_adapter.dart';
import 'stream_decoder.dart';

/// Internal interface the HTTP interceptors use to talk to the tracker.
abstract class AICaptureHost {
  /// Returns an adapter for [uri], or null when it should not be tracked.
  AIProviderAdapter? adapterFor(Uri uri);
  AIUsageDraft newDraft({
    required String provider,
    String? model,
    String operation,
    String? endpoint,
    Map<String, Object?> parameters,
    String? prompt,
    AICaptureSource source,
  });
  void submit(AIUsageDraft draft);
  void reportInternalError(Object error, StackTrace stack);
  bool get injectStreamUsageOption;
  bool get captureParameters;
}

/// Tracks one HTTP call from request to (streamed) response.
class HttpCapture {
  HttpCapture._(
    this._host,
    this.adapter,
    this.uri,
    this.draft,
    this.streamHint,
  );

  /// Starts a capture, or returns null when [uri] is not an AI endpoint.
  /// Never throws.
  static HttpCapture? start(
    AICaptureHost host,
    Uri uri,
    Object? body,
    AICaptureSource source,
  ) {
    try {
      final adapter = host.adapterFor(uri);
      if (adapter == null) return null;
      final map = decodeBody(body);
      AIRequestInfo req;
      try {
        req = adapter.parseRequest(uri, map);
      } catch (_) {
        req = AIRequestInfo();
      }
      final draft = host.newDraft(
        provider: adapter.providerFor(uri),
        model: req.model,
        operation: req.operation,
        endpoint: '${uri.host}${uri.path}',
        parameters: host.captureParameters ? req.parameters : const {},
        prompt: req.promptText,
        source: source,
      );
      return HttpCapture._(
        host,
        adapter,
        uri,
        draft,
        req.stream || adapter.isStreaming(uri, map),
      );
    } catch (e, st) {
      host.reportInternalError(e, st);
      return null;
    }
  }

  /// Decodes a JSON request/response body from String, bytes or Map.
  static Map<String, Object?>? decodeBody(Object? body) {
    try {
      if (body is Map) return body.cast<String, Object?>();
      String? s;
      if (body is String) s = body;
      if (body is List<int>) s = utf8.decode(body, allowMalformed: true);
      if (s == null || s.isEmpty) return null;
      final t = s.trimLeft();
      if (!t.startsWith('{')) return null;
      final d = jsonDecode(t);
      return d is Map ? d.cast<String, Object?>() : null;
    } catch (_) {
      return null;
    }
  }

  /// Returns a copy of [body] with `stream_options.include_usage` set, for
  /// OpenAI-compatible streaming requests. Returns null when not applicable.
  static Map<String, Object?>? withStreamUsage(Map<String, Object?>? body) {
    if (body == null || body['stream'] != true) return null;
    if (body.containsKey('messages') == false &&
        body.containsKey('prompt') == false) {
      return null; // Responses API reports usage already.
    }
    final so = body['stream_options'];
    if (so is Map && so['include_usage'] == true) return null;
    return {
      ...body,
      'stream_options': {if (so is Map) ...so, 'include_usage': true},
    };
  }

  final AICaptureHost _host;
  final AIProviderAdapter adapter;
  final Uri uri;
  final AIUsageDraft draft;
  final bool streamHint;
  final _sw = Stopwatch()..start();
  bool _streaming = false;
  bool _done = false;
  int? _status;
  AIStreamDecoder? _decoder;
  final _acc = AIStreamAccumulator();
  final _body = BytesBuilder(copy: false);
  int _bodyLen = 0;
  static const _maxBody = 8 * 1024 * 1024;

  void onResponse(int statusCode, String? contentType) {
    if (_done) return;
    try {
      _status = statusCode;
      draft.httpStatus = statusCode;
      final ct = contentType?.toLowerCase() ?? '';
      _streaming =
          statusCode < 400 &&
          (streamHint ||
              ct.contains('text/event-stream') ||
              ct.contains('ndjson'));
      if (_streaming) {
        draft.streamed = true;
        _decoder = AIStreamDecoder((json) {
          draft.timeToFirstTokenMs ??= _sw.elapsedMilliseconds;
          adapter.onStreamEvent(uri, json, _acc);
        });
      }
    } catch (e, st) {
      _host.reportInternalError(e, st);
    }
  }

  void addBytes(List<int> bytes) {
    if (_done) return;
    try {
      if (_decoder != null) {
        _decoder!.add(bytes);
      } else if (_bodyLen + bytes.length <= _maxBody) {
        _body.add(bytes);
        _bodyLen += bytes.length;
      }
    } catch (e, st) {
      _host.reportInternalError(e, st);
    }
  }

  /// Body fully received.
  void complete() {
    if (_done) return;
    try {
      if (_decoder != null) {
        _decoder!.close();
        _finish(_acc.toResponse());
        return;
      }
      completeWithData(_body.takeBytes());
    } catch (e, st) {
      _host.reportInternalError(e, st);
    }
  }

  /// For clients that already decoded the body (Dio): [data] may be a Map,
  /// List, String or bytes.
  void completeWithData(Object? data) {
    if (_done) return;
    try {
      Object? json = data;
      if (data is List<int>) {
        json = utf8.decode(data, allowMalformed: true);
      }
      if (json is String) {
        final str = json;
        try {
          json = jsonDecode(str);
        } catch (_) {
          // Not JSON. Maybe a buffered SSE body.
          if (str.contains('data:')) {
            final d = AIStreamDecoder(
              (j) => adapter.onStreamEvent(uri, j, _acc),
            );
            d.add(utf8.encode(str));
            d.close();
            draft.streamed = true;
            _finish(_acc.toResponse());
            return;
          }
          json = null;
        }
      }
      if ((_status ?? 200) >= 400) {
        _fail(_errorMessage(json) ?? 'HTTP $_status', AICallStatus.error);
        return;
      }
      if (json is List && adapter is! AIListResponseAdapter) {
        // Some APIs stream a JSON array even without SSE.
        for (final e in json) {
          adapter.onStreamEvent(uri, e, _acc);
        }
        _finish(_acc.toResponse());
        return;
      }
      _finish(adapter.parseResponse(uri, json));
    } catch (e, st) {
      _host.reportInternalError(e, st);
      _finish(AIResponseInfo());
    }
  }

  void fail(Object error, {int? statusCode, Object? responseData}) {
    if (_done) return;
    if (statusCode != null) draft.httpStatus = statusCode;
    final msg =
        _errorMessage(
          HttpCapture.decodeBody(responseData) ??
              (responseData is Map ? responseData : null),
        ) ??
        error.toString();
    _fail(msg, AICallStatus.error);
  }

  void cancel() {
    if (_done) return;
    if (_decoder != null && _acc.events > 0) {
      // Keep partial stream data.
      try {
        _decoder!.close();
      } catch (_) {}
      draft.status = AICallStatus.cancelled;
      draft.errorMessage = 'Stream cancelled by app';
      _finish(_acc.toResponse(), keepStatus: true);
      return;
    }
    _fail('Cancelled', AICallStatus.cancelled);
  }

  void _fail(String message, AICallStatus status) {
    if (_done) return;
    draft.status = status;
    draft.errorMessage = message.length > 500
        ? '${message.substring(0, 500)}…'
        : message;
    _finish(
      _decoder != null ? _acc.toResponse() : AIResponseInfo(),
      keepStatus: true,
    );
  }

  void _finish(AIResponseInfo info, {bool keepStatus = false}) {
    if (_done) return;
    _done = true;
    try {
      draft.latencyMs = _sw.elapsedMilliseconds;
      if (info.model != null && info.model!.isNotEmpty) {
        draft.model = info.model;
      }
      draft.usage = info.usage ?? draft.usage;
      draft.response = info.text;
      draft.finishReason = info.finishReason;
      draft.responseId = info.responseId;
      _host.submit(draft);
    } catch (e, st) {
      _host.reportInternalError(e, st);
    }
  }

  static String? _errorMessage(Object? json) {
    if (json is! Map) return json is String && json.isNotEmpty ? json : null;
    final err = json['error'];
    if (err is Map) {
      return (err['message'] ?? err['type'] ?? err.toString()).toString();
    }
    if (err is String) return err;
    return (json['message'] ?? json['detail'])?.toString();
  }

  /// Wraps [source] so every byte is observed by this capture, without
  /// changing what the app receives.
  Stream<List<int>> tee(Stream<List<int>> source) {
    late StreamController<List<int>> controller;
    StreamSubscription<List<int>>? sub;
    controller = StreamController<List<int>>(
      sync: true,
      onListen: () {
        sub = source.listen(
          (data) {
            controller.add(data);
            addBytes(data);
          },
          onError: (Object e, StackTrace st) {
            controller.addError(e, st);
            fail(e);
          },
          onDone: () {
            complete();
            controller.close();
          },
          cancelOnError: false,
        );
      },
      onPause: () => sub?.pause(),
      onResume: () => sub?.resume(),
      onCancel: () {
        cancel();
        return sub?.cancel();
      },
    );
    return controller.stream;
  }

  Stream<Uint8List> teeBytes(Stream<Uint8List> source) =>
      tee(source).map((e) => e is Uint8List ? e : Uint8List.fromList(e));
}

/// Marker for adapters whose normal (non-stream) response is a JSON list.
abstract class AIListResponseAdapter {}
