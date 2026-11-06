import 'package:flutter/widgets.dart';

import '../core/kaleidoscope_tracker.dart';
import '../models/ai_usage_context.dart';

/// Tags a part of the widget tree with module / page / section.
///
/// ```dart
/// AIUsageScope(module: 'shop', page: 'cart', child: CartPage());
/// // ...inside, when calling AI:
/// AIUsageScope.run(context, () => api.suggest(items), section: 'suggestions');
/// ```
/// Scopes nest: inner values win.
class AIUsageScope extends InheritedWidget {
  AIUsageScope({
    super.key,
    String? module,
    String? page,
    String? section,
    String? feature,
    List<String> tags = const [],
    Map<String, Object?> custom = const {},
    required super.child,
  }) : value = AIUsageContext(
         module: module,
         page: page,
         section: section,
         feature: feature,
         tags: tags,
         custom: custom,
       );

  const AIUsageScope.withContext({
    super.key,
    required this.value,
    required super.child,
  });

  final AIUsageContext value;

  /// Merged context of every enclosing scope.
  static AIUsageContext of(BuildContext context) {
    final scopes = <AIUsageContext>[];
    context.visitAncestorElements((e) {
      final w = e.widget;
      if (w is AIUsageScope) scopes.add(w.value);
      return true;
    });
    var out = AIUsageContext.empty;
    for (final s in scopes.reversed) {
      out = out.merge(s);
    }
    final self = context.widget;
    if (self is AIUsageScope) out = out.merge(self.value);
    return out;
  }

  /// Runs [body] with this widget tree's scope (plus [section] etc.) applied
  /// to every AI call inside, including HTTP-intercepted ones.
  static R run<R>(
    BuildContext context,
    R Function() body, {
    String? section,
    String? feature,
    Map<String, Object?> custom = const {},
  }) {
    final ctx = of(
      context,
    ).merge(AIUsageContext(section: section, feature: feature, custom: custom));
    return KaleidoscopeTracker.runWithContext(ctx, body);
  }

  @override
  bool updateShouldNotify(AIUsageScope oldWidget) => false;
}

/// Tags calls with the current route name as `page` automatically.
///
/// `MaterialApp(navigatorObservers: [Kaleidoscope.navigatorObserver()])`
class AIUsageNavigatorObserver extends NavigatorObserver {
  AIUsageNavigatorObserver({KaleidoscopeTracker? tracker, this.moduleForRoute})
    : _tracker = tracker ?? KaleidoscopeTracker.instance;

  final KaleidoscopeTracker _tracker;

  /// Optional: map a route name to a module (e.g. `/shop/cart` → `shop`).
  /// By default the first path segment is used when the name has two or
  /// more segments.
  final String? Function(String routeName)? moduleForRoute;

  void _set(Route<dynamic>? route) {
    final name = route?.settings.name;
    if (name == null || name.isEmpty) return;
    String? module;
    if (moduleForRoute != null) {
      module = moduleForRoute!(name);
    } else {
      final segs = name.split('/').where((s) => s.isNotEmpty).toList();
      if (segs.length >= 2) module = segs.first;
    }
    _tracker.currentScreen = AIUsageContext(module: module, page: name);
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _set(route);
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _set(previousRoute);
  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      _set(newRoute);
  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _set(previousRoute);
}
