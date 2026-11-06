import 'package:kaleidoscope/kaleidoscope.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  testWidgets('analytics screen renders every tab with data', (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late KaleidoscopeTracker t;
    await tester.runAsync(() async {
      t = await newTracker(monthlyBudget: 5);
      final now = DateTime.now();
      final store = t.store!;
      for (var d = 0; d < 20; d++) {
        await store.insert(
          rec(
            at: now.subtract(Duration(days: d, hours: d)),
            cost: 0.1 * (d + 1),
            context: AIUsageContext(
              module: 'm${d % 3}',
              page: 'p${d % 2}',
              section: 's',
            ),
            status: d == 3 ? AICallStatus.error : AICallStatus.success,
          ),
        );
      }
    });
    await tester.pumpWidget(
      MaterialApp(home: AIAnalyticsScreen(tracker: t, initialRange: null)),
    );
    for (
      var i = 0;
      i < 20 && find.byType(CircularProgressIndicator).evaluate().isNotEmpty;
      i++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('Cost'), findsWidgets);
    for (final tab in ['Breakdown', 'Trends', 'Calls']) {
      await tester.tap(find.text(tab));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
    expect(find.textContaining('gpt-4o-mini'), findsWidgets);
    await tester.tap(find.textContaining('openai · gpt-4o-mini').first);
    await tester.pumpAndSettle();
    expect(find.text('Input tokens'), findsWidgets);
    await tester.runAsync(t.dispose);
  });

  testWidgets('PIN gate', (tester) async {
    late KaleidoscopeTracker t;
    await tester.runAsync(() async => t = await newTracker());
    await tester.pumpWidget(
      MaterialApp(
        home: AIAnalyticsScreen(tracker: t, accessPin: '1234'),
      ),
    );
    expect(find.text('Unlock'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '1234');
    await tester.tap(find.text('Unlock'));
    await tester.pump();
    expect(find.text('Unlock'), findsNothing);
    await tester.runAsync(t.dispose);
  });

  testWidgets('debug overlay shows live totals', (tester) async {
    late KaleidoscopeTracker t;
    await tester.runAsync(() async => t = await newTracker());
    await tester.pumpWidget(
      MaterialApp(
        home: AIUsageDebugOverlay(
          tracker: t,
          child: const Scaffold(body: Text('app')),
        ),
      ),
    );
    expect(find.textContaining('0 calls'), findsOneWidget);
    await tester.runAsync(() async {
      t.record(
        provider: 'openai',
        model: 'gpt-4o',
        inputTokens: 1000,
        outputTokens: 100,
      );
      await t.flush();
    });
    await tester.pump();
    expect(find.textContaining('1 calls'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(t.dispose);
  });

  testWidgets('AIUsageScope merges ancestors', (tester) async {
    late AIUsageContext ctx;
    await tester.pumpWidget(
      AIUsageScope(
        module: 'shop',
        child: AIUsageScope(
          page: 'cart',
          child: Builder(
            builder: (c) {
              ctx = AIUsageScope.of(c);
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    expect(ctx.module, 'shop');
    expect(ctx.page, 'cart');
  });
}
