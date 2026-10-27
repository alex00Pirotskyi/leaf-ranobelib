import 'dart:convert';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as parser;
import 'package:http/http.dart' as http;

import 'open_reader.dart';

/// A source-confirmed reading order. URLs are never generated from numbers.
class BookManifest {
  BookManifest({
    required this.sourceUrl,
    required this.title,
    required this.author,
    required this.language,
    required List<Uri> chapters,
    this.note,
  }) : chapters = List<Uri>.unmodifiable(chapters);

  final Uri sourceUrl;
  final String title;
  final String author;
  final String language;
  final List<Uri> chapters;
  final String? note;
}

/// Discovers ordered contents through Wikimedia's public, CORS-enabled API.
///
/// Only source-linked book descendants and explicitly marked contents are
/// followed. Edition indexes, red links, ambiguous/empty pages and limits are
/// reported instead of producing a silently incomplete book.
class BookDiscovery {
  BookDiscovery({http.Client? client}) : _client = client ?? http.Client();

  static const maxChapters = 500;
  static const maxContentsPages = 64;
  final http.Client _client;
  DateTime? _lastRequest;

  static bool supports(Uri page) => OpenReader.supports(page);

  Future<BookManifest> discover(Uri url) async {
    if (!supports(url)) {
      throw const FormatException(
        'Automatic contents are available for Wikisource and Wikibooks links.',
      );
    }
    final cache = <String, _WikiPage>{};
    var page = await _load(url, cache);
    _checkPage(page);
    var entries = _contents(page);
    var recoveredParent = false;

    // A chapter's actual header/breadcrumb may identify the complete work.
    // Do not guess a parent by stripping a path segment (editions use slashes).
    if (entries.isEmpty) {
      for (final parentUrl in _linkedParents(page).take(4)) {
        try {
          final parent = await _load(parentUrl, cache);
          _checkPage(parent);
          final parentEntries = _contents(parent);
          if (parentEntries.any((entry) =>
              entry.url == page.url ||
              _titleOf(page.url).startsWith('${_titleOf(entry.url)}/'))) {
            page = parent;
            entries = parentEntries;
            recoveredParent = true;
            break;
          }
        } on FormatException {
          // Unavailable or ambiguous parent is not authority for a whole book.
          // The readable original chapter remains available with a clear note.
        }
      }
    }

    final result = <Uri>[];
    final seen = <String>{};
    final visiting = <String>{};
    var includesFrontMatter = false;

    void append(Uri chapter) {
      if (!seen.add(chapter.toString())) return;
      if (result.length >= maxChapters) {
        throw const FormatException(
          'This book has more than 500 source sections. Choose a smaller '
          'volume or a manual range; nothing was silently truncated.',
        );
      }
      result.add(chapter);
    }

    Future<void> walk(_WikiPage current, List<_Entry> children, int depth) async {
      if (depth > 8 || !visiting.add(current.url.toString())) {
        throw const FormatException(
          'The source contents are circular or too deeply nested. '
          'Choose one volume instead.',
        );
      }
      try {
        if (children.isEmpty) {
          _requireReadable(current);
          append(current.url);
          return;
        }
        if (_hasFrontMatter(current, children)) {
          append(current.url);
          includesFrontMatter = true;
        }
        for (final entry in children) {
          final hasListedChildren = children.any((other) =>
              other.url != entry.url &&
              _titleOf(other.url).startsWith('${_titleOf(entry.url)}/'));
          if (entry.isVolume || hasListedChildren) {
            final volume = await _load(entry.url, cache);
            _checkPage(volume);
            await walk(volume, _contents(volume), depth + 1);
          } else {
            append(entry.url);
          }
        }
      } finally {
        visiting.remove(current.url.toString());
      }
    }

    await walk(page, entries, 0);
    final isChapter = _looksLikeChapter(_titleOf(page.url).split('/').last) ||
        _linkedParents(page).isNotEmpty;
    final note = entries.isEmpty
        ? (isChapter
            ? 'Only this page was identified. Complete book contents could '
                'not be confirmed; use the book contents link for more chapters.'
            : 'The source provides the reading text on one page.')
        : 'Source contents: ${result.length} sections'
            '${includesFrontMatter ? ', including text from the contents page' : ''}.'
            '${recoveredParent ? ' Found from the chapter’s book link.' : ''}'
            ' Chapter availability is checked while downloading.';
    return BookManifest(
      sourceUrl: page.url,
      title: _metadata(page.document, [
            '#ws-title', '#header_title_text', '#header-title-text',
            '.wst-header-title-text',
          ]) ??
          page.title,
      author: (_metadata(page.document, [
                '#ws-author a', '#ws-author', '#header_author_text a',
                '#header-author-text a', '.contributor-text .fn',
              ]) ??
              '')
          .replaceFirst(RegExp(r'^(?:by|автор)\s+', caseSensitive: false), ''),
      language: page.url.host.split('.').first,
      chapters: result,
      note: note,
    );
  }

