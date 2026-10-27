import 'dart:convert';
import 'package:html/parser.dart' as html;
import 'epub_builder.dart';
import 'ranobe_client.dart' show documentNodesToHtml, escapeXml;

class ImportedBook {
  ImportedBook(
      {required Iterable<BookChapter> chapters,
      this.title,
      this.author,
      this.language,
      this.complete = true,
      this.expectedChapters})
      : chapters = List.unmodifiable(chapters);
  final List<BookChapter> chapters;
  final String? title;
  final String? author;
  final String? language;

  /// Every chapter declared by this import is present. This is not a claim
  /// that an arbitrary text file represents an entire published work.
  final bool complete;
  final int? expectedChapters;
}

class ImportFile {
  const ImportFile(this.name, this.source);
  final String name;
  final String source;
}

/// Pure file parsing and validation. A malformed file rejects the whole batch;
/// no chapter is silently skipped, replaced with a placeholder or truncated.
class ImportParser {
  static const int maxFileBytes = 16 * 1024 * 1024;
  static const int maxTotalBytes = 64 * 1024 * 1024;
  static const int maxChapters = 500;

  static List<ImportFile> orderedFiles(Iterable<ImportFile> files) =>
      files.toList()..sort((a, b) => naturalCompare(a.name, b.name));

  /// Compare long numeric runs without JavaScript integer precision loss.
  static int naturalCompare(String left, String right) {
    final tokens = RegExp(r'\d+|\D+');
    final a =
        tokens.allMatches(left.toLowerCase()).map((m) => m.group(0)!).toList();
    final b =
        tokens.allMatches(right.toLowerCase()).map((m) => m.group(0)!).toList();
    for (var i = 0; i < a.length && i < b.length; i++) {
      if (a[i] == b[i]) continue;
      if (RegExp(r'^\d+$').hasMatch(a[i]) && RegExp(r'^\d+$').hasMatch(b[i])) {
        final an = a[i].replaceFirst(RegExp(r'^0+'), '');
        final bn = b[i].replaceFirst(RegExp(r'^0+'), '');
        final lengthOrder = an.length.compareTo(bn.length);
        if (lengthOrder != 0) return lengthOrder;
        final numericOrder = an.compareTo(bn);
        if (numericOrder != 0) return numericOrder;
      } else {
        final lexicalOrder = a[i].compareTo(b[i]);
        if (lexicalOrder != 0) return lexicalOrder;
      }
    }
    final tokenOrder = a.length.compareTo(b.length);
    return tokenOrder != 0 ? tokenOrder : left.compareTo(right);
  }

  static ImportedBook parseFiles(Iterable<ImportFile> files) {
    final sorted = orderedFiles(files);
    if (sorted.length > maxChapters) {
      throw const FormatException(
          'Choose no more than 500 chapter files at once.');
    }
    var totalBytes = 0;
    final books = <ImportedBook>[];
    var count = 0;
    for (final file in sorted) {
      totalBytes += utf8.encode(file.source).length;
      if (totalBytes > maxTotalBytes) {
        throw const FormatException(
            'Choose at most 64 MB of files per import.');
      }
      final book = parseFile(file.name, file.source);
      count += book.chapters.length;
      if (count > maxChapters) {
        throw const FormatException(
            'An import may contain at most 500 chapters.');
      }
      books.add(book);
    }
    return combine(books);
  }

  static ImportedBook parseFile(String filename, String source) {
    if (source.length > maxFileBytes ||
        utf8.encode(source).length > maxFileBytes) {
      throw FormatException('$filename is larger than the 16 MB file limit.');
    }
    final normalized =
        source.startsWith('\uFEFF') ? source.substring(1) : source;
    final ext = filename.split('.').last.toLowerCase();
    final stem = filename.replaceFirst(RegExp(r'\.[^.]+$'), '').trim();
    final label = stem.isEmpty ? 'Imported chapter' : stem;
    if (ext == 'json') return _fromJson(normalized, label);
    if (ext == 'txt') {
      return ImportedBook(
          chapters: [_chapter(label, textToHtml(normalized), filename)],
          expectedChapters: 1);
    }
    if (ext == 'html' || ext == 'htm') {
      return ImportedBook(
          chapters: [_chapter(label, normalized, filename)],
          expectedChapters: 1);
    }
    throw FormatException(
        'Unsupported file: $filename. Choose TXT, HTML or JSON.');
  }

