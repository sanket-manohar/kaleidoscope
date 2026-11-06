/// Where in the app an AI call happened, plus any custom tags.
///
/// Contexts merge: values from a more specific context (e.g. one passed
/// directly to `track`) override values from an outer one (a zone scope or
/// the current route).
class AIUsageContext {
  const AIUsageContext({
    this.module,
    this.page,
    this.section,
    this.feature,
    this.userId,
    this.sessionId,
    this.conversationId,
    this.tags = const [],
    this.custom = const {},
  });

  /// Top-level area of the app, e.g. `checkout`, `support`, `onboarding`.
  final String? module;

  /// Screen / route inside the module, e.g. `cart`, `chat`.
  final String? page;

  /// Section within the page, e.g. `suggestions`, `composer`, `summary_card`.
  final String? section;

  /// Optional finer-grained feature name, e.g. `auto_reply`.
  final String? feature;

  /// Your app's (pseudonymous) user id, if you want per-user analytics.
  final String? userId;

  /// App session id.
  final String? sessionId;

  /// Conversation / thread id, to group multi-turn chats.
  final String? conversationId;

  /// Free-form labels.
  final List<String> tags;

  /// Any custom key/values you want stored with the record.
  final Map<String, Object?> custom;

  static const empty = AIUsageContext();

  bool get isEmpty =>
      module == null &&
      page == null &&
      section == null &&
      feature == null &&
      userId == null &&
      sessionId == null &&
      conversationId == null &&
      tags.isEmpty &&
      custom.isEmpty;

  /// Returns a context where non-null values of [other] win.
  AIUsageContext merge(AIUsageContext? other) {
    if (other == null || other.isEmpty) return this;
    if (isEmpty) return other;
    return AIUsageContext(
      module: other.module ?? module,
      page: other.page ?? page,
      section: other.section ?? section,
      feature: other.feature ?? feature,
      userId: other.userId ?? userId,
      sessionId: other.sessionId ?? sessionId,
      conversationId: other.conversationId ?? conversationId,
      tags: {...tags, ...other.tags}.toList(),
      custom: {...custom, ...other.custom},
    );
  }

  AIUsageContext copyWith({
    String? module,
    String? page,
    String? section,
    String? feature,
    String? userId,
    String? sessionId,
    String? conversationId,
    List<String>? tags,
    Map<String, Object?>? custom,
  }) => AIUsageContext(
    module: module ?? this.module,
    page: page ?? this.page,
    section: section ?? this.section,
    feature: feature ?? this.feature,
    userId: userId ?? this.userId,
    sessionId: sessionId ?? this.sessionId,
    conversationId: conversationId ?? this.conversationId,
    tags: tags ?? this.tags,
    custom: custom ?? this.custom,
  );

  Map<String, Object?> toJson() => {
    if (module != null) 'module': module,
    if (page != null) 'page': page,
    if (section != null) 'section': section,
    if (feature != null) 'feature': feature,
    if (userId != null) 'userId': userId,
    if (sessionId != null) 'sessionId': sessionId,
    if (conversationId != null) 'conversationId': conversationId,
    if (tags.isNotEmpty) 'tags': tags,
    if (custom.isNotEmpty) 'custom': custom,
  };

  factory AIUsageContext.fromJson(Map<String, Object?> json) => AIUsageContext(
    module: json['module'] as String?,
    page: json['page'] as String?,
    section: json['section'] as String?,
    feature: json['feature'] as String?,
    userId: json['userId'] as String?,
    sessionId: json['sessionId'] as String?,
    conversationId: json['conversationId'] as String?,
    tags: (json['tags'] as List?)?.map((e) => '$e').toList() ?? const [],
    custom: (json['custom'] as Map?)?.cast<String, Object?>() ?? const {},
  );

  @override
  String toString() => [
    module,
    page,
    section,
    feature,
  ].where((e) => e != null && e.isNotEmpty).join(' › ');
}