  Future<_WikiPage> _load(Uri url, Map<String, _WikiPage> cache) async {
    final canonical = _pageUrl(url.host, _titleOf(url));
    final cached = cache[canonical.toString()];
    if (cached != null) return cached;
    if (cache.length >= maxContentsPages) {
      throw const FormatException(
        'This book requires more than 64 contents pages. Choose one volume; '
        'the contents have not been truncated.',
      );
    }
    final last = _lastRequest;
    if (last != null) {
      final remaining = const Duration(milliseconds: 180) -
          DateTime.now().difference(last);
      if (remaining > Duration.zero) await Future<void>.delayed(remaining);
    }
    _lastRequest = DateTime.now();
    final base = OpenReader.apiUrl(canonical);
    final endpoint = base.replace(queryParameters: {
      ...base.queryParameters,
      'prop': 'text|properties|categories',
      'redirects': '1',
    });
    late final http.Response response;
    try {
      response = await _client.get(endpoint, headers: const {
        'Accept': 'application/json',
      }).timeout(const Duration(seconds: 25));
    } catch (_) {
      throw const FormatException(
        'Could not reach the source contents. Check your connection and retry. '
        'A browser access error does not necessarily mean CAPTCHA.',
      );
    }
    if (response.statusCode == 429) {
      throw const FormatException(
        'The source is limiting requests. Your book has not been truncated; '
        'wait before trying again.',
      );
    }
    if (response.statusCode != 200) {
      throw FormatException(
        'The source contents returned HTTP ${response.statusCode}.',
      );
    }
    dynamic body;
    try {
      body = jsonDecode(utf8.decode(response.bodyBytes));
    } catch (_) {
      throw const FormatException('The source returned invalid contents data.');
    }
    if (body is! Map || body['error'] != null) {
      final error = body is Map ? body['error'] : null;
      throw FormatException(
        'The requested source page is unavailable${error == null ? '.' : ': $error'}',
      );
    }
    final parsed = body['parse'];
    if (parsed is! Map || parsed['text'] is! String) {
      throw const FormatException('This source page has no readable content.');
    }
    final title = (parsed['title'] ?? _titleOf(canonical)).toString();
    final page = _WikiPage(
      _pageUrl(canonical.host, title),
      title,
      parsed['text'] as String,
      parsed,
    );
    cache[canonical.toString()] = page;
    return page;
  }

  void close() => _client.close();
}

class _WikiPage {
  _WikiPage(this.url, this.title, this.html, this.data)
      : document = parser.parseFragment(html);
  final Uri url;
  final String title;
  final String html;
  final Map data;
  final dom.DocumentFragment document;
}

class _Entry {
  const _Entry(this.url, this.isVolume);
  final Uri url;
  final bool isVolume;
}

const _tocSelector = '.ws-toc, .wst-toc-table, .wst-auxtoc, .book-toc, '
    '#book-toc, [data-book-toc], .toc, #toc, .toccolours, .ws-summary';
const _navigationSelector = 'script, style, noscript, nav, footer, '
    '.mw-editsection, .ws-header, .wst-header, #headertemplate, .headertemplate, '
    '.ws-footer, #ws-footer, .wst-footer, .navbox, .catlinks, .sistersitebox, '
    '.plainSister, .licenseContainer, .licensetemplate, .mw-cite-backlink, '
    '.reference, .references, .ws-noexport, .metadata, .portal';

List<_Entry> _contents(_WikiPage page) {
  final document = parser.parseFragment(page.html);
  for (final item in document.querySelectorAll(_navigationSelector).toList()) {
    item.remove();
  }
  final entries = <_Entry>[];
  final seen = <String>{};
  final parentTitle = _titleOf(page.url);
  for (final anchor in document.querySelectorAll('a[href]')) {
    final target = _wikiLink(page.url, anchor);
    if (target == null || target == page.url) continue;
    final targetTitle = _titleOf(target);
    final isChild = targetTitle.startsWith('$parentTitle/');
    final inContents = _hasAncestor(anchor, _tocSelector);
    final inListOrTable = _hasAncestor(anchor, 'ul, ol, table, dl');
    // Unrelated article references outside an explicit contents block are
    // not evidence of chapter membership, even if numbered in their labels.
    if (!(isChild && (inListOrTable || inContents)) && !inContents) continue;
    if (_isMissing(anchor)) {
      throw FormatException(
        'The source contents include an unavailable section: '
        '${anchor.text.trim()}. Choose another edition or a manual range.',
      );
    }
    if (!seen.add(target.toString())) continue;
    if (entries.length >= BookDiscovery.maxChapters) {
      throw const FormatException(
        'The source lists more than 500 sections. Choose one volume or '
        'a smaller manual range; nothing was silently truncated.',
      );
    }
    entries.add(_Entry(target, _looksLikeVolume(targetTitle.split('/').last) ||
        _looksLikeVolume(anchor.text.trim())));
  }
  return entries;
}

