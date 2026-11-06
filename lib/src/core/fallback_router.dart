import 'kaleidoscope_tracker.dart';
import '../models/ai_usage_context.dart';

/// One provider option for [AIFallbackRouter].
class AIRoute<T> {
  const AIRoute({
    required this.provider,
    required this.model,
    required this.call,
    this.timeout,
  });
  final String provider;
  final String model;
  final Future<T> Function() call;
  final Duration? timeout;
  String get id => '$provider/$model';
}

/// Thrown when every route failed. [errors] holds each failure in order.
class AIAllRoutesFailedException implements Exception {
  AIAllRoutesFailedException(this.errors);
  final Map<String, Object> errors;
  @override
  String toString() =>
      'All AI routes failed: ${errors.entries.map((e) => '${e.key}: ${e.value}').join('; ')}';
}

/// Optional add-on: tries providers in order and falls back on failure,
/// with a simple circuit breaker. Each attempt is tracked (failures are
/// recorded as errors with `customData.fallback = true`).
///
/// Calls made through the tracked HTTP client / Dio are already recorded,
/// so set [trackAttempts] to false in that case to avoid double counting.
class AIFallbackRouter {
  AIFallbackRouter({
    KaleidoscopeTracker? tracker,
    this.failureThreshold = 3,
    this.cooldown = const Duration(minutes: 1),
    this.trackAttempts = true,
    this.shouldFallback,
  }) : _tracker = tracker ?? KaleidoscopeTracker.instance;

  final KaleidoscopeTracker _tracker;

  /// Consecutive failures before a route is skipped for [cooldown].
  final int failureThreshold;
  final Duration cooldown;
  final bool trackAttempts;

  /// Decide per error whether to try the next route (default: always).
  final bool Function(Object error)? shouldFallback;

  final _failures = <String, int>{};
  final _openUntil = <String, DateTime>{};

  bool isOpen(String routeId) {
    final until = _openUntil[routeId];
    return until != null && DateTime.now().isBefore(until);
  }

  Future<T> run<T>(
    List<AIRoute<T>> routes, {
    AIUsageContext? context,
    String? prompt,
  }) async {
    final errors = <String, Object>{};
    final available = routes.where((r) => !isOpen(r.id)).toList();
    final order = available.isEmpty ? routes : available;
    for (var i = 0; i < order.length; i++) {
      final route = order[i];
      try {
        Future<T> call() {
          final f = route.call();
          return route.timeout == null ? f : f.timeout(route.timeout!);
        }

        final T result = trackAttempts
            ? await _tracker.track<T>(
                provider: route.provider,
                model: route.model,
                prompt: prompt,
                context: context,
                customData: {'fallback': i > 0, 'attempt': i + 1},
                call: call,
              )
            : await call();
        _failures[route.id] = 0;
        _openUntil.remove(route.id);
        return result;
      } catch (e) {
        errors[route.id] = e;
        final n = (_failures[route.id] ?? 0) + 1;
        _failures[route.id] = n;
        if (n >= failureThreshold) {
          _openUntil[route.id] = DateTime.now().add(cooldown);
        }
        _tracker.logger.internal(
          'route ${route.id} failed${i + 1 < order.length ? ', falling back' : ''}',
          e,
        );
        if (shouldFallback != null && !shouldFallback!(e)) rethrow;
      }
    }
    throw AIAllRoutesFailedException(errors);
  }
}
