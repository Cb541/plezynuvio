import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/nuvio_stream_link.dart';

void main() {
  test('Parses encoded signed Nuvio stream without losing query tokens', () {
    const signed = 'https://cdn.test/movie.mkv?token=alpha%2Bbeta&expires=42';
    final link = NuvioStreamLink.tryParse(
      'plezy://stream?url=' + Uri.encodeComponent(signed) +
      '&title=' + Uri.encodeComponent('Movie & More') +
      '&sub=' + Uri.encodeComponent('https://subs.test/en.srt?a=1&b=2'),
    );
    expect(link?.url, signed);
    expect(link?.title, 'Movie & More');
    expect(link?.subtitleUrl, 'https://subs.test/en.srt?a=1&b=2');
  });

  test('Rejects unsafe non-HTTP schemes and missing media URL', () {
    expect(NuvioStreamLink.tryParse('plezy://stream?url=file%3A%2F%2F%2Fetc%2Fpasswd'), isNull);
    expect(NuvioStreamLink.tryParse('plezy://stream'), isNull);
    expect(NuvioStreamLink.tryParse('plezy://play?content_id=x'), isNull);
    expect(NuvioStreamLink.tryParse('plezy://stream?url=https%3A%2F%2F'), isNull);
  });

  test('Ignores non-HTTP subtitles', () {
    final link = NuvioStreamLink.tryParse(
      'plezy://stream?url=https%3A%2F%2Fexample.test%2Fmovie.mkv&sub=file%3A%2F%2F%2Ftmp%2Fa.srt',
    );
    expect(link, isNotNull);
    expect(link?.subtitleUrl, isNull);
    expect(link?.title, 'Nuvio stream');
  });
}
