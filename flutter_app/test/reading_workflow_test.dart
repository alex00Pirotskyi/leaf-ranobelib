import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:leaf_reader/core/chapter_url_plan.dart';
import 'package:leaf_reader/core/open_reader.dart';

void main() {
  group('URL range inference', () {
    test('distinct hash-routed chapters never collapse into a single page', () {
      expect(
          () => ChapterUrlPlan.parse('https://example.org/book/#/chapter/1',
              'https://example.org/book/#/chapter/5'),
          throwsFormatException);
    });
    test('numbered Wikisource chapters with padding', () {
      final plan = ChapterUrlPlan.parse(
        'https://en.wikisource.org/wiki/Example/Chapter_001',
        'https://en.wikisource.org/wiki/Example/Chapter_003',
      );
      expect(plan.inferred, isTrue);
      expect(plan.urls.length, 3);
      expect(plan.urls[1].toString(), endsWith('/Chapter_002'));
      expect(plan.isWikimedia, isTrue);
    });

    test('preserves book ID, volume and translation query', () {
      final plan = ChapterUrlPlan.parse(
        'https://ranobelib.me/ru/example-202399/read/v1/c1?bid=1234',
        'https://ranobelib.me/ru/example-202399/read/v1/c3?bid=1234',
      );
      expect(plan.urls.map((u) => u.pathSegments.last).toList(),
          ['c1', 'c2', 'c3']);
      expect(plan.urls[1].queryParameters['bid'], '1234');
    });

    test('opaque chapter slugs fall back to following Next links', () {
      final plan = ChapterUrlPlan.parse(
        'https://example.org/read/chapter-alpha',
        'https://example.org/read/chapter-omega',
      );
      expect(plan.inferred, isFalse);
      expect(plan.urls, isEmpty);
    });

    test('rejects an origin change and an excessive range', () {
      expect(
          () => ChapterUrlPlan.parse(
                'https://example.org/read/1',
                'https://elsewhere.org/read/2',
              ),
          throwsFormatException);
      expect(
          () => ChapterUrlPlan.parse(
                'https://example.org/read/1',
                'https://example.org/read/1000',
              ),
          throwsFormatException);
    });

    test('one URL exports one chapter', () {
      final plan = ChapterUrlPlan.parse(
        'https://en.wikibooks.org/wiki/Example/Chapter_3',
        'https://en.wikibooks.org/wiki/Example/Chapter_3',
      );
      expect(plan.urls.length, 1);
    });

    test('encoded spaces do not become part of a chapter number', () {
      final plan = ChapterUrlPlan.parse(
        'https://en.wikisource.org/wiki/Book/Chapter%209',
        'https://en.wikisource.org/wiki/Book/Chapter%2011',
      );
      expect(plan.inferred, isTrue);
      expect(plan.urls.map((url) => url.pathSegments.last).toList(),
          ['Chapter 9', 'Chapter 10', 'Chapter 11']);
    });

    test('Cyrillic letters in percent escapes cannot become chapter numbers',
        () {
      final plan = ChapterUrlPlan.parse(
        'https://ru.wikisource.org/wiki/Книга/Глава_А',
        'https://ru.wikisource.org/wiki/Книга/Глава_В',
      );
      expect(plan.inferred, isFalse);
      expect(plan.urls, isEmpty);
    });

    test('real numeric Russian chapter suffixes remain supported', () {
      final plan = ChapterUrlPlan.parse(
        'https://ru.wikisource.org/wiki/Книга/Глава_9',
        'https://ru.wikisource.org/wiki/Книга/Глава_11',
      );
      expect(plan.inferred, isTrue);
      expect(plan.urls.length, 3);
      expect(plan.urls[1].pathSegments.last, 'Глава_10');
    });

    test('only explicit chapter query numbers are inferred', () {
      final chapter = ChapterUrlPlan.parse(
        'https://example.org/read?bid=20&chapter=9',
        'https://example.org/read?bid=20&chapter=11',
      );
      expect(chapter.inferred, isTrue);
      expect(chapter.urls[1].queryParameters, {'bid': '20', 'chapter': '10'});
      final book = ChapterUrlPlan.parse(
        'https://example.org/read?bid=1&chapter=9',
        'https://example.org/read?bid=3&chapter=9',
      );
      expect(book.inferred, isFalse);
      final translation = ChapterUrlPlan.parse(
        'https://example.org/read?chapter=9&branch_id=1',
        'https://example.org/read?chapter=9&branch_id=3',
      );
      expect(translation.inferred, isFalse);
    });

    test('a changing book ID or arbitrary slug is not a chapter range', () {
      for (final pair in [
        [
          'https://example.org/book/1/read/c1',
          'https://example.org/book/3/read/c1'
        ],
        [
          'https://example.org/book/1--a-novel',
          'https://example.org/book/3--a-novel'
        ],
      ]) {
        expect(ChapterUrlPlan.parse(pair[0], pair[1]).inferred, isFalse);
      }
    });

    test('fragments are removed from range endpoints and membership checks',
        () {
      final plan = ChapterUrlPlan.parse(
        'https://example.org/read/1#text',
        'https://example.org/read/3#footer',
      );
      expect(plan.inferred, isTrue);
      expect(plan.start.hasFragment, isFalse);
      expect(plan.end.hasFragment, isFalse);
      expect(plan.contains(Uri.parse('https://example.org/read/2#chapter')),
          isTrue);
      final same = ChapterUrlPlan.parse(
        'https://example.org/read/1#text',
        'https://example.org/read/1#other',
      );
      expect(same.urls.length, 1);
    });

    test('chapter zero does not gain padding and mixed padding is not guessed',
        () {
      final zero = ChapterUrlPlan.parse(
          'https://example.org/chapter-0', 'https://example.org/chapter-10');
      expect(zero.inferred, isTrue);
      expect(zero.urls.first.pathSegments.last, 'chapter-0');
      expect(zero.urls.length, 11);
      final mixed = ChapterUrlPlan.parse(
          'https://example.org/chapter-1', 'https://example.org/chapter-03');
      expect(mixed.inferred, isFalse);
    });
  });

  group('Public open-reading provider', () {
    test('generates a CORS-permitted Wikimedia API URL', () {
      final uri = OpenReader.apiUrl(Uri.parse(
          'https://en.wikisource.org/wiki/Pride_and_Prejudice_(1817)/Chapter_1'));
      expect(uri.queryParameters['origin'], '*');
      expect(uri.queryParameters['action'], 'parse');
      expect(
          uri.queryParameters['page'], 'Pride and Prejudice (1817)/Chapter 1');
    });

    test('extracts content but drops navigation and wiki chrome', () async {
      final reader = OpenReader(client: MockClient((request) async {
        expect(request.url.host, 'en.wikisource.org');
        return http.Response(
            jsonEncode({
              'parse': {
                'title': 'Example / Chapter 1',
                'text': '<div class="mw-parser-output">'
                    '<div class="ws-header"><p>NAVIGATION BANNER</p></div>'
                    '<p>The quick brown fox jumped over the lazy dog. '
                    'This paragraph contains enough words to form a small chapter.</p>'
                    '<p>This is another paragraph from the readable chapter.</p>'
                    '</div>'
              }
            }),
            200,
            headers: {'content-type': 'application/json'});
      }));
      final chapter = await reader
          .read(Uri.parse('https://en.wikisource.org/wiki/Example/Chapter_1'));
      expect(chapter.title, contains('Chapter 1'));
      expect(chapter.html, contains('quick brown fox'));
      expect(chapter.html, isNot(contains('NAVIGATION BANNER')));
      expect(chapter.html, contains('Source:'));
      reader.close();
    });

    test('handles Russian language and HTML text', () {
      final html = extractWikiText('<div class="mw-parser-output">'
          '<p>Привет мир. Большой русский текст главы.</p>'
          '<p>Начало произведения.</p><div class="mw-editsection">править</div>'
          '</div>');
      expect(html, contains('Привет мир'));
      expect(html, isNot(contains('править')));
    });
  });
}
