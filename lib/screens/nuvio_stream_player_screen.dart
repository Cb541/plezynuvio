import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../mpv/mpv.dart';
import '../services/nuvio_stream_link.dart';
import '../services/playback_coordinator.dart';

/// Standalone native-mpv playback for a URL Nuvio has already resolved.
///
/// Keeps the Plex/Jellyfin player and its server bookkeeping untouched.
/// In this first build the seek strip shows a time target, not extracted
/// thumbnail images; remote key repeats are accumulated so holding right
/// does not open dozens of expensive network seeks.
class NuvioStreamPlayerScreen extends StatefulWidget {
  const NuvioStreamPlayerScreen({super.key, required this.link});
  final NuvioStreamLink link;

  @override
  State<NuvioStreamPlayerScreen> createState() => _NuvioStreamPlayerScreenState();
}

class _NuvioStreamPlayerScreenState extends State<NuvioStreamPlayerScreen> {
  late final Player _player;
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
    final next = (origin.inMilliseconds + direction * 10000).clamp(0, maxMs > 0 ? maxMs : 86400000);
    setState(() => _seekPreview = Duration(milliseconds: next));
    _seekDebounce?.cancel();
    _seekDebounce = Timer(const Duration(milliseconds: 400), _commitSeek);
  }

  void _commitSeek() {
    _seekDebounce?.cancel();
    _seekDebounce = null;
    final target = _seekPreview;
    if (target == null) return;
    setState(() {
      _seekPreview = null;
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
        : (target.inMilliseconds / durationMs).clamp(0.0, 1.0);
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
                            ? 'Seeking • thumbnails not yet generated'
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
