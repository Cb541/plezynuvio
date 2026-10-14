import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/nuvio_seek_thumbnails.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test.nuvio.thumbnails');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('seeks are snapped to a ten-second thumbnail grid', () {
    expect(NuvioSeekThumbnails.keyFor(const Duration(seconds: 29)), 20000);
    expect(NuvioSeekThumbnails.keyFor(const Duration(seconds: 30)), 30000);
    expect(NuvioSeekThumbnails.keyFor(Duration.zero), 0);
  });

  test('caches successful frames without repeating network extraction', () async {
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'frame');
      expect(call.arguments['url'], 'https://example.com/video.mkv');
      expect(call.arguments['timeMs'], 10000);
      calls++;
      return Uint8List.fromList([0xff, 0xd8, 0xff, 0xd9]);
    });
    final thumbnails = NuvioSeekThumbnails('https://example.com/video.mkv', channel: channel);
    expect(await thumbnails.getFrame(const Duration(seconds: 17)), isNotNull);
    expect(thumbnails.cached(const Duration(seconds: 12)), isNotNull);
    expect(await thumbnails.getFrame(const Duration(seconds: 11)), isNotNull);
    expect(calls, 1);
    thumbnails.dispose();
  });

  test('bounds the thumbnail LRU to 48 decoded frames', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      return Uint8List.fromList([0xff, 0xd8, 0xff, 0xd9]);
    });
    final thumbnails = NuvioSeekThumbnails('https://example.com/video.mkv', channel: channel);
    for (var i = 0; i <= 48; i++) {
      await thumbnails.getFrame(Duration(seconds: i * 10));
    }
    expect(thumbnails.cached(Duration.zero), isNull);
    expect(thumbnails.cached(const Duration(seconds: 480)), isNotNull);
    thumbnails.dispose();
  });

  test('missing native backend and disposal fail closed', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw MissingPluginException('no tvOS plugin');
    });
    final thumbnails = NuvioSeekThumbnails('https://example.com/video.mkv', channel: channel);
    expect(await thumbnails.getFrame(Duration.zero), isNull);
    thumbnails.dispose();
    expect(await thumbnails.getFrame(Duration.zero), isNull);
  });
}
