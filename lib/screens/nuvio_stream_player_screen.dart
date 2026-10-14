import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../mpv/mpv.dart';
import '../services/nuvio_stream_link.dart';
import '../services/nuvio_seek_thumbnails.dart';
import '../services/playback_coordinator.dart';

/// Standalone native-mpv playback for a URL Nuvio has already resolved.
///
/// Keeps the Plex/Jellyfin player and its server bookkeeping untouched.
/// Remote seeks show independently decoded on-demand thumbnails. The video
/// player is only sought once the user releases the remote direction key.
class NuvioStreamPlayerScreen extends StatefulWidget {
  const NuvioStreamPlayerScreen({super.key, required this.link});
  final NuvioStreamLink link;

  @override
  State<NuvioStreamPlayerScreen> createState() => _NuvioStreamPlayerScreenState();
}

class _NuvioStreamPlayerScreenState extends State<NuvioStreamPlayerScreen> {
  late final Player _player;
  late final NuvioSeekThumbnails _thumbnails;
  Timer? _thumbnailDebounce;
  Duration? _queuedThumbnail;
  Uint8List? _thumbnail;
  bool _thumbnailInFlight = false;
  bool _previewUnavailable = false;
  final FocusNode _remoteFocus = FocusNode(debugLabel: 'Nuvio external video');
  final List<StreamSubscription<dynamic>> _subscriptions = [];

  Timer? _seekDebounce;
  Duration? _seekPreview;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _loading = true;
  bool _playing = false;
  bool _buffering = false;
  bool _closing = false;
  String? _failure;