  static ImportedBook combine(Iterable<ImportedBook> imported) {
    final books = imported.toList();
    final chapters = books.expand((b) => b.chapters).toList();
    if (chapters.length > maxChapters) {
      throw const FormatException(
          'An import may contain at most 500 chapters.');
    }
    String? consistent(String? Function(ImportedBook) field) {
      if (books.isEmpty) return null;
      final first = field(books.first);
      return first != null && books.every((b) => field(b) == first)
          ? first
          : null;
    }

    return ImportedBook(
        chapters: chapters,
        title: consistent((b) => b.title),
        author: consistent((b) => b.author),
        language: consistent((b) => b.language),
        complete: books.every((b) => b.complete),
        expectedChapters:
            books.isNotEmpty && books.every((b) => b.expectedChapters != null)
                ? books.fold<int>(0, (sum, b) => sum + b.expectedChapters!)
                : null);
  }

  static ImportedBook _fromJson(String source, String fallback) {
    dynamic data;
    try {
      data = jsonDecode(source);
    } catch (_) {
      throw FormatException(
          'Invalid JSON in $fallback. No chapters were imported.');
    }
    final metadata = <Map>[];
    for (var depth = 0; data is Map && data.containsKey('data'); depth++) {
      if (depth >= 4)
        throw FormatException('Too many JSON wrappers in $fallback.');
      metadata.add(data);
      data = data['data'];
    }
    if (data is Map) metadata.add(data);
    dynamic rawChapters;
    if (data is Map && data.containsKey('chapters')) {
      rawChapters = data['chapters'];
      if (rawChapters is! List)
        throw FormatException(
            'The chapters field must be a list in $fallback.');
    } else if (data is List) {
      rawChapters = data;
    } else if (data is Map) {
      rawChapters = [data];
    } else {
      throw FormatException(
          'Expected a chapter, array, or {"chapters": [...]} in $fallback.');
    }
    final list = rawChapters as List;
    if (list.isEmpty)
      throw FormatException('No chapters were found in $fallback.');
    if (list.length > maxChapters) {
      throw FormatException(
          '$fallback contains more than 500 chapters. Nothing was truncated.');
    }
    final chapters = <BookChapter>[];
    for (var index = 0; index < list.length; index++) {
      final raw = list[index];
      final where = '$fallback, chapter ${index + 1}';
      if (raw is! Map)
        throw FormatException('Expected a chapter object in $where.');
      final titleValue = raw['title'] ?? raw['name'];
      if (titleValue != null && titleValue is! String) {
        throw FormatException('The chapter title must be text in $where.');
      }
      final title = titleValue?.toString().trim();
      chapters.add(_chapter(
          title == null || title.isEmpty ? 'Chapter ${index + 1}' : title,
          _chapterHtml(raw, where),
          where));
    }
    var complete = true;
    int? expected;
    for (final map in metadata) {
      if (map.containsKey('complete')) {
        if (map['complete'] is! bool)
          throw FormatException(
              'The complete field must be true or false in $fallback.');
        complete = complete && map['complete'] == true;
      }
      if (map['capturedChapters'] != null) {
        final captured =
            _count(map['capturedChapters'], 'capturedChapters', fallback);
        if (captured != chapters.length) {
          throw FormatException(
              'The captured chapter count does not match the JSON in $fallback.');
        }
      }
      if (map['expectedChapters'] != null) {
        final declared =
            _count(map['expectedChapters'], 'expectedChapters', fallback);
        if (expected != null && expected != declared) {
          throw FormatException(
              'Conflicting expected chapter counts in $fallback.');
        }
        expected = declared;
      }
    }
    if (expected != null) {
      if (expected < chapters.length)
        throw FormatException(
            'The expected count is smaller than the imported chapters in $fallback.');
      if (expected > chapters.length) complete = false;
    }
    String? field(String key, [String? alternative]) {
      for (final map in metadata.reversed) {
        final value =
            map[key] ?? (alternative == null ? null : map[alternative]);
        if (value == null) continue;
        if (value is! String)
          throw FormatException('The $key field must be text in $fallback.');
        if (value.trim().isNotEmpty) return value.trim();
      }
      return null;
    }

    final language = field('language', 'lang');
    if (language != null &&
        !RegExp(r'^[A-Za-z]{2,8}(?:-[A-Za-z0-9]{1,8})*$').hasMatch(language)) {
      throw FormatException(
          'Use a language code such as ru or en in $fallback.');
    }
    return ImportedBook(
        chapters: chapters,
        title: field('title'),
        author: field('author'),
        language: language,
        complete: complete,
        expectedChapters: expected);
  }

