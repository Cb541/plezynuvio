import 'dart:math' as math;

/// Stable touchpad-to-playhead mapping, independent of any video decode.
class NuvioTouchSeek {
  /// Moving 400 tvOS remote touch points seeks at most 25% of a movie or
  /// 15 minutes. This keeps tiny gestures precise and supports big jumps.
  static Duration target({
    required Duration origin,
    required Duration total,
    required double deltaX,
  }) {
    final totalMs = total.inMilliseconds;
    if (totalMs <= 0 || !deltaX.isFinite) return origin;
    final fullGestureMs = math.min(totalMs * 0.25, 15 * 60 * 1000.0);
    final nextMs = (origin.inMilliseconds + deltaX / 400.0 * fullGestureMs)
        .round().clamp(0, totalMs);
    return Duration(milliseconds: nextMs);
  }
}
