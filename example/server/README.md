# Sample backend for `ServerSyncSink`

```bash
AI_USAGE_TOKEN=secret dart run server.dart
```

In the app:

```dart
Kaleidoscope.addSink(ServerSyncSink(
  endpoint: Uri.parse('https://your-server.com/ai-usage'),
  headers: {'Authorization': 'Bearer secret'},
  appId: 'my-app',
));
```

Records are batched, kept on the device while offline, retried with backoff,
and de-duplicated by id on the server. Prompt text is never sent unless you set
`includeText: true`.

`GET /summary` returns calls, tokens and cost by app, module and model.
