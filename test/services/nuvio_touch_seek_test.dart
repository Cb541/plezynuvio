import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/nuvio_touch_seek.dart';

void main() {
  test('touchpad scrubbing clamps to movie bounds', () {
    const total = Duration(hours: 2);
    expect(NuvioTouchSeek.target(
      origin: const Duration(minutes: 90), total: total, deltaX: 800,
    ), total);
    expect(NuvioTouchSeek.target(
      origin: const Duration(minutes: 5), total: total, deltaX: -800,
    ), Duration.zero);
  });

  test('touchpad has symmetric controlled motion', () {
    const total = Duration(hours: 2);
    const at = Duration(hours: 1);
    final right = NuvioTouchSeek.target(origin: at, total: total, deltaX: 100);
    final left = NuvioTouchSeek.target(origin: at, total: total, deltaX: -100);
    expect(right - at, at - left);
    expect(NuvioTouchSeek.target(origin: at, total: total, deltaX: double.nan), at);
  });
}
