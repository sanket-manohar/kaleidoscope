import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/ai_usage_record.dart';
import 'http_capture.dart';

/// A drop-in `http.Client` that records every AI API call made through it.
///
/// ```dart
/// final client = Kaleidoscope.httpClient(); // wraps http.Client()
/// final res = await client.post(Uri.parse('https://api.openai.com/v1/chat/completions'), ...);
/// ```
///
/// Non-AI requests pass through untouched. If tracking fails for any reason,
/// the request and response are still delivered exactly as normal.
class AITrackingHttpClient extends http.BaseClient {
  AITrackingHttpClient(this._host, {http.Client? inner})
    : _inner = inner ?? http.Client();

  final AICaptureHost _host;
  final http.Client _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    HttpCapture? cap;
    var outgoing = request;
    try {
      String? body;
      if (request is http.Request) body = request.body;
      cap = HttpCapture.start(
        _host,
        request.url,
        body,
        AICaptureSource.httpClient,
      );
      if (cap != null &&
          request is http.Request &&
          _host.injectStreamUsageOption) {
        final patched = HttpCapture.withStreamUsage(
          HttpCapture.decodeBody(body),
        );
        if (patched != null) {
          outgoing = _copyWithBody(request, jsonEncode(patched));
        }
      }
    } catch (e, st) {
      _host.reportInternalError(e, st);
    }

    http.StreamedResponse res;
    try {
      res = await _inner.send(outgoing);
    } catch (e) {
      cap?.fail(e);
      rethrow;
    }
    if (cap == null) return res;
    try {
      cap.onResponse(res.statusCode, res.headers['content-type']);
      return http.StreamedResponse(
        http.ByteStream(cap.tee(res.stream)),
        res.statusCode,
        contentLength: res.contentLength,
        request: res.request,
        headers: res.headers,
        isRedirect: res.isRedirect,
        persistentConnection: res.persistentConnection,
        reasonPhrase: res.reasonPhrase,
      );
    } catch (e, st) {
      _host.reportInternalError(e, st);
      return res;
    }
  }

  http.Request _copyWithBody(http.Request r, String body) {
    final c = http.Request(r.method, r.url)
      ..headers.addAll(r.headers)
      ..followRedirects = r.followRedirects
      ..maxRedirects = r.maxRedirects
      ..persistentConnection = r.persistentConnection
      ..encoding = r.encoding;
    c.body = body;
    return c;
  }

  @override
  void close() => _inner.close();
}
