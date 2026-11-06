import '../models/ai_usage_record.dart';

/// Filter for reading records.
class UsageQuery {
  const UsageQuery({
    this.from,
    this.to,
    this.providers,
    this.models,
    this.modules,
    this.pages,
    this.sections,
    this.status,
    this.search,
    this.limit,
    this.offset = 0,
    this.newestFirst = true,
  });

  final DateTime? from;
  final DateTime? to;
  final Set<String>? providers;
  final Set<String>? models;
  final Set<String>? modules;
  final Set<String>? pages;
  final Set<String>? sections;
  final AICallStatus? status;

  /// Case-insensitive search over model, provider, tags, error and text.
  final String? search;
  final int? limit;
  final int offset;
  final bool newestFirst;

  static const all = UsageQuery();

  UsageQuery copyWith({
    DateTime? from,
    DateTime? to,
    int? limit,
    String? search,
  }) => UsageQuery(
    from: from ?? this.from,
    to: to ?? this.to,
    providers: providers,
    models: models,
    modules: modules,
    pages: pages,
    sections: sections,
    status: status,
    search: search ?? this.search,
    limit: limit ?? this.limit,
    offset: offset,
    newestFirst: newestFirst,
  );

  bool matches(AIUsageRecord r) {
    if (from != null && r.timestamp.isBefore(from!)) return false;
    if (to != null && !r.timestamp.isBefore(to!)) return false;
    if (providers != null && !providers!.contains(r.provider)) return false;
    if (models != null && !models!.contains(r.model)) return false;
    if (modules != null && !modules!.contains(r.context.module)) return false;
    if (pages != null && !pages!.contains(r.context.page)) return false;
    if (sections != null && !sections!.contains(r.context.section)) {
      return false;
    }
    if (status != null && r.status != status) return false;
    final s = search?.trim().toLowerCase();
    if (s != null && s.isNotEmpty) {
      final hay = [
        r.model,
        r.provider,
        r.operation,
        r.context.toString(),
        ...r.context.tags,
        r.errorMessage ?? '',
        r.prompt ?? '',
        r.response ?? '',
      ].join('\n').toLowerCase();
      if (!hay.contains(s)) return false;
    }
    return true;
  }
}

/// Storage backend. Implement this to store records anywhere (your own DB,
/// a remote API...). All methods may throw; the tracker catches everything.
abstract class UsageStore {
  Future<void> open();
  Future<void> insert(AIUsageRecord record);
  Future<List<AIUsageRecord>> query(UsageQuery query);
  Future<int> count([UsageQuery query = UsageQuery.all]);

  /// Deletes records with timestamp before [cutoff]. Returns rows deleted.
  Future<int> deleteOlderThan(DateTime cutoff);

  /// Keeps only the newest [maxRecords]. Returns rows deleted.
  Future<int> trimTo(int maxRecords);

  /// Removes prompt/response text from records before [cutoff].
  Future<int> stripTextOlderThan(DateTime cutoff);
  Future<void> deleteRecord(String id);
  Future<void> clear();

  /// Small key/value area (pricing overrides, settings).
  Future<String?> readValue(String key);
  Future<void> writeValue(String key, String value);
  Future<void> close();
}

/// Non-persistent store, handy for tests, web previews and demos.
class InMemoryUsageStore implements UsageStore {
  final List<AIUsageRecord> _records = [];
  final Map<String, String> _kv = {};

  @override
  Future<void> open() async {}

  @override
  Future<void> insert(AIUsageRecord record) async => _records.add(record);

  @override
  Future<List<AIUsageRecord>> query(UsageQuery q) async {
    final list = _records.where(q.matches).toList()
      ..sort(
        (a, b) => q.newestFirst
            ? b.timestamp.compareTo(a.timestamp)
            : a.timestamp.compareTo(b.timestamp),
      );
    final start = q.offset.clamp(0, list.length);
    final end = q.limit == null
        ? list.length
        : (start + q.limit!).clamp(0, list.length);
    return list.sublist(start, end);
  }

  @override
  Future<int> count([UsageQuery q = UsageQuery.all]) async =>
      _records.where(q.matches).length;

  @override
  Future<int> deleteOlderThan(DateTime cutoff) async {
    final before = _records.length;
    _records.removeWhere((r) => r.timestamp.isBefore(cutoff));
    return before - _records.length;
  }

  @override
  Future<int> trimTo(int maxRecords) async {
    if (_records.length <= maxRecords) return 0;
    _records.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    final n = _records.length - maxRecords;
    _records.removeRange(0, n);
    return n;
  }

  @override
  Future<int> stripTextOlderThan(DateTime cutoff) async {
    var n = 0;
    for (var i = 0; i < _records.length; i++) {
      final r = _records[i];
      if (r.timestamp.isBefore(cutoff) &&
          (r.prompt != null || r.response != null)) {
        _records[i] = r.copyWith(clearText: true);
        n++;
      }
    }
    return n;
  }

  @override
  Future<void> deleteRecord(String id) async =>
      _records.removeWhere((r) => r.id == id);

  @override
  Future<void> clear() async => _records.clear();

  @override
  Future<String?> readValue(String key) async => _kv[key];

  @override
  Future<void> writeValue(String key, String value) async => _kv[key] = value;

  @override
  Future<void> close() async {}
}
