import '../models/ai_usage_context.dart';
import '../models/ai_usage_record.dart';
import '../pricing/pricing_table.dart';
import '../storage/usage_store.dart';
import 'redaction.dart';

/// What to keep of prompt and response text.
enum PromptStorageMode {
  /// Store only metadata (model, tokens, params, tags). The default.
  metadataOnly,

  /// Store text after running the redactors (emails, phones, keys, cards...).
  redacted,

  /// Store full text as-is (still encrypted at rest).
  full,
}

/// Developer-defined retention rules. Cleanup runs at start-up and then
/// every [cleanupInterval].
class RetentionPolicy {
  const RetentionPolicy({
    this.maxAge = const Duration(days: 90),
    this.maxRecords = 50000,
    this.textMaxAge,
    this.cleanupInterval = const Duration(hours: 6),
  });

  /// Delete records older than this. `null` keeps them forever.
  final Duration? maxAge;

  /// Keep at most this many records (oldest deleted first). `null` = no cap.
  final int? maxRecords;

  /// Strip prompt/response text from records older than this, but keep the
  /// metadata (tokens, cost, tags). Useful for privacy policies like
  /// "prompts kept 7 days, usage kept 1 year".
  final Duration? textMaxAge;

  final Duration cleanupInterval;

  static const keepForever = RetentionPolicy(maxAge: null, maxRecords: null);
}

/// Console output level for debug builds.
enum AIDebugLogLevel { off, errors, summary, verbose }

class AIDebugLogConfig {
  const AIDebugLogConfig({
    this.level = AIDebugLogLevel.summary,
    this.useColors = true,
    this.showPromptText = false,
    this.onlyInDebugMode = true,
  });

  final AIDebugLogLevel level;

  /// ANSI colours (VS Code / Android Studio consoles support them).
  final bool useColors;

  /// Print (truncated) prompt and response text. Off by default.
  final bool showPromptText;

  /// When true (default) nothing is printed in profile/release builds.
  final bool onlyInDebugMode;

  static const off = AIDebugLogConfig(level: AIDebugLogLevel.off);
}

/// Hook to change or drop a record right before it is saved.
/// Return `null` to drop it.
typedef AIRecordTransformer = AIUsageRecord? Function(AIUsageRecord record);

/// Called when the tracker itself hits an internal error. The app's AI call
/// is never affected.
typedef KaleidoscopeErrorHandler =
    void Function(Object error, StackTrace stack);

class KaleidoscopeConfig {
  const KaleidoscopeConfig({
    this.enabled = true,
    this.promptStorage = PromptStorageMode.metadataOnly,
    this.maxStoredTextLength = 20000,
    this.redactors = Redactors.defaults,
    this.retention = const RetentionPolicy(),
    this.debugLog = const AIDebugLogConfig(),
    this.store,
    this.databaseName = 'kaleidoscope.db',
    this.pricing,
    this.remotePricingUrl,
    this.remotePricingHeaders = const {},
    this.pricingRefreshInterval = const Duration(hours: 24),
    this.captureParameters = true,
    this.estimateMissingTokens = true,
    this.injectStreamUsageOption = false,
    this.additionalHostsToTrack = const [],
    this.ignoredHosts = const [],
    this.beforeSave,
    this.onError,
    this.defaultContext,
    this.monthlyBudget,
  });

  /// Master switch. When false every call passes straight through.
  final bool enabled;

  /// Whether to store prompts/responses, redacted text, or metadata only.
  final PromptStorageMode promptStorage;

  /// Text longer than this is truncated before storage.
  final int maxStoredTextLength;

  /// Applied when [promptStorage] is [PromptStorageMode.redacted], and always
  /// for debug-console output.
  final List<Redactor> redactors;

  final RetentionPolicy retention;
  final AIDebugLogConfig debugLog;

  /// Custom storage backend. Defaults to the encrypted SQLCipher store.
  final UsageStore? store;
  final String databaseName;

  /// Initial pricing table. Defaults to [PricingTable.withDefaults].
  final PricingTable? pricing;

  /// JSON endpoint to refresh prices from (see README for the format).
  final Uri? remotePricingUrl;
  final Map<String, String> remotePricingHeaders;
  final Duration pricingRefreshInterval;

  /// Record request parameters such as temperature or max_tokens.
  final bool captureParameters;

  /// When a provider does not report usage, estimate it from text length
  /// (about 4 characters per token) and flag the record as estimated.
  final bool estimateMissingTokens;

  /// For OpenAI-compatible streaming requests, add
  /// `stream_options: {include_usage: true}` so exact usage is reported.
  /// Off by default because it changes the outgoing request.
  final bool injectStreamUsageOption;

  /// Extra hosts whose traffic the HTTP interceptors should inspect, on top
  /// of the known AI endpoint paths (useful for custom gateways).
  final List<String> additionalHostsToTrack;

  /// Hosts the HTTP interceptors must never inspect.
  final List<String> ignoredHosts;

  final AIRecordTransformer? beforeSave;
  final KaleidoscopeErrorHandler? onError;

  /// Context applied to every record (e.g. app flavour or user id).
  final AIUsageContext? defaultContext;

  /// Optional monthly budget used by the budget analytics and screen.
  final double? monthlyBudget;
}
