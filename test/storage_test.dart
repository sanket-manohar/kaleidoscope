import 'dart:io';

import 'package:kaleidoscope/kaleidoscope.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as ffi;

import 'helpers.dart';

void main() {
  final now = DateTime.now();

  Future<void> exercise(UsageStore store) async {
    await store.open();
    await store.insert(
      rec(
        at: now.subtract(const Duration(days: 40)),
        prompt: 'old secret',
        context: const AIUsageContext(module: 'a', page: 'x'),
      ),
    );
    await store.insert(
      rec(
        at: now.subtract(const Duration(days: 10)),
        prompt: 'mid',
        model: 'claude-haiku-5-5',
        context: const AIUsageContext(module: 'b'),
      ),
    );
    await store.insert(rec(at: now, prompt: 'new', status: AICallStatus.error));
    expect(await store.count(), 3);
    expect(
      (await store.query(const UsageQuery(modules: {'a'}))).single.prompt,
      'old secret',
    );
    expect(
      (await store.query(const UsageQuery(search: 'haiku'))).single.model,
      'claude-haiku-5-5',
    );
    expect(
      (await store.query(const UsageQuery(status: AICallStatus.error))),
      hasLength(1),
    );
    expect(
      (await store.query(const UsageQuery(limit: 1))).single.prompt,
      'new',
    );
    expect(
      await store.stripTextOlderThan(now.subtract(const Duration(days: 30))),
      1,
    );
    expect(
      (await store.query(const UsageQuery(modules: {'a'}))).single.prompt,
      isNull,
    );
    expect(
      await store.deleteOlderThan(now.subtract(const Duration(days: 30))),
      1,
    );
    expect(await store.trimTo(1), 1);
    expect((await store.query(UsageQuery.all)).single.prompt, 'new');
    await store.writeValue('k', 'v');
    expect(await store.readValue('k'), 'v');
    await store.clear();
    expect(await store.count(), 0);
    await store.close();
  }

  test('in-memory store', () => exercise(InMemoryUsageStore()));

  test('SQLite store (same code path as SQLCipher, via ffi)', () async {
    ffi.sqfliteFfiInit();
    final dir = await Directory.systemTemp.createTemp('aiut');
    final store = SecureSqliteUsageStore(
      directory: dir.path,
      keyProvider: () async => 'test-key',
      opener:
          (path, {required password, required version, required onCreate}) =>
              ffi.databaseFactoryFfi.openDatabase(
                path,
                options: ffi.OpenDatabaseOptions(
                  version: version,
                  onCreate: onCreate,
                ),
              ),
    );
    await exercise(store);
    await dir.delete(recursive: true);
  });

  test('retention policy runs on the tracker', () async {
    final store = InMemoryUsageStore();
    await store.insert(
      rec(at: now.subtract(const Duration(days: 10)), prompt: 'p1'),
    );
    await store.insert(
      rec(at: now.subtract(const Duration(days: 3)), prompt: 'p2', input: 2),
    );
    await store.insert(rec(at: now, prompt: 'p3', input: 3));
    final t = await newTracker(
      store: store,
      retention: const RetentionPolicy(
        maxAge: Duration(days: 7),
        maxRecords: 10,
        textMaxAge: Duration(days: 1),
      ),
    );
    await t.runRetention();
    final rs = await t.records();
    expect(rs, hasLength(2));
    expect(rs.first.prompt, 'p3');
    expect(rs.last.prompt, isNull);
    await t.dispose();
  });

  test('pricing overrides persist across restarts', () async {
    final store = InMemoryUsageStore();
    final t1 = await newTracker(store: store);
    t1.pricing.setPrice(
      'house-model',
      const ModelPrice(inputPerMillion: 7, outputPerMillion: 7),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final t2 = await newTracker(store: store);
    expect(t2.pricing.lookup('house-model')!.inputPerMillion, 7);
    await t1.dispose();
    await t2.dispose();
  });

  test('record JSON round trip', () {
    final r = rec(
      at: DateTime(2026, 1, 2, 3, 4, 5),
      prompt: 'x',
      context: const AIUsageContext(module: 'm', tags: ['t'], custom: {'k': 1}),
    );
    final back = AIUsageRecord.fromJson(r.toJson());
    expect(back.toJson(), r.toJson());
  });
}
