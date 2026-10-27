import 'dart:convert';

import 'package:http/http.dart' as http;

/// RanobeLIB's public JSON API. Browser CORS and site restrictions still apply.
class RanobeClient {
  RanobeClient({http.Client? httpClient}) : _http = httpClient ?? http.Client();

  final http.Client _http;
  static const _api = 'https://api.cdnlibs.org/api/manga/';

  static String slugFromUrl(String value) {
    final url = Uri.tryParse(value.trim());
    if (url == null ||
        url.scheme != 'https' ||
        url.host.toLowerCase() != 'ranobelib.me' ||
        url.userInfo.isNotEmpty ||
        url.hasPort ||
        url.pathSegments.length != 3 ||
        url.pathSegments[0] != 'ru' ||
        url.pathSegments[1] != 'book' ||
        !RegExp(r'^\d+--[A-Za-z0-9_-]+$').hasMatch(url.pathSegments[2])) {
      throw const FormatException('Paste a RanobeLIB book URL (https://ranobelib.me/ru/book/123--title).');
    }
    return url.pathSegments[2];
  }

  Future<dynamic> _get(Uri uri) async {
    try {
      final response = await _http
          .get(uri, headers: const {'Site-Id': '3'})
          .timeout(const Duration(seconds: 25));
      if (response.statusCode == 403) {
        throw const RanobeException(
          'RanobeLIB refused direct browser access (HTTP 403). '
          'A browser app cannot bypass its protection. Use Import files instead.',
        );
      }
      if (response.statusCode == 429) {
        throw const RanobeException('RanobeLIB rate limited this request (HTTP 429).');
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw RanobeException('RanobeLIB returned HTTP ' + response.statusCode.toString() + '.');
      }
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map || !decoded.containsKey('data')) {
        throw const RanobeException('Unexpected RanobeLIB response.');
      }
      return decoded['data'];
    } on RanobeException {
      rethrow;
    } on FormatException {
      throw const RanobeException('RanobeLIB returned invalid JSON.');
    } on http.ClientException {
      throw const RanobeException(
        'Browser cannot read the RanobeLIB API (likely CORS restrictions). '
        'Use Import files to create an EPUB locally.',
      );
    } catch (error) {
      if (error is RanobeException) rethrow;
      throw RanobeException('Cannot contact RanobeLIB (CORS / protection / connection): ' + error.toString());
    }
  }

  Future<Novel> inspect(String bookUrl) async {
    final slug = slugFromUrl(bookUrl);
    final metadata = await _get(Uri.parse(_api + slug));
    if (metadata is! Map) throw const RanobeException('Book metadata not found.');
    final book = Map<String, dynamic>.from(metadata);
    final rawChapters = await _get(Uri.parse(_api + slug + '/chapters'));
    if (rawChapters is! List) throw const RanobeException('Chapter list is missing.');

    final branches = <String, String>{'auto': 'Automatic translation'};
    final candidates = <NovelChapter>[];
    for (final raw in rawChapters) {
      if (raw is! Map) continue;
      final item = Map<String, dynamic>.from(raw);
      final translationIds = <String>[];
      final translations = item['branches'];
      if (translations is! List) continue;
      for (final entry in translations) {
        if (entry is! Map) continue;
        final branch = Map<String, dynamic>.from(entry);
        final restricted = branch['restricted_view'];
        if (restricted is Map && restricted['is_open'] == false) continue;
        final moderation = branch['moderation'];
        if (moderation is Map && moderation['id'] == 0) continue;
        final id = (branch['branch_id'] ?? 0).toString();
        if (translationIds.contains(id)) continue;
        translationIds.add(id);
        final teamItems = branch['teams'];
        String? teamName;
        if (teamItems is List && teamItems.isNotEmpty && teamItems.first is Map) {
          teamName = ((teamItems.first as Map)['name'] ?? '').toString().trim();
        }
        if (teamName == null || teamName.isEmpty) {
          final team = branch['team'];
          if (team is Map) teamName = (team['name'] ?? '').toString().trim();
        }
        branches[id] = teamName == null || teamName.isEmpty ? 'Translation ' + id : teamName;
      }
      if (translationIds.isEmpty) continue;
      candidates.add(NovelChapter(
        volume: (item['volume'] ?? 0).toString(),
        number: (item['number'] ?? 0).toString(),
        name: (item['name'] ?? '').toString(),
        availableBranches: translationIds,
        index: item['index'] is num ? (item['index'] as num).toInt() : 0,
      ));
    }
    candidates.sort((a, b) {
      final v = _naturalKey(a.volume).compareTo(_naturalKey(b.volume));
      if (v != 0) return v;
      final n = _naturalKey(a.number).compareTo(_naturalKey(b.number));
      return n != 0 ? n : a.index.compareTo(b.index);
    });
    final chapters = <NovelChapter>[];
    final seen = <String>{};
    for (final candidate in candidates) {
      if (seen.add(candidate.volume + '/' + candidate.number)) chapters.add(candidate);
    }
    final authors = book['authors'];
    String author = 'Unknown author';
    if (authors is List && authors.isNotEmpty && authors.first is Map) {
      author = ((authors.first as Map)['name'] ?? author).toString();
    }
    return Novel(
      slug: slug,
      title: (book['rus_name'] ?? book['eng_name'] ?? book['name'] ?? 'Untitled').toString(),
      author: author,
      chapters: chapters,
      branches: branches,
    );
  }

  List<NovelChapter> chaptersFor(Novel novel, String branch) =>
      novel.chapters.where((c) =>
          branch == 'auto' ? c.availableBranches.isNotEmpty
                           : c.availableBranches.contains(branch)).toList();

  Future<String> fetchChapter(Novel novel, NovelChapter chapter, String branch) async {
    final selected = branch == 'auto' ? chapter.availableBranches.first : branch;
    final query = <String, String>{
      'volume': chapter.volume,
      'number': chapter.number,
      if (selected != '0') 'branch_id': selected,
    };
    final result = await _get(Uri.parse(_api + novel.slug + '/chapter')
        .replace(queryParameters: query));
    if (result is! Map) throw RanobeException('Missing chapter ' + chapter.number);
    final doc = Map<String, dynamic>.from(result);
    final content = doc['content'];
    if (content is String) return content;
    if (content is Map && content['type'] == 'doc' && content['content'] is List) {
      return documentNodesToHtml(content['content'] as List);
    }
    throw RanobeException('Unsupported chapter content: ' + chapter.number);
  }

  void close() => _http.close();
}

