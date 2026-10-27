/// Turns a pair of public chapter links into a safe, bounded reading plan.
///
/// Supports one changing integer token in path or query, such as
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
    final start = a.replace(fragment: '');
    final end = b.replace(fragment: '');
    if (start == end) {
      return ChapterUrlPlan._(start: start, end: end, urls: [start],
        inferred: true, description: 'One chapter');
    }

    // Split URL into all digit groups and intervening text. Non-changing
    // numbers (book IDs, volumes, translation IDs) are preserved exactly.
    final aa = start.toString();
    final bb = end.toString();
    final digits = RegExp(r'\d+');
    final ma = digits.allMatches(aa).toList();
    final mb = digits.allMatches(bb).toList();
    if (ma.length == mb.length) {
      final skeletonA = aa.split(digits);
      final skeletonB = bb.split(digits);
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
        if (difference >= 0) {
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
            final width = (fromText.startsWith('0') || toText.startsWith('0'))
                ? (fromText.length > toText.length ? fromText.length : toText.length)
                : 0;
            final prefix = aa.substring(0, ma[difference].start);
            final suffix = aa.substring(ma[difference].end);
            final urls = <Uri>[];
            for (var n = from; n <= to; n++) {
              final value = width > 0 ? n.toString().padLeft(width, '0') : '$n';
              urls.add(Uri.parse('$prefix$value$suffix'));
            }
            if (urls.last == end) {
              return ChapterUrlPlan._(
                start: start, end: end, urls: urls, inferred: true,
                description: '$length sequential URLs, chapter $from–$to',
              );
            }
          }
        }
      }
    }

    return ChapterUrlPlan._(
      start: start, end: end, urls: const [],
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

  static bool _equal(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  bool get isWikimedia => RegExp(
        r'^[a-z-]+\.(wikisource|wikibooks)\.org$',
      ).hasMatch(start.host) &&
      start.pathSegments.isNotEmpty &&
      start.pathSegments.first == 'wiki';

  /// Links are compared with fragments removed; navigation must stay on the
  /// exact original website.
  bool contains(Uri url) =>
      url.origin == start.origin &&
      (inferred ? urls.contains(url.replace(fragment: '')) : true);
}
