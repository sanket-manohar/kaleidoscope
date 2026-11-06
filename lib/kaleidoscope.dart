/// Track tokens, cost, latency and errors of every AI call (any model, any
/// provider) with module / page / section tagging, encrypted local storage,
/// analytics, forecasts, charts and a drop-in dashboard.
library;

export 'src/analytics/ai_usage_analytics.dart';
export 'src/analytics/analytics_engine.dart';
export 'src/analytics/analytics_models.dart';
export 'src/capture/adapters/anthropic_adapter.dart';
export 'src/capture/adapters/cohere_adapter.dart';
export 'src/capture/adapters/gemini_adapter.dart';
export 'src/capture/adapters/generic_adapter.dart';
export 'src/capture/adapters/ollama_adapter.dart';
export 'src/capture/adapters/openai_compatible_adapter.dart';
export 'src/capture/ai_dio_interceptor.dart';
export 'src/capture/ai_http_client.dart';
export 'src/capture/provider_adapter.dart';
export 'src/capture/stream_decoder.dart';
export 'src/capture/token_estimator.dart';
export 'src/capture/usage_extractors.dart';
export 'src/config/redaction.dart';
export 'src/config/tracker_config.dart';
export 'src/core/kaleidoscope.dart';
export 'src/core/kaleidoscope_tracker.dart';
export 'src/core/fallback_router.dart';
export 'src/debug/ai_debug_logger.dart';
export 'src/export/usage_exporter.dart';
export 'src/models/ai_usage_context.dart';
export 'src/models/ai_usage_record.dart';
export 'src/pricing/pricing_table.dart';
export 'src/sinks/ai_usage_sink.dart' show AIUsageSink;
export 'src/sinks/http_sinks.dart';
export 'src/storage/secure_sqlite_store.dart';
export 'src/storage/usage_store.dart';
export 'src/widgets/ai_analytics_screen.dart';
export 'src/widgets/ai_debug_overlay.dart';
export 'src/widgets/ai_usage_charts.dart';
export 'src/widgets/ai_usage_scope.dart';
export 'src/widgets/format.dart';
