import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/ai_usage_record.dart';

/// Price of one model, in [currency] per one million tokens.
class ModelPrice {
  const ModelPrice({
    required this.inputPerMillion,
    required this.outputPerMillion,
    this.cachedInputPerMillion,
    this.cacheWritePerMillion,
    this.currency = 'USD',
  });

  final double inputPerMillion;
  final double outputPerMillion;

  /// Defaults to [inputPerMillion] when null.
  final double? cachedInputPerMillion;

  /// Defaults to [inputPerMillion] when null.
  final double? cacheWritePerMillion;
  final String currency;

  static const free = ModelPrice(inputPerMillion: 0, outputPerMillion: 0);

  AICost costFor(AITokenUsage u) {
    const m = 1000000.0;
    return AICost(
      input: u.inputTokens * inputPerMillion / m,
      output: u.outputTokens * outputPerMillion / m,
      cached:
          u.cachedInputTokens * (cachedInputPerMillion ?? inputPerMillion) / m +
          u.cacheWriteTokens * (cacheWritePerMillion ?? inputPerMillion) / m,
      currency: currency,
    );
  }

  Map<String, Object?> toJson() => {
    'input': inputPerMillion,
    'output': outputPerMillion,
    if (cachedInputPerMillion != null) 'cachedInput': cachedInputPerMillion,
    if (cacheWritePerMillion != null) 'cacheWrite': cacheWritePerMillion,
    'currency': currency,
  };

  factory ModelPrice.fromJson(
    Map<String, Object?> j, {
    String defaultCurrency = 'USD',
  }) => ModelPrice(
    inputPerMillion: (j['input'] as num).toDouble(),
    outputPerMillion: (j['output'] as num).toDouble(),
    cachedInputPerMillion: (j['cachedInput'] as num?)?.toDouble(),
    cacheWritePerMillion: (j['cacheWrite'] as num?)?.toDouble(),
    currency: j['currency'] as String? ?? defaultCurrency,
  );
}

/// Updatable model → price lookup.
///
/// Keys are model names or patterns with a trailing or leading `*`
/// (`gpt-4o*`, `*-mini`). Optionally prefix with `provider:` to scope a key
/// (`ollama:*`). The most specific (longest) matching key wins; exact keys
/// beat patterns.
class PricingTable {
  PricingTable([Map<String, ModelPrice>? entries]) : _entries = {...?entries};

  /// Starts with [defaultPrices].
  factory PricingTable.withDefaults() => PricingTable(defaultPrices);

  final Map<String, ModelPrice> _entries;
  String? _version;
  DateTime? _updatedAt;

  final _listeners = <void Function()>[];

  String? get version => _version;
  DateTime? get updatedAt => _updatedAt;
  Map<String, ModelPrice> get entries => Map.unmodifiable(_entries);

  void addListener(void Function() l) => _listeners.add(l);
  void removeListener(void Function() l) => _listeners.remove(l);
  void _changed() {
    _updatedAt = DateTime.now();
    for (final l in List.of(_listeners)) {
      try {
        l();
      } catch (_) {}
    }
  }

  /// Add or replace one price at runtime.
  void setPrice(String modelPattern, ModelPrice price) {
    _entries[modelPattern.toLowerCase()] = price;
    _changed();
  }

  void removePrice(String modelPattern) {
    _entries.remove(modelPattern.toLowerCase());
    _changed();
  }

  /// Merge many prices; with [replace] the table is cleared first.
  void setAll(Map<String, ModelPrice> prices, {bool replace = false}) {
    if (replace) _entries.clear();
    prices.forEach((k, v) => _entries[k.toLowerCase()] = v);
    _changed();
  }

  /// Finds the price for [model], or null if nothing matches.
  ModelPrice? lookup(String model, {String? provider}) {
    final m = model.toLowerCase();
    final p = provider?.toLowerCase();
    final candidates = <String>[
      if (p != null) '$p:$m',
      m,
      // Strip vendor prefixes like "openai/gpt-4o" (OpenRouter) or
      // "anthropic.claude-..." (Bedrock).
      if (m.contains('/')) m.substring(m.lastIndexOf('/') + 1),
      if (m.startsWith('anthropic.')) m.substring('anthropic.'.length),
    ];
    for (final c in candidates) {
      final exact = _entries[c];
      if (exact != null) return exact;
    }
    String? bestKey;
    for (final key in _entries.keys) {
      for (final c in candidates) {
        if (_matches(key, c, p) &&
            (bestKey == null || key.length > bestKey.length)) {
          bestKey = key;
        }
      }
    }
    return bestKey == null ? null : _entries[bestKey];
  }

  static bool _matches(String key, String model, String? provider) {
    var k = key;
    final colon = k.indexOf(':');
    if (colon > 0) {
      if (provider == null || k.substring(0, colon) != provider) return false;
      k = k.substring(colon + 1);
    }
    if (k == '*') return true;
    if (k.endsWith('*') && k.startsWith('*')) {
      return model.contains(k.substring(1, k.length - 1));
    }
    if (k.endsWith('*')) return model.startsWith(k.substring(0, k.length - 1));
    if (k.startsWith('*')) return model.endsWith(k.substring(1));
    return k == model;
  }