void _checkPage(_WikiPage page) {
  if (!_isReadingTitle(page.title)) {
    throw const FormatException(
      'Open a book or an edition, rather than an author, category or help page.',
    );
  }
  final properties = page.data['properties'];
  final categories = page.data['categories'];
  final markedIncomplete = categories is List && categories.any((entry) =>
      entry is Map && RegExp(
        r'incomplete (?:texts|transcriptions)|неполные тексты|тексты с пропусками',
        caseSensitive: false,
      ).hasMatch((entry['category'] ?? entry['*'] ?? '').toString().replaceAll('_', ' ')));
  if (markedIncomplete || page.document.querySelector(
      '.ws-incomplete, .wst-incomplete, [data-book-incomplete="true"]') != null) {
    throw const FormatException(
      'The source marks this text as incomplete. Choose a completed edition '
      'or select the available chapters manually.',
    );
  }
  final propertyDisambiguation =
      (properties is Map && properties.containsKey('disambiguation')) ||
      (properties is List && properties.any((entry) =>
          entry is Map && entry['name'] == 'disambiguation'));
  final categoryDisambiguation = categories is List && categories.any((entry) =>
      entry is Map && RegExp(
        r'disambiguation|неоднозначност|многозначност|списки\s+редакций',
        caseSensitive: false,
      ).hasMatch((entry['category'] ?? entry['*'] ?? '').toString().replaceAll('_', ' ')));
  if (propertyDisambiguation || categoryDisambiguation ||
      page.document.querySelector(
        '.disambig, .disambigbox, #disambigbox, .ws-disambig, '
        '.wst-versions, .edition-list, #disambig, #versions',
      ) != null) {
    throw const FormatException(
      'This page lists different works or editions. Open one complete '
      'edition first so versions are not mixed together.',
    );
  }
  // Version-index templates are not consistently marked across languages.
  // Inspect the body only, excluding the "other editions" menu found on
  // ordinary book and chapter pages.
  final body = parser.parseFragment(page.html);
  for (final item in body.querySelectorAll(_navigationSelector).toList()) {
    item.remove();
  }
  final text = (body.text ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
  if (RegExp(
    r'(this page (?:links|lists).*?(?:versions|editions)|'
    r'список (?:доступных )?(?:редакций|изданий)|'
    r'существуют (?:другие|различные) (?:редакции|версии))',
    caseSensitive: false,
  ).hasMatch(text) && body.querySelectorAll('a[href]').length > 1) {
    throw const FormatException(
      'Choose one edition from this page before creating the EPUB.',
    );
  }
  if (text.isEmpty) {
    throw const FormatException('This page has no readable text or contents.');
  }
}

void _requireReadable(_WikiPage page) {
  final text = (parser.parseFragment(extractWikiText(page.html)).text ?? '')
      .replaceAll(RegExp(r'\s+'), ' ').trim();
  if (text.length < 80) {
    throw const FormatException(
      'No readable chapter or reliable book contents were found. '
      'Open the complete edition or enter chapter links manually.',
    );
  }
  // Link-only indexes must not become a misleading one-chapter "book".
  final content = parser.parseFragment(extractWikiText(page.html));
  final linkedText = content.querySelectorAll('a').fold<int>(
      0, (length, anchor) => length + anchor.text.trim().length);
  if (linkedText > text.length * .65 && content.querySelector('pre, .poem') == null) {
    throw const FormatException(
      'This is a link index, not confirmed reading text. Choose a book edition.',
    );
  }
}

bool _hasFrontMatter(_WikiPage page, List<_Entry> entries) {
  final body = parser.parseFragment(extractWikiText(page.html));
  final targets = entries.map((entry) => entry.url.toString()).toSet();
  for (final anchor in body.querySelectorAll('a[href]').toList()) {
    final target = _wikiLink(page.url, anchor);
    if (target == null || !targets.contains(target.toString())) continue;
    var parent = anchor.parent;
    while (parent != null) {
      if (const ['ul', 'ol', 'table', 'dl'].contains(parent.localName)) {
        parent.remove();
        break;
      }
      parent = parent.parent;
    }
    anchor.remove();
  }
  var length = 0;
  for (final block in body.querySelectorAll('p, pre, blockquote, .poem')) {
    if (_hasAncestor(block, 'p, pre, blockquote, .poem')) continue;
    final text = block.text.replaceAll(RegExp(r'\s+'), ' ').trim();
    // Short display-title lines and publisher addresses are not prose.
    if (text.length >= 80) length += text.length;
  }
  return length >= 180;
}

List<Uri> _linkedParents(_WikiPage page) {
  final parents = <Uri>[];
  for (final anchor in page.document.querySelectorAll(
    '#header_title_text a, #header-title-text a, .wst-header-title-text a, '
    '.subpages a, #sub_nav a, .wb-breadcrumb a',
  )) {
    final target = _wikiLink(page.url, anchor);
    if (target != null && _titleOf(page.url).startsWith('${_titleOf(target)}/') &&
        !parents.contains(target)) {
      parents.add(target);
    }
  }
  return parents;
}

Uri? _wikiLink(Uri base, dom.Element anchor) {
  final href = anchor.attributes['href'];
  if (href == null || href.isEmpty || href.startsWith('#')) return null;
  Uri target;
  try {
    target = base.resolve(href);
  } on FormatException {
    return null;
  }
  if (target.host != base.host || target.scheme != 'https' ||
      target.userInfo.isNotEmpty || target.hasPort) return null;
  String title;
  if (OpenReader.supports(target)) {
    title = _titleOf(target);
  } else if (target.path == '/w/index.php' &&
      target.queryParameters['title'] != null) {
    final action = target.queryParameters['action'];
    if (action != null && action != 'view' && !_isMissing(anchor)) return null;
    title = target.queryParameters['title']!.replaceAll('_', ' ');
  } else {
    return null;
  }
  if (!_isReadingTitle(title)) return null;
  return _pageUrl(base.host, title);
}

bool _isMissing(dom.Element anchor) => anchor.classes.contains('new') ||
    (Uri.tryParse(anchor.attributes['href'] ?? '')?.queryParameters['redlink'] == '1');

bool _hasAncestor(dom.Element element, String selector) {
  var parent = element.parent;
  while (parent != null) {
    if (_matchesSimpleSelector(parent, selector)) return true;
    parent = parent.parent;
  }
  return false;
}

// Only tag/class/id/attribute-existence selectors are used for ancestry here.
// package:html does not provide the browser Element.matches() API.
bool _matchesSimpleSelector(dom.Element element, String selectors) =>
    selectors.split(',').any((part) {
      final selector = part.trim();
      if (selector.startsWith('.')) {
        return element.classes.contains(selector.substring(1));
      }
      if (selector.startsWith('#')) return element.id == selector.substring(1);
      if (selector.startsWith('[') && selector.endsWith(']')) {
        return element.attributes.containsKey(selector.substring(1, selector.length - 1));
      }
      return element.localName == selector;
    });

String? _metadata(dom.DocumentFragment document, List<String> selectors) {
  for (final selector in selectors) {
    final text = document.querySelector(selector)?.text
        .replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text != null && text.isNotEmpty) return text;
  }
  return null;
}

