/// Replaces sensitive substrings in text.
class Redactor {
  const Redactor(this.name, this.pattern, [this.replacement = '[REDACTED]']);

  final String name;
  final String pattern;
  final String replacement;

  String apply(String input) =>
      input.replaceAll(RegExp(pattern, caseSensitive: false), replacement);
}

/// Built-in redactors.
abstract final class Redactors {
  static const email = Redactor(
    'email',
    r'[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}',
    '[EMAIL]',
  );
  static const phone = Redactor(
    'phone',
    r'(?<!\w)\+?\d[\d\s().-]{8,}\d(?!\w)',
    '[PHONE]',
  );
  static const creditCard = Redactor(
    'card',
    r'\b(?:\d[ -]?){13,19}\b',
    '[CARD]',
  );
  static const apiKey = Redactor(
    'api_key',
    r'\b(?:sk|pk|rk|sk-ant|AIza|ghp|gho|xox[abp])[-_A-Za-z0-9]{16,}\b',
    '[SECRET]',
  );
  static const bearer = Redactor(
    'bearer',
    r'Bearer\s+[A-Za-z0-9._\-]+',
    'Bearer [SECRET]',
  );
  static const ipv4 = Redactor('ipv4', r'\b(?:\d{1,3}\.){3}\d{1,3}\b', '[IP]');

  static const defaults = <Redactor>[
    apiKey,
    bearer,
    email,
    creditCard,
    phone,
    ipv4,
  ];

  static String applyAll(String text, List<Redactor> redactors) {
    var out = text;
    for (final r in redactors) {
      out = r.apply(out);
    }
    return out;
  }
}
