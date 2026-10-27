import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:leaf_reader/core/book_catalogue.dart';

http.Response searchResponse(List<Map<String, Object>> books) => http.Response(
      jsonEncode({
        'query': {'search': books},
      }),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

void main() {
  test(
    'featured books are specific editions with native EPUB fallback links',
    () {
      expect(BookCatalogue.featured.map((b) => b.language).toSet(), {
        'ru',
        'en',
      });
      final captain = BookCatalogue.featured.first;
      expect(captain.pageUrl.pathSegments.last, '1960_(СО)');
      expect(captain.epubUrl!.host, 'ws-export.wmcloud.org');
      expect(captain.epubUrl!.queryParameters['format'], 'epub-3');
      expect(captain.epubUrl!.queryParameters['page'], contains('/1960_(СО)'));
    },
  );

  test(
    'empty search offers immediate featured books without a network call',
    () async {
      final catalogue = BookCatalogue(
        client: MockClient(
          (_) async => throw StateError('A blank search must be local'),
        ),
      );
      final result = await catalogue.search('', language: 'ru');
      expect(result.books.length, 2);
      expect(result.books.every((b) => b.language == 'ru'), isTrue);
      expect(result.failures, isEmpty);
      catalogue.close();
    },
  );

  test(
    'search encodes Russian safely and uses the supported public CORS API',
    () async {
      final catalogue = BookCatalogue(
        client: MockClient((request) async {
          expect(request.url.host, 'ru.wikisource.org');
          expect(request.url.queryParameters['origin'], '*');
          expect(request.url.queryParameters['srnamespace'], '0');
          expect(request.url.queryParameters['srsearch'], startsWith('Метель'));
          expect(
            request.url.queryParameters['srsearch'],
            contains('Списки редакций'),
          );
          return searchResponse([
            {'ns': 0, 'title': 'Метель (Пушкин)', 'snippet': 'Повесть'},
          ]);
        }),
      );
      final result = await catalogue.search('Метель', language: 'ru');
      expect(result.books.single.title, 'Метель (Пушкин)');
      expect(result.books.single.pageUrl.pathSegments.last, 'Метель_(Пушкин)');
      catalogue.close();
    },
  );

  test(
    'retains a healthy catalogue when another returns an API-level error',
    () async {
      final catalogue = BookCatalogue(
        client: MockClient((request) async {
          if (request.url.host.startsWith('ru.')) {
            return http.Response(
              jsonEncode({
                'error': {
                  'code': 'cirrussearch-too-busy-error',
                  'info': 'busy',
                },
              }),
              200,
            );
          }
          return searchResponse([
            {'ns': 0, 'title': 'A New Book', 'snippet': 'Novel'},
          ]);
        }),
      );
      final result = await catalogue.search('New Book');
      expect(result.books.single.title, 'A New Book');
      expect(result.isPartial, isTrue);
      expect(result.failures.single.sourceName, 'Викитека');
      expect(result.failures.single.kind, CatalogueFailureKind.rateLimited);
      catalogue.close();
    },
  );

  test(
    'filters version indexes and chapter hits but keeps edition subpages',
    () async {
      final catalogue = BookCatalogue(
        client: MockClient(
          (_) async => searchResponse([
            {'ns': 0, 'title': 'Novel/Chapter 1', 'snippet': 'Chapter'},
            {'ns': 0, 'title': 'Роман/Глава II', 'snippet': 'Глава'},
            {
              'ns': 0,
              'title': 'Novel',
              'snippet': 'Versions of <b>Novel</b> include',
            },
            {'ns': 0, 'title': 'Роман', 'snippet': 'Список редакций: Роман'},
            {'ns': 0, 'title': 'Novel/1960 (СО)', 'snippet': 'Complete book'},
            {'ns': 0, 'title': 'Author:Someone', 'snippet': 'Author'},
            {'ns': 104, 'title': 'Page:Novel.djvu/1', 'snippet': 'Scan'},
            {
              'ns': 0,
              'title': 'Another Novel (1890)',
              'snippet': 'Complete book',
            },
          ]),
        ),
      );
      final result = await catalogue.search('Novel', language: 'en');
      expect(result.books.map((b) => b.title).toList(), [
        'Another Novel (1890)',
        'Novel/1960 (СО)',
      ]);
      catalogue.close();
    },
  );

  test('uses one bounded title-prefix fallback when full-text search is busy',
      () async {
    var calls = 0;
    final catalogue = BookCatalogue(client: MockClient((request) async {
      calls++;
      if (request.url.queryParameters['list'] == 'search') {
        return http.Response(
            jsonEncode({
              'error': {
                'code': 'cirrussearch-too-busy-error',
              }
            }),
            200);
      }
      expect(request.url.queryParameters['generator'], 'allpages');
      expect(request.url.queryParameters['gapprefix'], 'Роман');
      expect(request.url.queryParameters['gapfilterredir'], 'nonredirects');
      expect(request.url.queryParameters['gaplimit'], '24');
      expect(request.url.queryParameters['origin'], '*');
      return http.Response(
          jsonEncode({
            'query': {
              'pages': [
                {
                  'ns': 0,
                  'title': 'Роман (Автор)',
                  'categories': [
                    {'title': 'Категория:Списки редакций'},
                  ]
                },
                {'ns': 0, 'title': 'Роман (Автор)/1960 (СО)'},
                {'ns': 0, 'title': 'Роман (Автор)/1960 (СО)/Глава I'},
                {'ns': 0, 'title': 'Роман: Глава II'},
                {
                  'ns': 0,
                  'title': 'Роман неоднозначный',
                  'pageprops': {'disambiguation': ''}
                },
              ]
            }
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    }));
    final result = await catalogue.search('роман', language: 'ru');
    expect(calls, 2);
    expect(result.books.single.title, 'Роман (Автор)/1960 (СО)');
    expect(result.isPartial, isTrue);
    expect(result.failures.single.message, contains('begin with your search'));
    catalogue.close();
  });

  test('keeps curated matching books usable during an outage', () async {
    final catalogue = BookCatalogue(
      client: MockClient(
        (_) async => http.Response('temporarily unavailable', 503),
      ),
    );
    final result = await catalogue.search('Jane Austen', language: 'en');
    expect(result.books.single.title, 'Pride and Prejudice');
    expect(result.isPartial, isTrue);
    expect(result.failures.single.kind, CatalogueFailureKind.unavailable);
    catalogue.close();
  });

  test(
    'malformed responses produce an explicit failure, not zero search hits',
    () async {
      final catalogue = BookCatalogue(
        client: MockClient(
          (_) async => http.Response('<html>challenge</html>', 200),
        ),
      );
      final result = await catalogue.search('Unlisted work', language: 'en');
      expect(result.books, isEmpty);
      expect(result.failures.single.kind, CatalogueFailureKind.invalidResponse);
      catalogue.close();
    },
  );
}
