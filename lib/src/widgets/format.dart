/// Small formatting helpers used by the widgets.
abstract final class AIFormat {
  static String money(double v, [String currency = 'USD']) {
    final sym = switch (currency) {
      'USD' => r'$',
      'EUR' => '€',
      'GBP' => '£',
      'INR' => '₹',
      'JPY' => '¥',
      _ => '$currency ',
    };
    if (v == 0) return '${sym}0';
    if (v < 0.01) return '$sym${v.toStringAsFixed(5)}';
    if (v < 1) return '$sym${v.toStringAsFixed(3)}';
    return '$sym${v.toStringAsFixed(2)}';
  }

  static String tokens(num v) {
    if (v >= 1e9) return '${(v / 1e9).toStringAsFixed(2)}B';
    if (v >= 1e6) return '${(v / 1e6).toStringAsFixed(2)}M';
    if (v >= 1e3) return '${(v / 1e3).toStringAsFixed(1)}k';
    return v.toStringAsFixed(0);
  }

  static String ms(num v) =>
      v >= 1000 ? '${(v / 1000).toStringAsFixed(2)}s' : '${v.round()}ms';

  static String pct(double v) =>
      '${(v * 100).toStringAsFixed(v < 0.1 ? 1 : 0)}%';

  static String time(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }
}
