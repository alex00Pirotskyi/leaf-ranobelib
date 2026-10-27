import 'dart:async';
import 'dart:convert';

import 'package:html/parser.dart' as html;
import 'package:http/http.dart' as http;

/// Whether Leaf should discover a work's chapters or open an existing EPUB.
enum CatalogueBookKind { wikisource, directEpub }

class CatalogueBook {
  const CatalogueBook({
    required this.title,
    this.author = '',
    required this.language,
    required this.sourceName,
    required this.pageUrl,
    this.epubUrl,
    this.kind = CatalogueBookKind.wikisource,
  });

  final String title;
  final String author;
  final String language;
  final String sourceName;
  final Uri pageUrl;

  /// A source-provided download. Open this as a user-initiated navigation;
  /// the file server need not permit cross-origin fetches.
  final Uri? epubUrl;
  final CatalogueBookKind kind;
}

enum CatalogueFailureKind { network, rateLimited, unavailable, invalidResponse }

class CatalogueSourceFailure {
  const CatalogueSourceFailure(this.sourceName, this.message, this.kind);
  final String sourceName;
  final String message;
  final CatalogueFailureKind kind;
}

class CatalogueSearchResult {
  CatalogueSearchResult({
    required Iterable<CatalogueBook> books,
    Iterable<CatalogueSourceFailure> failures = const [],
  })  : books = List.unmodifiable(books),
        failures = List.unmodifiable(failures);

  final List<CatalogueBook> books;
  final List<CatalogueSourceFailure> failures;
  bool get isPartial => books.isNotEmpty && failures.isNotEmpty;
}

/// Directory entries are discovery links, not claims that Leaf can scrape them.
class CatalogueLibrary {
  const CatalogueLibrary({
    required this.name,
    required this.language,
    required this.url,
    required this.description,
    this.integrated = false,
  });
  final String name;
  final String language;
  final Uri url;
  final String description;
  final bool integrated;
}

