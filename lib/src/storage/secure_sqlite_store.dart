import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_sqlcipher/sqflite.dart' as cipher;

import '../models/ai_usage_record.dart';
import 'usage_store.dart';

/// Opens a database. Override in tests (e.g. with sqflite_common_ffi).
typedef DatabaseOpener =
    Future<cipher.Database> Function(
      String path, {
      required String password,
      required int version,
      required cipher.OnDatabaseCreateFn onCreate,
    });

/// Provides the database password. Defaults to a random 256-bit key kept in
/// the iOS Keychain / Android Keystore via flutter_secure_storage.
typedef KeyProvider = Future<String> Function();

/// Encrypted store: the whole SQLite file is encrypted with SQLCipher
/// (AES-256), and the key never leaves the platform's secure storage.
class SecureSqliteUsageStore implements UsageStore {
  SecureSqliteUsageStore({
    this.databaseName = 'kaleidoscope.db',
    this.directory,
    KeyProvider? keyProvider,
    DatabaseOpener? opener,
    FlutterSecureStorage? secureStorage,
  }) : _keyProvider = keyProvider,
       _opener = opener,
       _secure = secureStorage ?? const FlutterSecureStorage();

  final String databaseName;
  final String? directory;
  final KeyProvider? _keyProvider;
  final DatabaseOpener? _opener;
  final FlutterSecureStorage _secure;
  cipher.Database? _db;

  static const _keyName = 'kaleidoscope.db_key.v1';
  static const _table = 'records';

  cipher.Database get _d {
    final db = _db;
    if (db == null) throw StateError('SecureSqliteUsageStore not opened');
    return db;
  }

  Future<String> _defaultKey() async {
    final existing = await _secure.read(key: _keyName);
    if (existing != null && existing.isNotEmpty) return existing;
    final rnd = Random.secure();
    final key = base64UrlEncode(
      List<int>.generate(32, (_) => rnd.nextInt(256)),
    );
    await _secure.write(key: _keyName, value: key);
    return key;
  }

  @override
  Future<void> open() async {
    if (_db != null) return;
    final dir = directory ?? await cipher.getDatabasesPath();
    final path = p.join(dir, databaseName);
    final password = await (_keyProvider ?? _defaultKey)();
    Future<void> onCreate(cipher.Database db, int version) async {
      await db.execute('''
        CREATE TABLE $_table (
          id TEXT PRIMARY KEY,
          ts INTEGER NOT NULL,
          provider TEXT,
          model TEXT,
          module TEXT,
          page TEXT,
          section TEXT,
          status TEXT,
          has_text INTEGER NOT NULL DEFAULT 0,
          data TEXT NOT NULL
        )''');
      await db.execute('CREATE INDEX idx_${_table}_ts ON $_table(ts)');
      await db.execute(
        'CREATE INDEX idx_${_table}_dims ON $_table(module, page, section)',
      );
      await db.execute('CREATE TABLE kv (k TEXT PRIMARY KEY, v TEXT NOT NULL)');
    }

    final opener = _opener;
    _db = opener != null
        ? await opener(path, password: password, version: 1, onCreate: onCreate)
        : await cipher.openDatabase(
            path,
            password: password,
            version: 1,
            onCreate: onCreate,
          );
  }

  Map<String, Object?> _row(AIUsageRecord r) => {
    'id': r.id,
    'ts': r.timestamp.millisecondsSinceEpoch,
    'provider': r.provider,
    'model': r.model,
    'module': r.context.module,
    'page': r.context.page,
    'section': r.context.section,
    'status': r.status.name,
    'has_text': (r.prompt != null || r.response != null) ? 1 : 0,
    'data': jsonEncode(r.toJson()),
  };

  AIUsageRecord _fromRow(Map<String, Object?> row) => AIUsageRecord.fromJson(
    (jsonDecode(row['data'] as String) as Map).cast<String, Object?>(),
  );

