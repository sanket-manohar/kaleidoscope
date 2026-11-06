// Minimal receiver for ServerSyncSink. No dependencies: `dart run server.dart`
//
//   POST /ai-usage   body: {"app": "...", "records": [ ... ]}   -> 200 {"saved": n}
//   GET  /summary    -> totals by app, module and model
//
// Records are appended to ai_usage.jsonl. Set AI_USAGE_TOKEN to require
// `Authorization: Bearer <token>`. Duplicate record ids are ignored, so
// client retries are safe.
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  final port = int.tryParse(Platform.environment['PORT'] ?? '') ?? 8080;
  final token = Platform.environment['AI_USAGE_TOKEN'];
  final file = File('ai_usage.jsonl');
  final seen = <String>{};
  if (file.existsSync()) {
    for (final line in file.readAsLinesSync()) {
      try {
        seen.add((jsonDecode(line) as Map)['id'] as String);
      } catch (_) {}
    }
  }

  final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
  stdout.writeln(
    'AI usage receiver on http://localhost:$port (POST /ai-usage, GET /summary)',
  );

  await for (final req in server) {
    try {
      if (token != null &&
          req.headers.value('authorization') != 'Bearer $token') {
        _json(req, 401, {'error': 'unauthorized'});
        continue;
      }
      if (req.method == 'POST' && req.uri.path == '/ai-usage') {
        final body =
            jsonDecode(await utf8.decodeStream(req)) as Map<String, dynamic>;
        final app = body['app'] ?? 'unknown';
        final records = (body['records'] as List? ?? const [])
            .cast<Map<String, dynamic>>();
        final sink = file.openWrite(mode: FileMode.append);
        var saved = 0;
        for (final r in records) {
          final id = r['id'] as String?;
          if (id == null || !seen.add(id)) continue;
          sink.writeln(
            jsonEncode({
              ...r,
              'app': app,
              'receivedAt': DateTime.now().toUtc().toIso8601String(),
            }),
          );
          saved++;
        }
        await sink.close();
        _json(req, 200, {'saved': saved, 'duplicates': records.length - saved});
      } else if (req.method == 'GET' && req.uri.path == '/summary') {
        final totals = <String, Map<String, num>>{};
        void add(String key, Map r) {
          final t = totals.putIfAbsent(
            key,
            () => {'calls': 0, 'tokens': 0, 'cost': 0},
          );
          t['calls'] = t['calls']! + 1;
          t['tokens'] =
              t['tokens']! + ((r['usage'] as Map?)?['total'] as num? ?? 0);
          t['cost'] = t['cost']! + ((r['cost'] as Map?)?['total'] as num? ?? 0);
        }

        if (file.existsSync()) {
          for (final line in file.readAsLinesSync()) {
            final r = jsonDecode(line) as Map;
            add('app:${r['app']}', r);
            add('module:${(r['context'] as Map?)?['module'] ?? '(none)'}', r);
            add('model:${r['model']}', r);
          }
        }
        _json(req, 200, totals);
      } else {
        _json(req, 404, {'error': 'not found'});
      }
    } catch (e) {
      _json(req, 400, {'error': '$e'});
    }
  }
}

void _json(HttpRequest req, int status, Object body) {
  req.response
    ..statusCode = status
    ..headers.contentType = ContentType.json
    ..write(jsonEncode(body))
    ..close();
}
