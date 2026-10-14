/// Direct video stream passed from Nuvio's tvOS external-player chooser.
///
/// Nuvio sends: plezy://stream?url=<percent-encoded-http-url>&title=...&sub=...
/// This deliberately does not use Plezy's server-backed MediaItem: the
/// expiring debrid URL is already resolved by the sending application.
final class NuvioStreamLink {
  const NuvioStreamLink({
    required this.url,
    required this.title,
    this.subtitleUrl,
  });

  final String url;
  final String title;
  final String? subtitleUrl;

  static bool _isHttpUrl(String? value) {
    if (value == null || value.isEmpty) return false;
    final uri = Uri.tryParse(value);
    return uri != null &&
        (uri.scheme == 'https' || uri.scheme == 'http') &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty;
  }

  static NuvioStreamLink? tryParse(String text) {
    final uri = Uri.tryParse(text);
    if (uri == null || !{'plezy', 'nuvio-player'}.contains(uri.scheme) || uri.host != 'stream') return null;

    final stream = uri.queryParameters['url'];
    if (!_isHttpUrl(stream)) return null;

    final rawTitle = uri.queryParameters['title']?.trim();
    final title = rawTitle == null || rawTitle.isEmpty
        ? 'Nuvio stream'
        : (rawTitle.length > 180 ? rawTitle.substring(0, 180) : rawTitle);
    final subtitle = uri.queryParameters['sub'];
    return NuvioStreamLink(
      url: stream!,
      title: title,
      subtitleUrl: _isHttpUrl(subtitle) ? subtitle : null,
    );
  }
}
