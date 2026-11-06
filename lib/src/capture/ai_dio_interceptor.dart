import 'package:dio/dio.dart';

import '../models/ai_usage_record.dart';
import 'http_capture.dart';

/// Dio interceptor that records AI API calls.
///
/// ```dart
/// dio.interceptors.add(Kaleidoscope.dioInterceptor());
/// ```
class AITrackingDioInterceptor extends Interceptor {
  AITrackingDioInterceptor(this._host);

  final AICaptureHost _host;
  static const _key = '__ai_usage_capture';

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    try {
      final cap = HttpCapture.start(
        _host,
        options.uri,
        options.data,
        AICaptureSource.dio,
      );
      if (cap != null) {
        options.extra[_key] = cap;
        if (_host.injectStreamUsageOption) {
          final patched = HttpCapture.withStreamUsage(
            HttpCapture.decodeBody(options.data),
          );
          if (patched != null) options.data = patched;
        }
      }
    } catch (e, st) {
      _host.reportInternalError(e, st);
    }
    handler.next(options);
  }

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) {
    try {
      final cap = response.requestOptions.extra.remove(_key);
      if (cap is HttpCapture) {
        cap.onResponse(
          response.statusCode ?? 200,
          response.headers.value(Headers.contentTypeHeader),
        );
        final data = response.data;
        if (data is ResponseBody) {
          data.stream = cap.teeBytes(data.stream);
        } else {
          cap.completeWithData(data);
        }
      }
    } catch (e, st) {
      _host.reportInternalError(e, st);
    }
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    try {
      final cap = err.requestOptions.extra.remove(_key);
      if (cap is HttpCapture) {
        if (err.type == DioExceptionType.cancel) {
          cap.cancel();
        } else {
          Object? data = err.response?.data;
          if (data is ResponseBody) data = null;
          cap.fail(
            err.message ?? err.type.name,
            statusCode: err.response?.statusCode,
            responseData: data,
          );
        }
      }
    } catch (e, st) {
      _host.reportInternalError(e, st);
    }
    handler.next(err);
  }
}