bool _looksLikeVolume(String text) => RegExp(
  r'^(?:volume|vol\.?|part|book|том|часть|книга)(?:[\s.:_-]|$)',
  caseSensitive: false,
).hasMatch(text);

bool _looksLikeChapter(String text) => RegExp(
  r'^(?:chapter|chap\.?|глава|раздел)(?:[\s.:_-]|$)|^[IVXLCDM]+$|^\d+(?:\.\d+)?$',
  caseSensitive: false,
).hasMatch(text);

bool _isReadingTitle(String title) => title.trim().isNotEmpty && !RegExp(
  r'^(?:Author|Автор|Category|Категория|Index|Индекс|Page|Страница|'
  r'File|Image|Файл|Изображение|Template|Шаблон|Help|Справка|'
  r'Special|Служебная|User|Участник|Talk|Обсуждение|'
  r'Wikisource|Викитека|Wikibooks|Викиучебник|Portal|Портал)(?: talk|:|_)',
  caseSensitive: false,
).hasMatch(title);

String _titleOf(Uri url) => url.pathSegments.skip(1).join('/').replaceAll('_', ' ');
Uri _pageUrl(String host, String title) => Uri(
  scheme: 'https', host: host, path: '/wiki/${title.replaceAll(' ', '_')}',
);