/// Browser-only discovery through public MediaWiki Action APIs.
///
/// Search and reading APIs are deliberately separate from native file links:
/// a successful cross-origin catalogue request does not mean the EPUB host
/// permits fetch(). Other libraries remain explicitly external discovery links.
class BookCatalogue {
  BookCatalogue({
    http.Client? client,
    this.timeout = const Duration(seconds: 15),
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final Duration timeout;

  static Uri wikiPage(String language, String title) => Uri.https(
        '$language.wikisource.org',
        '/wiki/${title.replaceAll(' ', '_')}',
      );

  static Uri wikiEpub(String language, String title) => Uri.https(
        'ws-export.wmcloud.org',
        '/',
        {
          'lang': language,
          'page': title.replaceAll(' ', '_'),
          'format': 'epub-3'
        },
      );

  static CatalogueBook _featuredBook(
    String title,
    String author,
    String language,
    String wikiTitle,
  ) =>
      CatalogueBook(
        title: title,
        author: author,
        language: language,
        sourceName: language == 'ru' ? 'Викитека' : 'Wikisource',
        pageUrl: wikiPage(language, wikiTitle),
        epubUrl: wikiEpub(language, wikiTitle),
      );

  /// Verified edition pages, rather than similarly named lists of editions.
  /// Available immediately and still useful when a search service is busy.
  static final List<CatalogueBook> featured = List.unmodifiable([
    _featuredBook(
      'Капитанская дочка',
      'Александр Пушкин',
      'ru',
      'Капитанская дочка (Пушкин)/1960 (СО)',
    ),
    _featuredBook(
      "Alice's Adventures in Wonderland",
      'Lewis Carroll',
      'en',
      "Alice's Adventures in Wonderland (1866)",
    ),
    _featuredBook(
      'Евгений Онегин',
      'Александр Пушкин',
      'ru',
      'Евгений Онегин (Пушкин)/СС 1959 (СО)',
    ),
    CatalogueBook(
      title: 'Pride and Prejudice',
      author: 'Jane Austen',
      language: 'en',
      sourceName: 'Project Gutenberg',
      pageUrl: Uri.https('www.gutenberg.org', '/ebooks/1342'),
      epubUrl: Uri.https('www.gutenberg.org', '/ebooks/1342.epub3.images'),
      kind: CatalogueBookKind.directEpub,
    ),
  ]);

  static final List<CatalogueLibrary> libraries = List.unmodifiable([
    CatalogueLibrary(
      name: 'Викитека',
      language: 'ru',
      url: Uri.https('ru.wikisource.org', '/'),
      description: 'Русская классика. Поиск и сборка EPUB в Leaf.',
      integrated: true,
    ),
    CatalogueLibrary(
      name: 'Wikisource',
      language: 'en',
      url: Uri.https('en.wikisource.org', '/'),
      description: 'English works. Search and build EPUB in Leaf.',
      integrated: true,
    ),
    CatalogueLibrary(
      name: 'Project Gutenberg',
      language: 'en / ru',
      url: Uri.https('www.gutenberg.org', '/ebooks/'),
      description: 'Classic books with EPUB downloads on the source website.',
    ),
    CatalogueLibrary(
      name: 'Standard Ebooks',
      language: 'en',
      url: Uri.https('standardebooks.org', '/ebooks'),
      description:
          'Carefully formatted classics. Download on the source website.',
    ),
    CatalogueLibrary(
      name: 'Open Library',
      language: 'en / ru',
      url: Uri.https('openlibrary.org', '/'),
      description:
          'Find editions and reading availability. Some books require borrowing.',
    ),
    CatalogueLibrary(
      name: 'RanobeLIB',
      language: 'ru',
      url: Uri.https('ranobelib.me', '/'),
      description:
          'Ранобэ и переводы. Доступ и проверка пользователя — на сайте.',
    ),
    CatalogueLibrary(
      name: 'Author.Today',
      language: 'ru',
      url: Uri.https('author.today', '/'),
      description:
          'Современные авторы. Чтение и доступные загрузки — на сайте.',
    ),
    CatalogueLibrary(
      name: 'Royal Road',
      language: 'en',
      url: Uri.https('www.royalroad.com', '/'),
      description:
          'Web novels. Read on the source website; import available files.',
    ),
  ]);

  Future<CatalogueSearchResult> search(
    String query, {
    String language = 'all',
  }) async {
    if (!const ['all', 'ru', 'en'].contains(language)) {
      throw ArgumentError.value(language, 'language', 'Use all, ru or en.');
    }
    final trimmed = query.trim();
    if (trimmed.length > 200) {
      throw const FormatException('Search with a book title or author name.');
    }
    final languages = language == 'all' ? const ['ru', 'en'] : [language];
    final local = featured
        .where(
          (book) =>
              languages.contains(book.language) &&
              (trimmed.isEmpty ||
                  '${book.title} ${book.author}'.toLowerCase().contains(
                        trimmed.toLowerCase(),
                      )),
        )
        .toList();
    if (trimmed.length < 2) return CatalogueSearchResult(books: local);

    // Each provider handles its own failure; one outage cannot discard books
    // returned successfully by the other language's catalogue.
    final results = await Future.wait(
      languages.map((lang) => _searchWiki(trimmed, lang)),
    );
    final books = <String, CatalogueBook>{
      for (final book in local) book.pageUrl.toString(): book,
    };
    for (final result in results) {
      for (final book in result.books) {
        books.putIfAbsent(book.pageUrl.toString(), () => book);
      }
    }
    return CatalogueSearchResult(
      books: books.values,
      failures: results.expand((result) => result.failures),
    );
  }

  Future<CatalogueSearchResult> _searchWiki(
    String query,
    String language,
  ) async {
    final sourceName = language == 'ru' ? 'Викитека' : 'Wikisource';
    CatalogueSearchResult failure(String message, CatalogueFailureKind kind) =>
        CatalogueSearchResult(
          books: const [],
          failures: [CatalogueSourceFailure(sourceName, message, kind)],
        );
    // A version-list page is not a complete book. Search actual editions and
    // leave the final content/TOC verification to the reading adapter.
    final exclusions = language == 'ru'
        ? '-incategory:"Списки редакций" -incategory:"Неоднозначности"'
        : '-incategory:"Versions pages" -incategory:"Disambiguation pages"';
    final url = Uri.https('$language.wikisource.org', '/w/api.php', {
      'action': 'query',
      'list': 'search',
      'srsearch': '$query $exclusions',
      'srnamespace': '0',
      'srlimit': '24',
      'srprop': 'snippet',
      'format': 'json',
      'formatversion': '2',
      'origin': '*',
    });

    late final http.Response response;
    try {
      response = await _client.get(url,
          headers: const {'Accept': 'application/json'}).timeout(timeout);
    } on TimeoutException {
      return failure(
        'Search took too long. Try again.',
        CatalogueFailureKind.network,
      );
    } catch (_) {
      return failure(
        'Search is unavailable. Check your connection and retry.',
        CatalogueFailureKind.network,
      );
    }
    if (response.statusCode == 429) {
      return failure(
        'The catalogue is busy. Try again later.',
        CatalogueFailureKind.rateLimited,
      );
    }
    if (response.statusCode != 200) {
      return failure(
        'The catalogue returned HTTP ${response.statusCode}.',
        CatalogueFailureKind.unavailable,
      );
    }
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map)
        throw const FormatException('Invalid search response');
      if (decoded['error'] is Map) {
        final code = (decoded['error'] as Map)['code']?.toString() ?? '';
        if (code == 'cirrussearch-too-busy-error') {
          return _searchTitlePrefix(query, language, sourceName);
        }
        final busy = code.contains('busy') ||
            code.contains('ratelimit') ||
            code == 'maxlag';
        return failure(
          busy
              ? 'The catalogue is busy. Try again later.'
              : 'Search is temporarily unavailable.',
          busy
              ? CatalogueFailureKind.rateLimited
              : CatalogueFailureKind.unavailable,
        );
      }
      final payload = decoded['query'];
      if (payload is! Map || payload['search'] is! List) {
        throw const FormatException('Invalid search response');
      }
      final matches = <CatalogueBook>[];
      for (final item in payload['search'] as List) {
        if (item is! Map || item['title'] is! String || item['ns'] != 0)
          continue;
        final title = item['title'] as String;
        final snippet =
            html.parseFragment(item['snippet']?.toString() ?? '').text ?? '';
        if (!_isWorkResult(title, snippet)) continue;
        matches.add(
          CatalogueBook(
            title: title,
            language: language,
            sourceName: sourceName,
            pageUrl: wikiPage(language, title),
            epubUrl: wikiEpub(language, title),
          ),
        );
      }
      // Preserve search relevance within each group; editions often use a
      // subpage (e.g. /1960 (СО)), so slash-containing titles are not discarded.
      final roots = matches.where((b) => !b.title.contains('/'));
      final editions = matches.where((b) => b.title.contains('/'));
      return CatalogueSearchResult(books: [...roots, ...editions].take(16));
    } catch (_) {
      return failure(
        'The catalogue returned an unreadable response. Try again.',
        CatalogueFailureKind.invalidResponse,
      );
    }
  }