  AICost costFor(String model, AITokenUsage usage, {String? provider}) {
    final price = lookup(model, provider: provider);
    return price == null ? AICost.unpriced : price.costFor(usage);
  }

  /// Load prices from JSON:
  /// ```json
  /// {"version":"2026-11","currency":"USD",
  ///  "models":{"gpt-4o*":{"input":2.5,"output":10,"cachedInput":1.25}}}
  /// ```
  void loadJson(Map<String, Object?> json, {bool replace = false}) {
    final currency = json['currency'] as String? ?? 'USD';
    final models = (json['models'] as Map?)?.cast<String, Object?>() ?? {};
    final parsed = <String, ModelPrice>{};
    models.forEach((k, v) {
      if (v is Map) {
        parsed[k] = ModelPrice.fromJson(
          v.cast<String, Object?>(),
          defaultCurrency: currency,
        );
      }
    });
    _version = json['version']?.toString() ?? _version;
    setAll(parsed, replace: replace);
  }

  String toJsonString() => jsonEncode(toJson());

  Map<String, Object?> toJson() => {
    if (_version != null) 'version': _version,
    'models': _entries.map((k, v) => MapEntry(k, v.toJson())),
  };

  /// Fetches prices from [url] and merges them. Returns false (and keeps the
  /// current table) on any failure.
  Future<bool> loadFromUrl(
    Uri url, {
    Map<String, String>? headers,
    http.Client? client,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final c = client ?? http.Client();
    try {
      final res = await c.get(url, headers: headers).timeout(timeout);
      if (res.statusCode < 200 || res.statusCode >= 300) return false;
      final decoded = jsonDecode(res.body);
      if (decoded is! Map) return false;
      loadJson(decoded.cast<String, Object?>());
      return true;
    } catch (_) {
      return false;
    } finally {
      if (client == null) c.close();
    }
  }

  /// Built-in starting prices (USD per 1M tokens). Prices change often:
  /// override them at runtime with [setPrice] / [loadJson], or point
  /// `remotePricingUrl` at a JSON file you control.
  static final Map<String, ModelPrice> defaultPrices = {
    // Anthropic (first-party API rates).
    'claude-fable-5*': _p(10, 50, 1.0, 12.5),
    'claude-opus-5-5*': _p(4, 20, 0.4, 5),
    'claude-opus-5*': _p(5, 25, 0.5, 6.25),
    'claude-opus-4*': _p(5, 25, 0.5, 6.25),
    'claude-sonnet-5*': _p(2, 10, 0.2, 2.5),
    'claude-sonnet-4*': _p(3, 15, 0.3, 3.75),
    'claude-haiku-5-5*': _p(0.10, 0.50, 0.01, 0.125),
    'claude-haiku-4*': _p(1, 5, 0.1, 1.25),
    // OpenAI (approximate).
    'gpt-5*': _p(1.25, 10, 0.125),
    'gpt-5-mini*': _p(0.25, 2, 0.025),
    'gpt-5-nano*': _p(0.05, 0.40, 0.005),
    'gpt-4.1*': _p(2, 8, 0.5),
    'gpt-4.1-mini*': _p(0.40, 1.60, 0.10),
    'gpt-4.1-nano*': _p(0.10, 0.40, 0.025),
    'gpt-4o*': _p(2.5, 10, 1.25),
    'gpt-4o-mini*': _p(0.15, 0.60, 0.075),
    'o3*': _p(2, 8, 0.5),
    'o4-mini*': _p(1.10, 4.40, 0.275),
    'text-embedding-3-small': _p(0.02, 0),
    'text-embedding-3-large': _p(0.13, 0),
    // Google Gemini (approximate, <=200k prompt tier).
    'gemini-2.5-pro*': _p(1.25, 10, 0.31),
    'gemini-2.5-flash*': _p(0.30, 2.50, 0.075),
    'gemini-2.5-flash-lite*': _p(0.10, 0.40, 0.025),
    'gemini-2.0-flash*': _p(0.10, 0.40, 0.025),
    // Others (approximate).
    'mistral-large*': _p(2, 6),
    'mistral-small*': _p(0.10, 0.30),
    'deepseek-chat*': _p(0.27, 1.10, 0.07),
    'deepseek-reasoner*': _p(0.55, 2.19, 0.14),
    'command-r-plus*': _p(2.5, 10),
    'command-r*': _p(0.15, 0.60),
    // Local models cost nothing per token.
    'ollama:*': ModelPrice.free,
  };

  static ModelPrice _p(double i, double o, [double? cached, double? write]) =>
      ModelPrice(
        inputPerMillion: i,
        outputPerMillion: o,
        cachedInputPerMillion: cached,
        cacheWritePerMillion: write,
      );
}
