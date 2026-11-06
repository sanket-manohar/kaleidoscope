import 'dart:convert';
import 'dart:math';

import 'package:kaleidoscope/kaleidoscope.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fake_ai_backend.dart';

final navigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 1. Start the tracker (one line). Everything else is optional.
  await Kaleidoscope.init(
    storePrompts: true, // demo only: keep prompt/answer text (encrypted)
    keepFor: const Duration(days: 60), // your retention policy
    monthlyBudget: 25, // budget alerts + projection
  );

  // Optional: your own price for a private model, updatable any time.
  Kaleidoscope.pricing.setPrice(
    'acme-support-*',
    const ModelPrice(inputPerMillion: 0.5, outputPerMillion: 1.5),
  );

  runApp(const DemoApp());
}

class DemoApp extends StatelessWidget {
  const DemoApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'kaleidoscope demo',
    navigatorKey: navigatorKey,
    theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
    darkTheme: ThemeData(
      colorSchemeSeed: Colors.indigo,
      brightness: Brightness.dark,
      useMaterial3: true,
    ),
    // Pages are tagged automatically from route names.
    navigatorObservers: [Kaleidoscope.navigatorObserver()],
    // Floating live cost bubble. Hidden automatically in release builds.
    builder: (context, child) =>
        AIUsageDebugOverlay(navigatorKey: navigatorKey, child: child!),
    initialRoute: '/home',
    routes: {
      '/home': (_) => const HomePage(),
      '/support/chat': (_) => const SupportChatPage(),
    },
  );
}

/// Pretend AI backends so the demo runs without API keys.
/// In a real app you would just use `Kaleidoscope.httpClient()`.
final http.Client fakeNetwork = MockClient.streaming(FakeAIBackend.handle);

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('kaleidoscope demo')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Each button makes a (fake) AI call through a different integration style. '
            'Watch the debug console and the floating bubble, then open the dashboard.',
          ),
          const SizedBox(height: 16),
          _Demo(
            title: 'Support chat (OpenAI via http.Client)',
            subtitle: 'Opens a page; calls are tagged support › /support/chat › composer',
            onTap: () => Navigator.pushNamed(context, '/support/chat'),
          ),
          _Demo(
            title: 'Shop suggestions (Claude via Dio, streaming)',
            subtitle: 'Kaleidoscope.scope(module: shop, page: cart, section: suggestions)',
            onTap: () => _claudeViaDio(context),
          ),
          _Demo(
            title: 'Notes summary (Gemini via SDK wrapper)',
            subtitle: 'Kaleidoscope.track(...) works with any SDK',
            onTap: () => _geminiWrapper(context),
          ),
          _Demo(
            title: 'On-device model (Gemini Nano / TFLite)',
            subtitle: 'trackOnDevice estimates tokens when the runtime does not report them',
            onTap: () => _onDevice(context),
          ),
          _Demo(
            title: 'Fallback: OpenAI fails, Claude answers',
            subtitle: 'Optional AIFallbackRouter',
            onTap: () => _fallback(context),
          ),
          _Demo(
            title: 'Estimate cost before sending',
            subtitle: 'Kaleidoscope.estimate(model, prompt)',
            onTap: () {
              final e = Kaleidoscope.estimate(
                model: 'gpt-4o',
                prompt: 'Summarise this article ' * 200,
                expectedOutputTokens: 300,
              );
              _toast(context, e.toString());
            },
          ),
          _Demo(
            title: 'Add 30 days of sample data',
            subtitle: 'So charts, trends and forecasts have something to show',
            onTap: () async {
              await _seed();
              if (context.mounted) _toast(context, 'Sample data added');
            },
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () => Kaleidoscope.openDashboard(context),
            icon: const Icon(Icons.insights),
            label: const Text('Open AI dashboard'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () async {
              final html = await Kaleidoscope.exportHtml();
              if (context.mounted) {
                _toast(
                  context,
                  'HTML report: ${html.length} characters (save or share it)',
                );
              }
            },
            icon: const Icon(Icons.description_outlined),
            label: const Text('Build HTML report'),
          ),
        ],
      ),
    );
  }

  Future<void> _claudeViaDio(BuildContext context) async {
    final dio = Dio()..httpClientAdapter = FakeAIBackend.dioAdapter();
    dio.interceptors.add(
      Kaleidoscope.dioInterceptor(),
    ); // <- the only tracker line
    final res = await Kaleidoscope.scope(
      module: 'shop',
      page: 'cart',
      section: 'suggestions',
      () => dio.post<ResponseBody>(
        'https://api.anthropic.com/v1/messages',
        data: {
          'model': 'claude-haiku-5-5',
          'max_tokens': 300,
          'stream': true,
          'messages': [
            {'role': 'user', 'content': 'Suggest 3 add-ons for a camping tent'},
          ],
        },
        options: Options(responseType: ResponseType.stream),
      ),
    );
    final text = await utf8.decodeStream(res.data!.stream);
    if (context.mounted) {
      _toast(context, 'Streamed ${text.length} bytes from Claude');
    }
  }

  Future<void> _geminiWrapper(BuildContext context) async {
    // Imagine `model.generateContent(...)` from any Gemini SDK here.
    final result = await Kaleidoscope.track<FakeSdkResponse>(
      provider: 'gemini',
      model: 'gemini-2.5-flash',
      prompt: 'Summarise my notes from today',
      parameters: {'temperature': 0.2},
      context: const AIUsageContext(
        module: 'notes',
        page: 'today',
        section: 'summary_card',
      ),
      call: () => FakeSdkResponse.generate('Summarise my notes from today'),
      usage: (r) => AITokenUsage(
        inputTokens: r.promptTokens,
        outputTokens: r.outputTokens,
      ),
      responseText: (r) => r.text,
    );
    if (context.mounted) _toast(context, result.text);
  }

  Future<void> _onDevice(BuildContext context) async {
    final out = await Kaleidoscope.instance.trackOnDevice<String>(
      model: 'gemini-nano',
      runtime: 'android-aicore',
      inputText: 'Rewrite this message to sound friendlier',
      context: const AIUsageContext(
        module: 'messages',
        page: 'compose',
        section: 'rewrite',
      ),
      call: () async {
        await Future<void>.delayed(const Duration(milliseconds: 120));
        return 'Hey! Would you mind taking a look when you get a chance?';
      },
      outputText: (r) => r,
    );
    if (context.mounted) _toast(context, out);
  }

  Future<void> _fallback(BuildContext context) async {
    final router = AIFallbackRouter();
    final answer = await router.run<String>([
      AIRoute(
        provider: 'openai',
        model: 'gpt-4o',
        call: () async => throw Exception('503 overloaded'),
      ),
      AIRoute(
        provider: 'anthropic',
        model: 'claude-sonnet-5-5',
        call: () async => 'Answer from Claude',
      ),
    ], context: const AIUsageContext(module: 'support', feature: 'fallback'));
    if (context.mounted) _toast(context, answer);
  }

  static Future<void> _seed() async {
    final store = Kaleidoscope.instance.store;
    if (store == null) return;
    final rnd = Random(7);
    final now = DateTime.now();
    const modules = {
      'support': ['/support/chat', '/support/tickets'],
      'shop': ['cart', 'product'],
      'notes': ['today', 'search'],
    };
    const models = [
      ('openai', 'gpt-4o-mini'),
      ('anthropic', 'claude-sonnet-5-5'),
      ('gemini', 'gemini-2.5-flash'),
    ];
    for (var d = 30; d >= 1; d--) {
      final calls = 8 + d % 5 + (30 - d) ~/ 3 + rnd.nextInt(4);
      for (var i = 0; i < calls; i++) {
        final m = modules.keys.elementAt(rnd.nextInt(3));
        final page = modules[m]![rnd.nextInt(2)];
        final (provider, model) = models[rnd.nextInt(3)];
        final usage = AITokenUsage(
          inputTokens: 300 + rnd.nextInt(1500),
          outputTokens: 80 + rnd.nextInt(600),
          cachedInputTokens: provider == 'anthropic' ? rnd.nextInt(2000) : 0,
        );
        final failed = rnd.nextDouble() < 0.04;
        await store.insert(
          AIUsageRecord(
            id: 'seed-$d-$i',
            timestamp: now.subtract(
              Duration(
                days: d,
                hours: rnd.nextInt(14),
                minutes: rnd.nextInt(60),
              ),
            ),
            provider: provider,
            model: model,
            usage: usage,
            cost: Kaleidoscope.pricing.costFor(
              model,
              usage,
              provider: provider,
            ),
            latencyMs: 400 + rnd.nextInt(2500),
            timeToFirstTokenMs: 150 + rnd.nextInt(500),
            status: failed ? AICallStatus.error : AICallStatus.success,
            errorMessage: failed ? 'Rate limit reached' : null,
            httpStatus: failed ? 429 : 200,
            context: AIUsageContext(
              module: m,
              page: page,
              section: ['main', 'sidebar'][rnd.nextInt(2)],
            ),
          ),
        );
      }
    }
    Kaleidoscope.instance.revision.value++;
  }
}

