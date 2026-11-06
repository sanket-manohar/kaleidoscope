/// Fast offline token estimate. Real tokenizers differ per model; expect
/// roughly ±15% for English text. Use it for pre-call estimates and as a
/// fallback when a provider does not report usage.
abstract final class TokenEstimator {
  /// ~4 characters per token for Latin text, ~1 token per CJK character,
  /// plus a small per-message overhead when [messages] > 0.
  static int estimate(String? text, {int messages = 0}) {
    if (text == null || text.isEmpty) return messages * 4;
    var cjk = 0;
    var other = 0;
    for (final rune in text.runes) {
      if ((rune >= 0x3040 && rune <= 0x30FF) ||
          (rune >= 0x3400 && rune <= 0x9FFF) ||
          (rune >= 0xAC00 && rune <= 0xD7AF)) {
        cjk++;
      } else {
        other++;
      }
    }
    return cjk + (other / 4).ceil() + messages * 4;
  }
}