  @override
  void initState() {
    super.initState();
    _player = Player();
    _thumbnails = NuvioSeekThumbnails(widget.link.url);
    _subscriptions.add(_player.streams.position.listen((value) {
      if (mounted && _seekPreview == null) setState(() => _position = value);
    }));
    _subscriptions.add(_player.streams.duration.listen((value) {
      if (mounted) setState(() => _duration = value);
    }));
    _subscriptions.add(_player.streams.playing.listen((value) {
      if (mounted) setState(() => _playing = value);
    }));
    _subscriptions.add(_player.streams.buffering.listen((value) {
      if (mounted) setState(() => _buffering = value);
    }));
    _subscriptions.add(_player.streams.playbackRestart.listen((_) {
      if (mounted) setState(() => _loading = false);
    }));
    _subscriptions.add(_player.streams.fileLoadFailed.listen((_) {
      if (mounted) setState(() {
        _loading = false;
        _failure = 'Plezy could not load this stream. The link may have expired or the format may be unsupported.';
      });
    }));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _remoteFocus.requestFocus();
      unawaited(_startPlayback());
    });
  }

  Future<void> _startPlayback() async {
    try {
      await PlaybackCoordinator.instance.claimVideo();
      if (!mounted || _closing) return;
      final sidecar = widget.link.subtitleUrl;
      await _player.open(
        Media(widget.link.url),
        externalSubtitles: sidecar == null
            ? null
            : [SubtitleTrack.uri(sidecar, title: 'Nuvio subtitles')],
      );
      if (mounted) setState(() => _playing = true);
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _failure = 'The external stream could not be opened in Plezy.';
        });
      }
    }
  }

  void _previewSeek(int direction) {
    final maxMs = _duration.inMilliseconds;
    final origin = _seekPreview ?? _player.currentPosition;
    final next = (origin.inMilliseconds + direction * 10000).clamp(0, maxMs > 0 ? maxMs : 86400000).toInt();
    final target = Duration(milliseconds: next);
    setState(() => _seekPreview = target);
    _scheduleThumbnail(target);
    _seekDebounce?.cancel();
    _seekDebounce = Timer(const Duration(milliseconds: 400), _commitSeek);
  }

  void _scheduleThumbnail(Duration target) {
    _thumbnailDebounce?.cancel();
    final existing = _thumbnails.cached(target);
    setState(() {
      _thumbnail = existing;
      _previewUnavailable = false;
    });
    if (existing != null) return;
    // Avoid launching a decoder for every repeat key in a rapid scrub.
    _thumbnailDebounce = Timer(const Duration(milliseconds: 170), () {
      _queuedThumbnail = _seekPreview;
      unawaited(_drainThumbnailRequests());
    });
  }

  Future<void> _drainThumbnailRequests() async {
    if (_thumbnailInFlight) return;
    _thumbnailInFlight = true;
    try {
      while (!_closing && mounted && _queuedThumbnail != null) {
        final requested = _queuedThumbnail!;
        _queuedThumbnail = null;
        final bytes = await _thumbnails.getFrame(requested);
        if (!mounted || _closing) return;
        final current = _seekPreview;
        if (current != null &&
            NuvioSeekThumbnails.keyFor(current) == NuvioSeekThumbnails.keyFor(requested)) {
          setState(() {
            _thumbnail = bytes;
            _previewUnavailable = bytes == null;
          });
        }
      }
    } finally {
      _thumbnailInFlight = false;
    }
  }

  void _commitSeek() {
    _seekDebounce?.cancel();
    _seekDebounce = null;
    _thumbnailDebounce?.cancel();
    _queuedThumbnail = null;
    final target = _seekPreview;
    if (target == null) return;
    setState(() {
      _seekPreview = null;
      _thumbnail = null;
      _previewUnavailable = false;
      _position = target;
    });
    unawaited(_player.seek(target));
  }

  KeyEventResult _onRemoteKey(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    final down = event is KeyDownEvent || event is KeyRepeatEvent;
    if (key == LogicalKeyboardKey.arrowRight || key == LogicalKeyboardKey.arrowLeft) {
      if (down) {
        _previewSeek(key == LogicalKeyboardKey.arrowRight ? 1 : -1);
      } else if (event is KeyUpEvent) {
        _commitSeek();
      }
      return KeyEventResult.handled;
    }
    if (!down) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.mediaPlayPause) {
      unawaited(_player.playOrPause());
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.browserBack) {
      _close();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _close() {
    if (_closing) return;
    _closing = true;
    Navigator.of(context).pop();
  }

  String _formatTime(Duration value) {
    final h = value.inHours;
    final m = value.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = value.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h == 0 ? value.inMinutes.toString() + ':' + s : h.toString() + ':' + m + ':' + s;
  }

  @override
  void dispose() {
    _closing = true;
    _seekDebounce?.cancel();
    _thumbnailDebounce?.cancel();
    _queuedThumbnail = null;
    _thumbnails.dispose();
    for (final sub in _subscriptions) {
      unawaited(sub.cancel());
    }
    _remoteFocus.dispose();
    unawaited(_player.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final target = _seekPreview ?? _position;
    final durationMs = _duration.inMilliseconds;
    final progress = durationMs <= 0
        ? 0.0
        : (target.inMilliseconds / durationMs).clamp(0.0, 1.0).toDouble();
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          Video(player: _player),
          Focus(
            focusNode: _remoteFocus,
            onKeyEvent: _onRemoteKey,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => unawaited(_player.playOrPause()),
              child: const SizedBox.expand(),
            ),
          ),
          if (_loading || _buffering)
            const Center(child: CircularProgressIndicator()),
          if (_failure != null)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_failure!, style: const TextStyle(color: Colors.white, fontSize: 21)),
                    const SizedBox(height: 24),
                    FilledButton(onPressed: _close, child: const Text('Return to Plezy')),
                  ],
                ),
              ),
            ),
          if (_failure == null)
            Align(
              alignment: Alignment.bottomCenter,
              child: Container(
                padding: const EdgeInsets.fromLTRB(36, 22, 36, 34),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Color(0xDD000000)],
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_seekPreview != null) ...[
                      Center(
                        child: Container(
                          width: 292,
                          height: 182,
                          decoration: BoxDecoration(
                            color: const Color(0xEE101014),
                            border: Border.all(color: Colors.white38, width: 1.5),
                            borderRadius: BorderRadius.circular(12),
                            boxShadow: const [
                              BoxShadow(color: Colors.black87, blurRadius: 22, offset: Offset(0, 8)),
                            ],
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: Column(
                              children: [
                                Expanded(
                                  child: _thumbnail != null
                                      ? Image.memory(_thumbnail!, fit: BoxFit.contain, gaplessPlayback: true)
                                      : Center(
                                          child: _previewUnavailable
                                              ? const Text('Preview unavailable',
                                                  style: TextStyle(color: Colors.white70, fontSize: 14))
                                              : const SizedBox(
                                                  width: 25, height: 25,
                                                  child: CircularProgressIndicator(strokeWidth: 2.5),
                                                ),
                                        ),
                                ),
                                Container(
                                  width: double.infinity,
                                  color: const Color(0xCC111111),
                                  padding: const EdgeInsets.symmetric(vertical: 7),
                                  child: Text(
                                    _formatTime(target),
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(
                                      color: Colors.white, fontWeight: FontWeight.w600, fontSize: 15,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                    ],
                    Text(widget.link.title,
                        maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    LinearProgressIndicator(value: progress, minHeight: 5),
                    const SizedBox(height: 7),
                    Row(
                      children: [
                        Text(_formatTime(target)),
                        const Spacer(),
                        if (_seekPreview != null)
                          const Text('Release to seek'),
                        const Spacer(),
                        Text(_duration > Duration.zero ? _formatTime(_duration) : '--:--'),
                      ],
                    ),
                    const SizedBox(height: 5),
                    Text(_seekPreview != null
                            ? 'Previewing • release to seek'
                            : (_playing ? 'Select: pause • Left/Right: seek • Menu: back' : 'Select: play • Menu: back'),
                        style: const TextStyle(color: Colors.white70, fontSize: 13)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