  (String, List<Object?>) _where(UsageQuery q) {
    final parts = <String>[];
    final args = <Object?>[];
    void inSet(String col, Set<String>? values) {
      if (values == null) return;
      if (values.isEmpty) {
        parts.add('0');
        return;
      }
      parts.add('$col IN (${List.filled(values.length, '?').join(',')})');
      args.addAll(values);
    }

    if (q.from != null) {
      parts.add('ts >= ?');
      args.add(q.from!.millisecondsSinceEpoch);
    }
    if (q.to != null) {
      parts.add('ts < ?');
      args.add(q.to!.millisecondsSinceEpoch);
    }
    inSet('provider', q.providers);
    inSet('model', q.models);
    inSet('module', q.modules);
    inSet('page', q.pages);
    inSet('section', q.sections);
    if (q.status != null) {
      parts.add('status = ?');
      args.add(q.status!.name);
    }
    final s = q.search?.trim();
    if (s != null && s.isNotEmpty) {
      parts.add('data LIKE ?');
      args.add('%${s.replaceAll('%', r'\%')}%');
    }
    return (parts.isEmpty ? '' : parts.join(' AND '), args);
  }

  @override
  Future<void> insert(AIUsageRecord record) async {
    await _d.insert(
      _table,
      _row(record),
      conflictAlgorithm: cipher.ConflictAlgorithm.replace,
    );
  }

  @override
  Future<List<AIUsageRecord>> query(UsageQuery q) async {
    final (where, args) = _where(q);
    final rows = await _d.query(
      _table,
      columns: ['data'],
      where: where.isEmpty ? null : where,
      whereArgs: args,
      orderBy: 'ts ${q.newestFirst ? 'DESC' : 'ASC'}',
      limit: q.limit,
      offset: q.limit == null ? null : q.offset,
    );
    final out = <AIUsageRecord>[];
    for (final row in rows) {
      try {
        final r = _fromRow(row);
        // Re-check in Dart: LIKE on JSON is broader than our search.
        if (q.matches(r)) out.add(r);
      } catch (_) {
        // Skip a corrupted row instead of failing the whole query.
      }
    }
    return out;
  }

  @override
  Future<int> count([UsageQuery q = UsageQuery.all]) async {
    final (where, args) = _where(q);
    final res = await _d.rawQuery(
      'SELECT COUNT(*) AS c FROM $_table${where.isEmpty ? '' : ' WHERE $where'}',
      args,
    );
    return (res.first['c'] as num?)?.toInt() ?? 0;
  }

  @override
  Future<int> deleteOlderThan(DateTime cutoff) => _d.delete(
    _table,
    where: 'ts < ?',
    whereArgs: [cutoff.millisecondsSinceEpoch],
  );

  @override
  Future<int> trimTo(int maxRecords) => _d.rawDelete(
    'DELETE FROM $_table WHERE id NOT IN '
    '(SELECT id FROM $_table ORDER BY ts DESC LIMIT ?)',
    [maxRecords],
  );

  @override
  Future<int> stripTextOlderThan(DateTime cutoff) async {
    final rows = await _d.query(
      _table,
      columns: ['data'],
      where: 'ts < ? AND has_text = 1',
      whereArgs: [cutoff.millisecondsSinceEpoch],
    );
    if (rows.isEmpty) return 0;
    final batch = _d.batch();
    for (final row in rows) {
      final r = _fromRow(row).copyWith(clearText: true);
      batch.update(_table, _row(r), where: 'id = ?', whereArgs: [r.id]);
    }
    await batch.commit(noResult: true);
    return rows.length;
  }

  @override
  Future<void> deleteRecord(String id) =>
      _d.delete(_table, where: 'id = ?', whereArgs: [id]);

  @override
  Future<void> clear() => _d.delete(_table);

  @override
  Future<String?> readValue(String key) async {
    final rows = await _d.query(
      'kv',
      where: 'k = ?',
      whereArgs: [key],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['v'] as String?;
  }

  @override
  Future<void> writeValue(String key, String value) => _d.insert('kv', {
    'k': key,
    'v': value,
  }, conflictAlgorithm: cipher.ConflictAlgorithm.replace);

  @override
  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