int _naturalKey(String value) {
  final parts = RegExp(r'\d+').allMatches(value).map((m) => m.group(0)!).toList();
  if (parts.isEmpty) return 0;
  final major = int.tryParse(parts[0]) ?? 0;
  final minor = parts.length > 1 ? (int.tryParse(parts[1]) ?? 0) : 0;
  return major * 100000 + minor;
}

String escapeXml(String text) => text
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');

String documentNodesToHtml(List<dynamic> nodes) {
  final result = StringBuffer();
  for (final item in nodes) {
    if (item is! Map) continue;
    final node = Map<String, dynamic>.from(item);
    final type = (node['type'] ?? '').toString();
    if (type == 'text') {
      var text = escapeXml((node['text'] ?? '').toString());
      final marks = node['marks'];
      if (marks is List) {
        for (final mark in marks) {
          if (mark is! Map) continue;
          final tag = switch (mark['type']) {
            'bold' => 'strong',
            'italic' => 'em',
            'underline' => 'u',
            'strike' => 's',
            'code' => 'code',
            _ => '',
          };
          if (tag.isNotEmpty) text = '<' + tag + '>' + text + '</' + tag + '>';
        }
      }
      result.write(text);
      continue;
    }
    if (type == 'hardBreak') {
      result.write('<br/>');
      continue;
    }
    if (type == 'horizontalRule') {
      result.write('<hr/>');
      continue;
    }
    final tag = switch (type) {
      'paragraph' => 'p',
      'heading' => 'h2',
      'blockquote' => 'blockquote',
      'orderedList' => 'ol',
      'bulletList' => 'ul',
      'listItem' => 'li',
      'bold' => 'strong',
      'italic' => 'em',
      _ => '',
    };
    final inner = node['content'] is List
        ? documentNodesToHtml(node['content'] as List) : '';
    if (tag.isNotEmpty) {
      result.write('<' + tag + '>' + (inner.isEmpty ? ' ' : inner) + '</' + tag + '>');
    } else if (type == 'image') {
      result.write('<p>[Illustration omitted in browser-only export]</p>');
    } else {
      result.write(inner);
    }
  }
  return result.toString();
}

class RanobeException implements Exception {
  const RanobeException(this.message);
  final String message;
  @override
  String toString() => message;
}

class NovelChapter {
  const NovelChapter({
    required this.volume,
    required this.number,
    required this.name,
    required this.availableBranches,
    required this.index,
  });
  final String volume;
  final String number;
  final String name;
  final List<String> availableBranches;
  final int index;

  String get title => name.trim().isEmpty
      ? 'Chapter ' + number
      : 'Chapter ' + number + ' — ' + name;
}

class Novel {
  const Novel({
    required this.slug,
    required this.title,
    required this.author,
    required this.chapters,
    required this.branches,
  });
  final String slug;
  final String title;
  final String author;
  final List<NovelChapter> chapters;
  final Map<String, String> branches;
}
