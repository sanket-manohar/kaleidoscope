import 'dart:convert';

/// Incrementally decodes Server-Sent Events (`data: {...}`) and NDJSON
/// bodies into JSON values. Malformed lines are skipped, never thrown.
class AIStreamDecoder {
  AIStreamDecoder(this.onEvent, {this.maxRawChars = 4 * 1024 * 1024}) {
    _utf8 = const Utf8Decoder(
      allowMalformed: true,
    ).startChunkedConversion(_CallbackSink(_onText));
  }

  final void Function(Object? json) onEvent;
  final int maxRawChars;
  late final Sink<List<int>> _utf8;
  final _line = StringBuffer();
  final _data = StringBuffer();
  final _raw = StringBuffer();
  bool _rawOverflow = false;
  int dispatched = 0;
  bool _closed = false;

  void add(List<int> bytes) {
    if (_closed) return;
    _utf8.add(bytes);
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _utf8.close();
    if (_line.isNotEmpty) {
      _handleLine(_line.toString());
      _line.clear();
    }
    _flushData();
    if (dispatched == 0 && !_rawOverflow && _raw.isNotEmpty) {
      // e.g. Gemini without alt=sse streams one (pretty-printed) JSON array.
      _emit(_raw.toString());
    }
  }

  void _onText(String text) {
    if (!_rawOverflow) {
      if (_raw.length + text.length > maxRawChars) {
        _rawOverflow = true;
        _raw.clear();
      } else {
        _raw.write(text);
      }
    }
    var start = 0;
    for (var i = 0; i < text.length; i++) {
      if (text.codeUnitAt(i) == 0x0A) {
        _line.write(text.substring(start, i));
        _handleLine(_line.toString());
        _line.clear();
        start = i + 1;
      }
    }
    if (start < text.length) _line.write(text.substring(start));
  }

  void _handleLine(String raw) {
    final line = raw.endsWith('\r') ? raw.substring(0, raw.length - 1) : raw;
    if (line.isEmpty) {
      _flushData();
      return;
    }
    if (line.startsWith('data:')) {
      var payload = line.substring(5);
      if (payload.startsWith(' ')) payload = payload.substring(1);
      if (_data.isNotEmpty) _data.write('\n');
      _data.write(payload);
      return;
    }
    if (line.startsWith('event:') ||
        line.startsWith('id:') ||
        line.startsWith('retry:') ||
        line.startsWith(':')) {
      return;
    }
    final t = line.trim();
    if (t.startsWith('{') && t.endsWith('}')) _emit(t); // NDJSON
  }

  void _flushData() {
    if (_data.isEmpty) return;
    final payload = _data.toString().trim();
    _data.clear();
    if (payload == '[DONE]' || payload.isEmpty) return;
    _emit(payload);
  }

  void _emit(String payload) {
    Object? json;
    try {
      json = jsonDecode(payload);
    } catch (_) {
      return;
    }
    dispatched++;
    try {
      onEvent(json);
    } catch (_) {}
  }
}

class _CallbackSink implements Sink<String> {
  _CallbackSink(this._cb);
  final void Function(String) _cb;
  @override
  void add(String data) => _cb(data);
  @override
  void close() {}
}
