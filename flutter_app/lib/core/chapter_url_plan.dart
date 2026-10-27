/// Turns a pair of public chapter links into a safe, bounded reading plan.
///
/// Supports one changing chapter integer in the final path segment or an
/// explicit chapter/page query parameter, such as
/// .../Chapter_001 -> .../Chapter_012 or .../read/v1/c1?bid=7 -> c12?bid=7.
/// Different slugs, opaque IDs, multiple changing tokens and unsupported
/// progressions fall back to following Next links in the reader tab.
class ChapterUrlPlan {
  ChapterUrlPlan._({
    required this.start,
    required this.end,
    required this.urls,
    required this.inferred,
    required this.description,
  });

  final Uri start;
  final Uri end;
  final List<Uri> urls;
  final bool inferred;
  final String description;
  static const int maxChapters = 120;

  static ChapterUrlPlan parse(String first, String last) {
    final a = Uri.tryParse(first.trim());
    final b = Uri.tryParse(last.trim());
    if (a == null || b == null || !_valid(a) || !_valid(b)) {
      throw const FormatException('Enter two complete HTTPS chapter URLs.');
    }
    if (a.origin != b.origin) {
      throw const FormatException('Start and end must be on the same website.');
    }
    if (a.fragment != b.fragment &&
        [a.fragment, b.fragment].any((fragment) =>
            fragment.startsWith('/') || fragment.startsWith('!/'))) {
      throw const FormatException('These chapters use browser fragment routes. '
          'Copy normal chapter links or import the chapter files instead.');
    }
    final start = a.removeFragment();
    final end = b.removeFragment();
    if (start == end) {
      return ChapterUrlPlan._(
          start: start,
          end: end,
          urls: [start],
          inferred: true,
          description: 'One chapter');
    }

    // Treat percent escapes as literal text, never as chapter numbers. For
    // example %20 followed by chapter 9 must not become the integer 209, and
    // changing a Cyrillic letter must never generate invented chapter URLs.
    final aa = start.toString();
    final bb = end.toString();
    final tokens = RegExp(r'%[0-9A-Fa-f]{2}|\d+');
    final ma = tokens
        .allMatches(aa)
        .where((match) => !match.group(0)!.startsWith('%'))
        .toList();
    final mb = tokens
        .allMatches(bb)
        .where((match) => !match.group(0)!.startsWith('%'))
        .toList();
    if (ma.length == mb.length) {
      final skeletonA = _skeleton(aa, ma);
      final skeletonB = _skeleton(bb, mb);
      if (_equal(skeletonA, skeletonB)) {
        var difference = -1;
        for (var i = 0; i < ma.length; i++) {
          if (ma[i].group(0) != mb[i].group(0)) {
            if (difference != -1) {
              difference = -2;
              break;
            }
            difference = i;
          }
        }
        if (difference >= 0 && _isChapterToken(aa, ma[difference])) {
          final fromText = ma[difference].group(0)!;
          final toText = mb[difference].group(0)!;
          final from = int.tryParse(fromText);
          final to = int.tryParse(toText);
          if (from != null && to != null && from >= 0 && to >= from) {
            final length = to - from + 1;
            if (length > maxChapters) {
              throw FormatException('Limit: $maxChapters chapters per session. '
                  'Choose a smaller range.');
            }
            final width = ((fromText.length > 1 && fromText.startsWith('0')) ||
                    (toText.length > 1 && toText.startsWith('0')))
                ? (fromText.length > toText.length
                    ? fromText.length
                    : toText.length)
                : 0;
            final prefix = aa.substring(0, ma[difference].start);
            final suffix = aa.substring(ma[difference].end);
            final urls = <Uri>[];
            for (var n = from; n <= to; n++) {
              final value = width > 0 ? n.toString().padLeft(width, '0') : '$n';
              urls.add(Uri.parse('$prefix$value$suffix'));
            }
            if (urls.first == start && urls.last == end) {
              return ChapterUrlPlan._(
                start: start,
                end: end,
                urls: urls,
                inferred: true,
                description: '$length sequential URLs, chapter $from–$to',
              );
            }
          }
        }
      }
    }

    return ChapterUrlPlan._(
      start: start,
      end: end,
      urls: const [],
      inferred: false,
      description: 'No safe numeric pattern. Follow the website’s Next links '
          'until the exact ending URL.',
    );
  }

  static bool _valid(Uri uri) {
    if (uri.scheme != 'https' || uri.host.isEmpty || uri.userInfo.isNotEmpty) {
      return false;
    }
    if (uri.hasPort && uri.port != 443) return false;
    if (uri.toString().length > 2048) return false;
    return true;
  }

  static List<String> _skeleton(String value, List<RegExpMatch> matches) {
    final pieces = <String>[];
    var previous = 0;
    for (final match in matches) {
      pieces.add(value.substring(previous, match.start));
      previous = match.end;
    }
    pieces.add(value.substring(previous));
    return pieces;
  }

  static bool _isChapterToken(String url, RegExpMatch token) {
    final query = url.indexOf('?');
    if (query >= 0 && token.start > query) {
      final pairStart = url.lastIndexOf('&', token.start) + 1;
      final start = pairStart > query ? pairStart : query + 1;
      final nextPair = url.indexOf('&', start);
      final pair = url.substring(start, nextPair < 0 ? url.length : nextPair);
      final equals = pair.indexOf('=');
      if (equals < 0 || token.start <= start + equals) return false;
      final key =
          Uri.decodeQueryComponent(pair.substring(0, equals)).toLowerCase();
      final value = Uri.decodeQueryComponent(pair.substring(equals + 1));
      return const {
            'chapter',
            'chapter_number',
            'chapter_num',
            'chapter_no',
            'chap',
            'ch',
            'c',
            'page',
            'p',
            'part'
          }.contains(key) &&
          RegExp(r'^\d+$').hasMatch(value);
    }
    final pathEnd = query < 0 ? url.length : query;
    final segmentStart = url.lastIndexOf('/', pathEnd - 1) + 1;
    if (token.start < segmentStart || token.end > pathEnd) return false;
    final segment =
        Uri.decodeComponent(url.substring(segmentStart, pathEnd)).toLowerCase();
    // Book/translation IDs and years embedded in arbitrary slugs are not
    // chapter sequences. Unknown patterns use the site's explicit Next link.
    return RegExp(r'^(?:(?:chapter|chap|ch|c|page|p|part|section|read|'
            r'глава|страница|часть)[\s_.-]*)?\d+(?:\.html?)?$')
        .hasMatch(segment);
  }

  static bool _equal(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  bool get isWikimedia =>
      RegExp(
        r'^[a-z-]+\.(wikisource|wikibooks)\.org$',
      ).hasMatch(start.host) &&
      start.pathSegments.isNotEmpty &&
      start.pathSegments.first == 'wiki';

  /// Links are compared with fragments removed; navigation must stay on the
  /// exact original website.
  bool contains(Uri url) =>
      url.origin == start.origin &&
      (inferred ? urls.contains(url.removeFragment()) : true);
}
