import 'dart:collection';

import 'package:flutter/services.dart';

/// Small on-demand thumbnails for a Nuvio direct stream.
///
/// Invokes a separate, offscreen libmpv decoder on tvOS. Only successful JPEGs
/// are cached. Requests are driven by the seek UI after a short debounce and
/// are serialized by the native plugin to protect video playback performance.
class NuvioSeekThumbnails {
  NuvioSeekThumbnails(String url, {MethodChannel? channel})
    : _url = url,
      _channel = channel ?? const MethodChannel('com.plezy/nuvio_thumbnails');

  static const maxCachedFrames = 48;
  final String _url;
  final MethodChannel _channel;
  final LinkedHashMap<int, Uint8List> _frames = LinkedHashMap<int, Uint8List>();
  bool _disposed = false;

  /// Use the same 10-second grid as remote seek steps; nearby repeat presses
  /// reuse an existing JPEG instead of repeatedly decoding the same GOP.
  static int keyFor(Duration at) => (at.inMilliseconds ~/ 10000) * 10000;

  Uint8List? cached(Duration at) {
    final key = keyFor(at);
    final bytes = _frames.remove(key);
    if (bytes != null) _frames[key] = bytes; // bounded LRU
    return bytes;
  }

  Future<Uint8List?> getFrame(Duration at) async {
    if (_disposed) return null;
    final old = cached(at);
    if (old != null) return old;
    final key = keyFor(at);
    try {
      final bytes = await _channel.invokeMethod<Uint8List>('frame', {
        'url': _url,
        'timeMs': key,
      });
      if (_disposed || bytes == null || bytes.isEmpty) return null;
      // Defensive upper bound for data returned from the native channel.
      if (bytes.length > 512 * 1024) return null;
      _frames.remove(key);
      _frames[key] = bytes;
      while (_frames.length > maxCachedFrames) {
        _frames.remove(_frames.keys.first);
      }
      return bytes;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      // Non-tvOS platforms do not install the thumbnail plugin.
      return null;
    }
  }

  void dispose() {
    _disposed = true;
    _frames.clear();
  }
}