class SupportChatPage extends StatefulWidget {
  const SupportChatPage({super.key});
  @override
  State<SupportChatPage> createState() => _SupportChatPageState();
}

class _SupportChatPageState extends State<SupportChatPage> {
  // The only tracker line: wrap the client your code (or SDK) already uses.
  final client = Kaleidoscope.httpClient(fakeNetwork);
  final controller = TextEditingController(
    text: 'My order #123 has not arrived yet',
  );
  final messages = <String>[];
  bool busy = false;

  Future<void> send() async {
    setState(() => busy = true);
    try {
      // Calls inside this scope get module/section; page comes from the route.
      final res = await Kaleidoscope.scope(
        module: 'support',
        section: 'composer',
        () => client.post(
          Uri.parse('https://api.openai.com/v1/chat/completions'),
          headers: {
            'Authorization': 'Bearer YOUR_KEY',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'model': 'gpt-4o-mini',
            'temperature': 0.4,
            'messages': [
              {'role': 'system', 'content': 'You are a helpful support agent.'},
              {'role': 'user', 'content': controller.text},
            ],
          }),
        ),
      );
      final reply =
          (jsonDecode(res.body)['choices'] as List).first['message']['content']
              as String;
      setState(
        () => messages.addAll(['You: ${controller.text}', 'AI: $reply']),
      );
    } finally {
      setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AIUsageScope(
    module: 'support',
    page: '/support/chat',
    child: Scaffold(
      appBar: AppBar(title: const Text('Support chat')),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [for (final m in messages) Text(m)],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Expanded(child: TextField(controller: controller)),
                IconButton(
                  onPressed: busy ? null : send,
                  icon: const Icon(Icons.send),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class _Demo extends StatelessWidget {
  const _Demo({
    required this.title,
    required this.subtitle,
    required this.onTap,
  });
  final String title, subtitle;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Card(
    child: ListTile(
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.play_arrow),
      onTap: onTap,
    ),
  );
}

void _toast(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