  static int _count(dynamic value, String field, String filename) {
    if (value is! int || value < 0)
      throw FormatException(
          '$field must be a nonnegative integer in $filename.');
    return value;
  }

  static String _chapterHtml(Map chapter, String where) {
    final content = chapter['html'] ?? chapter['content'] ?? chapter['text'];
    if (content is String) {
      if (content.trim().isEmpty)
        throw FormatException('Empty chapter text in $where.');
      if (chapter['html'] != null ||
          RegExp(r'<[a-zA-Z][^>]*>').hasMatch(content)) return content;
      return textToHtml(content);
    }
    if (content is Map &&
        content['type'] == 'doc' &&
        content['content'] is List) {
      final nodes = content['content'] as List;
      if (!_validateNodes(nodes, where, 0))
        throw FormatException('No chapter text found in $where.');
      return documentNodesToHtml(nodes);
    }
    throw FormatException(
        'Missing or invalid chapter text in $where. Supply html, text, or content.');
  }

  static bool _validateNodes(List nodes, String where, int depth) {
    if (depth > 50)
      throw FormatException('Chapter content is nested too deeply in $where.');
    var hasText = false;
    for (final node in nodes) {
      if (node is! Map || node['type'] is! String)
        throw FormatException('Invalid document node in $where.');
      if (node['type'] == 'text') {
        if (node['text'] is! String)
          throw FormatException('Invalid text node in $where.');
        hasText = hasText || (node['text'] as String).trim().isNotEmpty;
      }
      if (node.containsKey('content')) {
        if (node['content'] is! List)
          throw FormatException('Invalid document content in $where.');
        final childHasText =
            _validateNodes(node['content'] as List, where, depth + 1);
        hasText = hasText || childHasText;
      }
    }
    return hasText;
  }

  static BookChapter _chapter(String title, String source, String where) {
    final document = html.parseFragment(source);
    for (final node in document
        .querySelectorAll(
          'script,style,iframe,object,embed,svg,head,noscript,template,form,input,button,textarea,select,canvas,video,audio',
        )
        .toList()) {
      node.remove();
    }
    if ((document.text ?? '')
        .replaceAll(RegExp(r'[\s\u200B\uFEFF]+'), '')
        .isEmpty) {
      throw FormatException('No readable chapter text found in $where.');
    }
    return BookChapter(title, sanitizeHtml(source));
  }

  static String textToHtml(String text) {
    final cleaned = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').trim();
    if (cleaned.isEmpty) throw const FormatException('The text file is empty.');
    return cleaned
        .split(RegExp(r'\n\s*\n+'))
        .map(
          (paragraph) =>
              '<p>${escapeXml(paragraph.trim()).replaceAll('\n', '<br/>')}</p>',
        )
        .join('\n');
  }
}
