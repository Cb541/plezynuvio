import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/apple_tv_remote_touch_service.dart';
import '../services/nuvio_stream_link.dart';
import 'nuvio_stream_player_screen.dart';

/// Dedicated Apple TV external player. No Plex account, library, or server
/// setup is required: a resolved HTTP(S) link from Nuvio is sufficient.
class NuvioExternalPlayerApp extends StatefulWidget {
  const NuvioExternalPlayerApp({super.key});

  @override
  State<NuvioExternalPlayerApp> createState() => _NuvioExternalPlayerAppState();
}

class _NuvioExternalPlayerAppState extends State<NuvioExternalPlayerApp> {
  static const _channel = MethodChannel('com.plezy/nuvio_stream');
  final _navigator = GlobalKey<NavigatorState>();
  final _urlController = TextEditingController();
  bool _opening = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    AppleTvRemoteTouchService.instance.start();
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'onExternalStream') return false;
      final args = call.arguments;
      return _openLink(args is Map ? args['deepLink'] : null);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        final initial = await _channel.invokeMethod<String>('getInitialExternalStream');
        if (initial != null) await _openLink(initial);
      } catch (_) {
        // The home screen also supports entering a URL manually.
      }
    });
  }

  Future<bool> _openLink(Object? source) async {
    final link = source is String ? NuvioStreamLink.tryParse(source) : null;
    if (link == null || !mounted || _navigator.currentState == null) return false;
    // Keep only one active full-screen playback route.
    if (_opening) _navigator.currentState!.popUntil((route) => route.isFirst);
    _opening = true;
    unawaited(_navigator.currentState!
        .push<void>(MaterialPageRoute<void>(
          builder: (_) => NuvioStreamPlayerScreen(link: link),
          fullscreenDialog: true,
        ))
        .whenComplete(() => _opening = false));
    return true;
  }

  void _openTypedUrl() {
    final uri = Uri.tryParse(_urlController.text.trim());
    if (uri == null ||
        !{'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      setState(() => _error = 'Enter a direct HTTP or HTTPS video URL');
      return;
    }
    setState(() => _error = null);
    unawaited(_openLink(
      Uri(scheme: 'nuvio-player', host: 'stream', queryParameters: {
        'url': uri.toString(),
        'title': 'Direct stream',
      }).toString(),
    ));
  }

  @override
  void dispose() {
    _channel.setMethodCallHandler(null);
    AppleTvRemoteTouchService.instance.stop();
    _urlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navigator,
      debugShowCheckedModeBanner: false,
      title: 'Nuvio Player',
      theme: ThemeData.dark(useMaterial3: true),
      home: Scaffold(
        backgroundColor: const Color(0xFF090B11),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: Padding(
              padding: const EdgeInsets.all(44),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Nuvio Player',
                      style: TextStyle(fontSize: 44, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 14),
                  const Text('Ready for a stream from Nuvio',
                      style: TextStyle(color: Colors.white70, fontSize: 22)),
                  const SizedBox(height: 16),
                  const Text(
                    'Dolby Vision P7 → P8.1  •  On-demand thumbnails  •  '
                    'Siri Remote touch seeking  •  Zoom and vertical stretch',
                    style: TextStyle(color: Colors.white54, fontSize: 16),
                  ),
                  const SizedBox(height: 32),
                  TextField(
                    controller: _urlController,
                    decoration: const InputDecoration(
                      labelText: 'Or paste a direct video URL',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.url,
                    onSubmitted: (_) => _openTypedUrl(),
                  ),
                  const SizedBox(height: 14),
                  FilledButton.icon(
                    onPressed: _openTypedUrl,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Play stream'),
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 14),
                      child: Text(_error!, style: const TextStyle(color: Colors.orangeAccent)),
                    )
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