  /// One bounded lookup against the page database when Cirrus full-text
  /// search is busy. It matches title prefixes, not authors or arbitrary words.
  Future<CatalogueSearchResult> _searchTitlePrefix(
    String query,
    String language,
    String sourceName,
  ) async {
    final originalFailure = CatalogueSourceFailure(
      sourceName,
      'Full-text search is busy. Try a title beginning or retry later.',
      CatalogueFailureKind.rateLimited,
    );
    final url = Uri.https('$language.wikisource.org', '/w/api.php', {
      'action': 'query',
      'generator': 'allpages',
      'gapprefix': query[0].toUpperCase() + query.substring(1),
      'gapnamespace': '0',
      'gaplimit': '24',
      'gapfilterredir': 'nonredirects',
      'prop': 'pageprops|categories',
      'clcategories': language == 'ru'
          ? 'Категория:Списки редакций|Категория:Неоднозначности'
          : 'Category:Versions pages|Category:Disambiguation pages',
      'format': 'json',
      'formatversion': '2',
      'origin': '*',
    });
    try {
      final response = await _client.get(url, headers: const {
        'Accept': 'application/json',
      }).timeout(timeout);
      if (response.statusCode != 200)
        throw const FormatException('Unavailable');
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      final payload = decoded is Map ? decoded['query'] : null;
      final pages = payload is Map ? payload['pages'] : null;
      if (pages is! List) throw const FormatException('No prefix results');
      final books = <CatalogueBook>[];
      for (final page in pages) {
        if (page is! Map || page['title'] is! String || page['ns'] != 0)
          continue;
        if (page['pageprops'] is Map &&
            (page['pageprops'] as Map).containsKey('disambiguation')) continue;
        // Only the version/disambiguation categories were requested above.
        if (page['categories'] is List &&
            (page['categories'] as List).isNotEmpty) {
          continue;
        }
        final title = page['title'] as String;
        if (!_isWorkResult(title, '')) continue;
        books.add(CatalogueBook(
          title: title,
          language: language,
          sourceName: sourceName,
          pageUrl: wikiPage(language, title),
          epubUrl: wikiEpub(language, title),
        ));
      }
      return CatalogueSearchResult(
        books: books.take(16),
        failures: [
          if (books.isEmpty)
            originalFailure
          else
            CatalogueSourceFailure(
              sourceName,
              'Full-text search is busy. Showing titles that begin with your search.',
              CatalogueFailureKind.rateLimited,
            ),
        ],
      );
    } catch (_) {
      return CatalogueSearchResult(
          books: const [], failures: [originalFailure]);
    }
  }

  static bool _isWorkResult(String title, String snippet) {
    if (title.trim().isEmpty) return false;
    if (RegExp(
      r'^(?:Author|Index|Category|Portal|Help|Template|Page|Автор|Индекс|'
      r'Категория|Портал|Справка|Шаблон|Страница):',
      caseSensitive: false,
    ).hasMatch(title)) {
      return false;
    }
    final child = title.split(RegExp(r'[/：:]')).last.trim();
    if (RegExp(r'[/：:]').hasMatch(title) &&
        RegExp(
          r'^(?:chapter|глава|часть|том|volume|part|book|песня|песнь)(?:\s|_|\d)|^[IVXLCDM]+$|^\d{1,3}$',
          caseSensitive: false,
        ).hasMatch(child)) return false;
    final lower = snippet.toLowerCase();
    return !lower.contains('versions of ') &&
        !lower.contains('список редакций');
  }

  void close() => _client.close();
}
