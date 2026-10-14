import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../mpv/mpv.dart';
import '../services/nuvio_stream_link.dart';
import '../services/nuvio_seek_thumbnails.dart';
import '../services/nuvio_touch_seek.dart';
import '../services/apple_tv_remote_touch_service.dart';
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
  bool _settingsOpen = false;
  int _selectedSetting = 0;
  int _dvMode = 0;
  double _zoom = 1.0;
  double _verticalStretch = 1.0;
  double? _touchStartX;
  double? _touchStartY;
  Duration _touchOrigin = Duration.zero;
  bool _touchScrubbing = false;
  static const _dvModes = ['dv81', 'auto', 'hevc_strip'];
  static const _dvLabels = ['Dolby Vision P8.1', 'Automatic', 'HDR10 fallback'];
  String? _failure;

  @override
  void initState() {
    super.initState();
    _player = Player();
    _thumbnails = NuvioSeekThumbnails(widget.link.url);
    final touch = AppleTvRemoteTouchService.instance;
    touch.captureNuvioTouch = true;
    _subscriptions.add(touch.nuvioTouches.listen(_onTouchSample));
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
      // Apply conversion before the first decode, not after file-loaded.
      await _player.setProperty('dv-conversion-mode', _dvModes[_dvMode]);
      final sidecar = widget.link.subtitleUrl;
      await _player.open(
        Media(widget.link.url),
        externalSubtitles: sidecar == null
            ? null
            : [SubtitleTrack.uri(sidecar, title: 'Nuvio subtitles')],
      );
      if (mounted) setState(() => _playing = true);
      await _applyGeometry();
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
    final next = (origin.inMilliseconds + direction * 10000)
        .clamp(0, maxMs > 0 ? maxMs : 86400000).toInt();
    _previewAt(Duration(milliseconds: next), autoCommit: true);
  }

  void _previewAt(Duration target, {required bool autoCommit}) {
    if (!mounted || _closing) return;
    setState(() => _seekPreview = target);
    _scheduleThumbnail(target);
    _seekDebounce?.cancel();
    _seekDebounce = autoCommit
        ? Timer(const Duration(milliseconds: 650), _commitSeek)
        : null;
  }

  void _onTouchSample(NuvioTouchSample sample) {
    if (_settingsOpen || _closing || !mounted || _duration <= Duration.zero) return;
    switch (sample.type) {
      case 'started':
        _touchStartX = sample.x;
        _touchStartY = sample.y;
        _touchOrigin = _seekPreview ?? _position;
        _touchScrubbing = false;
      case 'move':
        final x = sample.x;
        final y = sample.y;
        final startX = _touchStartX;
        final startY = _touchStartY;
        if (x == null || y == null || startX == null || startY == null) return;
        final deltaX = x - startX;
        final deltaY = y - startY;
        if (!_touchScrubbing &&
            (deltaX.abs() < 12 || deltaX.abs() < deltaY.abs() * 1.15)) {
          return;
        }
        _touchScrubbing = true;
        _previewAt(NuvioTouchSeek.target(
          origin: _touchOrigin,
          total: _duration,
          deltaX: deltaX,
        ), autoCommit: false);
      case 'ended':
        _touchStartX = null;
        _touchStartY = null;
        if (_touchScrubbing) _commitSeek();
        _touchScrubbing = false;
      case 'cancelled':
        _touchStartX = null;
        _touchStartY = null;
        _touchScrubbing = false;
        _seekDebounce?.cancel();
        setState(() => _seekPreview = null);
    }
  }

  Future<void> _applyGeometry() async {
    try {
      await const MethodChannel('com.plezy/mpv_player').invokeMethod<void>('setVideoZoom', {
        'scale': _zoom,
        'verticalScale': _verticalStretch,
      });
    } catch (_) {
      // Preserve playback if native geometry control is unavailable.
    }
  }

  void _adjustSetting(int direction) {
    switch (_selectedSetting) {
      case 0:
        _dvMode = (_dvMode + direction + _dvModes.length) % _dvModes.length;
        setState(() {});
        unawaited(_reloadForDv());
      case 1:
        setState(() => _zoom = (_zoom + direction * 0.10).clamp(1.0, 2.0));
        unawaited(_applyGeometry());
      case 2:
        setState(() => _verticalStretch =
            (_verticalStretch + direction * 0.05).clamp(0.70, 1.60));
        unawaited(_applyGeometry());
    }
  }

  Future<void> _reloadForDv() async {
    try {
      final resume = _seekPreview ?? _position;
      await _player.setProperty('dv-conversion-mode', _dvModes[_dvMode]);
      if (_closing || !mounted) return;
      await _player.open(
        Media(widget.link.url, start: resume),
        play: _playing,
        externalSubtitles: widget.link.subtitleUrl == null
            ? null
            : [SubtitleTrack.uri(widget.link.subtitleUrl!, title: 'Nuvio subtitles')],
      );
      await _applyGeometry();
    } catch (_) {
      if (mounted) setState(() {
        _failure = 'Could not restart the stream with the new Dolby Vision mode.';
      });
    }
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
    if (down && (key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown)) {
      if (!_settingsOpen) {
        setState(() {
          _settingsOpen = true;
          _selectedSetting = 0;
        });
      } else {
        setState(() {
          _selectedSetting = (_selectedSetting +
              (key == LogicalKeyboardKey.arrowDown ? 1 : -1) + 3) % 3;
        });
      }
      return KeyEventResult.handled;
    }
    if (_settingsOpen) {
      if (down && (key == LogicalKeyboardKey.arrowRight ||
          key == LogicalKeyboardKey.arrowLeft)) {
        _adjustSetting(key == LogicalKeyboardKey.arrowRight ? 1 : -1);
      } else if (down && (key == LogicalKeyboardKey.select ||
          key == LogicalKeyboardKey.enter ||
          key == LogicalKeyboardKey.escape ||
          key == LogicalKeyboardKey.browserBack)) {
        setState(() => _settingsOpen = false);
      }
      return KeyEventResult.handled;
    }
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
    return h == 0 ? '${value.inMinutes}:$s' : '$h:$m:$s';
  }

  @override
  void dispose() {
    _closing = true;
    _seekDebounce?.cancel();
    _thumbnailDebounce?.cancel();
    _queuedThumbnail = null;
    _thumbnails.dispose();
    AppleTvRemoteTouchService.instance.captureNuvioTouch = false;
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
          if (_settingsOpen && _failure == null)
            Align(
              alignment: Alignment.topRight,
              child: Container(
                width: 415,
                margin: const EdgeInsets.all(32),
                padding: const EdgeInsets.all(22),
                decoration: BoxDecoration(
                  color: const Color(0xF2151823),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: Colors.white24),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('VIDEO SETTINGS',
                        style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 10),
                    for (final item in [
                      'Dolby Vision conversion   ${_dvLabels[_dvMode]}',
                      'Zoom   ${_zoom.toStringAsFixed(2)}×',
                      'Vertical stretch   ${(_verticalStretch * 100).round()}%',
                    ].asMap().entries)
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
                        margin: const EdgeInsets.symmetric(vertical: 3),
                        decoration: BoxDecoration(
                          color: _selectedSetting == item.key
                              ? const Color(0xFF284F8D) : Colors.transparent,
                          borderRadius: BorderRadius.circular(7),
                        ),
                        child: Text(item.value, style: const TextStyle(fontSize: 17)),
                      ),
                    const SizedBox(height: 8),
                    const Text('Up/Down: select • Left/Right: change • Select: close',
                        style: TextStyle(color: Colors.white60, fontSize: 12)),
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
                            : (_playing
                                ? 'Touchpad: scrub • Up: video settings • Select: pause • Menu: back'
                                : 'Select: play • Touchpad: scrub • Up: video settings'),
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
