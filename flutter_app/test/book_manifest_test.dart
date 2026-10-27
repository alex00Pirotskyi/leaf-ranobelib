import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:leaf_reader/core/book_manifest.dart';
import 'package:leaf_reader/core/open_reader.dart';

Uri wiki(String title, [String language = 'en', String site = 'wikisource']) =>
    Uri(scheme: 'https', host: '$language.$site.org',
        path: '/wiki/${title.replaceAll(' ', '_')}');

String link(String title, String text, {String extra = ''}) =>
    '<a href="${wiki(title).path}" $extra>$text</a>';

Map<String, Object> article(String title, String html,
        {List<Object> properties = const []}) =>
    {'parse': {'title': title, 'text': '<div class="mw-parser-output">$html</div>',
      'properties': properties}};

BookDiscovery discovery(Map<String, Map<String, Object>> pages,
    {List<Uri>? requests}) => BookDiscovery(client: MockClient((request) async {
  requests?.add(request.url);
  expect(request.url.queryParameters['origin'], '*');
  expect(request.url.queryParameters['formatversion'], '2');
  final body = pages[request.url.queryParameters['page']];
  return http.Response(jsonEncode(body ?? {'error': {'code': 'missingtitle'}}),
      200, headers: {'content-type': 'application/json; charset=utf-8'});
}));

const prose = 'The travellers followed the river through the sleeping forest. '
    'Before the next morning they would reach the city, where an unexpected '
    'letter and a very old friend waited for them. This introduction belongs '
    'to the book and must survive chapter discovery and EPUB conversion.';

void main() {
  test('Russian edition preserves Roman chapter order and appendix', () async {
    const title = 'Капитанская дочка (Пушкин)/1960 (СО)';
    final client = discovery({title: article(title, '''
      <div id="headertemplate"><span id="ws-title">Капитанская дочка</span>
      <span id="ws-author">автор ${link('Автор:Пушкин', 'Александр Пушкин')}</span>
      <span id="headernext">${link('$title/Глава II', 'Следующая глава')}</span></div>
      <div class="text"><ul>
      <li>${link('$title/Глава I', 'Глава I. Сержант гвардии')}</li>
      <li>${link('$title/Глава II', 'Глава II. Вожатый')}</li>
      <li>${link('$title/Приложение', 'Пропущенная глава')}</li></ul></div>
    ''')});
    final result = await client.discover(wiki(title, 'ru'));
    expect(result.title, 'Капитанская дочка');
    expect(result.author, 'Александр Пушкин');
    expect(result.language, 'ru');
    expect(result.sourceUrl, wiki(title, 'ru'));
    expect(result.chapters, [wiki('$title/Глава I', 'ru'),
      wiki('$title/Глава II', 'ru'), wiki('$title/Приложение', 'ru')]);
    client.close();
  });

  test('English named chapters use source contents order, not number sorting', () async {
    const title = 'An Adventure (1866)';
    final requests = <Uri>[];
    final client = discovery({title: article(title, '''
      <div class="ws-header"><span id="ws-title">An Adventure</span>
      <span id="ws-author">An Author</span></div>
      <table class="wst-toc-table ws-summary"><tr><td>
      ${link('$title/The Rabbit', 'Down the rabbit-hole')}</td></tr>
      <tr><td>${link('$title/The Pool', 'The pool of tears')}</td></tr></table>
    ''')}, requests: requests);
    final result = await client.discover(wiki(title));
    expect(result.chapters, [wiki('$title/The Rabbit'), wiki('$title/The Pool')]);
    expect(requests.length, 1, reason: 'Do not pre-download every chapter.');
    expect(result.author, 'An Author');
    client.close();
  });

  test('opaque child IDs and duplicates retain first source occurrence', () async {
    const title = 'Book';
    final client = discovery({title: article(title, '''
      <ul><li>${link('$title/7341', 'Chapter I')}</li>
      <li>${link('$title/22', 'Chapter II')}</li>
      <li>${link('$title/7341', 'Chapter I again')}</li></ul>
      <p>${link('Unrelated article', 'See also')}</p>
    ''')});
    final result = await client.discover(wiki(title));
    expect(result.chapters, [wiki('$title/7341'), wiki('$title/22')]);
    client.close();
  });

  test('explicit TOC supports nonhierarchical page identifiers', () async {
    final client = discovery({'Book': article('Book', '''
      <ol class="book-toc"><li>${link('Opaque id ZX7', 'First chapter')}</li>
      <li>${link('Opaque id AB3', 'Second chapter')}</li></ol>
      <p>${link('Bibliography', 'Bibliography')}</p>
    ''')});
    expect((await client.discover(wiki('Book'))).chapters,
        [wiki('Opaque id ZX7'), wiki('Opaque id AB3')]);
    client.close();
  });

  test('nested volumes flatten in published order with no duplicates', () async {
    final client = discovery({
      'Novel': article('Novel', '<ul><li>${link('Novel/Volume I', 'Volume I')}</li>'
          '<li>${link('Novel/Volume II', 'Volume II')}</li></ul>'),
      'Novel/Volume I': article('Novel/Volume I', '<ul>'
          '<li>${link('Novel/Volume I/Chapter I', 'Chapter I')}</li>'
          '<li>${link('Novel/Volume I/Chapter II', 'Chapter II')}</li></ul>'),
      'Novel/Volume II': article('Novel/Volume II', '<ul>'
          '<li>${link('Novel/Volume II/Chapter I', 'Chapter I')}</li></ul>'),
    });
    expect((await client.discover(wiki('Novel'))).chapters, [
      wiki('Novel/Volume I/Chapter I'), wiki('Novel/Volume I/Chapter II'),
      wiki('Novel/Volume II/Chapter I'),
    ]);
    client.close();
  });

  test('substantial front matter is included before linked chapters', () async {
    final html = '<p>$prose</p><table class="wst-toc-table"><tr><td>'
        '${link('Book/Chapter 1', 'Chapter 1')}</td></tr>'
        '<tr><td>${link('Book/Chapter 2', 'Chapter 2')}</td></tr></table>';
    final client = discovery({'Book': article('Book', html)});
    final result = await client.discover(wiki('Book'));
    expect(result.chapters,
        [wiki('Book'), wiki('Book/Chapter 1'), wiki('Book/Chapter 2')]);
    expect(result.note, contains('including text from the contents page'));
    final extracted = extractWikiText(html);
    expect(extracted, contains('travellers'));
    expect(extracted, isNot(contains('Chapter 1')));
    client.close();
  });

  test('full-text edition with slash remains one page, not guessed parent', () async {
    const title = 'Евгений Онегин (Пушкин)/СС 1959 (СО)';
    final requests = <Uri>[];
    final client = discovery({title: article(title, '<pre>$prose</pre>')},
        requests: requests);
    final result = await client.discover(wiki(title, 'ru'));
    expect(result.chapters, [wiki(title, 'ru')]);
    expect(result.note, contains('one page'));
    expect(requests.length, 1);
    client.close();
  });

  test('root contents extraction preserves ordinary prose lists', () {
    final html = '<p>$prose</p><ul><li>First ingredient</li>'
        '<li>Second ingredient</li></ul><ul>'
        '<li>${link('Book/Chapter 1', 'Chapter 1')}</li>'
        '<li>${link('Book/Chapter 2', 'Chapter 2')}</li></ul>';
    final text = extractWikiText(html, page: wiki('Book'));
    expect(text, contains('First ingredient'));
    expect(text, isNot(contains('Chapter 1')));
  });

  test('chapter resolves a header-linked parent only if parent lists it', () async {
    final client = discovery({
      'Book/Chapter 2': article('Book/Chapter 2',
          '<div class="ws-header"><span class="wst-header-title-text">'
          '${link('Book', 'Book')}</span></div><p>$prose</p>'),
      'Book': article('Book', '<ul><li>${link('Book/Chapter 1', 'First')}</li>'
          '<li>${link('Book/Chapter 2', 'Second')}</li></ul>'),
    });
    final result = await client.discover(wiki('Book/Chapter 2'));
    expect(result.sourceUrl, wiki('Book'));
    expect(result.chapters, [wiki('Book/Chapter 1'), wiki('Book/Chapter 2')]);
    expect(result.note, contains('chapter’s book link'));
    client.close();
  });

  test('unconfirmed standalone chapter reports its limited scope', () async {
    final client = discovery({
      'Book/Chapter 2': article('Book/Chapter 2', '<p>$prose</p>'),
    });
    final result = await client.discover(wiki('Book/Chapter 2'));
    expect(result.chapters, [wiki('Book/Chapter 2')]);
    expect(result.note, contains('Only this page'));
    client.close();
  });

  test('Wikibooks uses same ordered contents contract', () async {
    final client = discovery({'Programming': article('Programming',
        '<ul><li>${link('Programming/Introduction', 'Introduction')}</li>'
        '<li>${link('Programming/Functions', 'Functions')}</li></ul>')});
    final result = await client.discover(wiki('Programming', 'en', 'wikibooks'));
    expect(result.chapters, [wiki('Programming/Introduction', 'en', 'wikibooks'),
      wiki('Programming/Functions', 'en', 'wikibooks')]);
    client.close();
  });

  test('empty source fails instead of exporting a contents placeholder', () async {
    final client = discovery({'Empty': article('Empty', '<p> </p>')});
    await expectLater(client.discover(wiki('Empty')), throwsFormatException);
    client.close();
  });

  test('disambiguation and editions are not concatenated', () async {
    final client = discovery({'Title': article('Title',
        '<ul><li>${link('Title/1880', 'First edition')}</li>'
        '<li>${link('Title/1900', 'Second edition')}</li></ul>',
        properties: [{'name': 'disambiguation', 'value': ''}])});
    await expectLater(client.discover(wiki('Title')),
        throwsA(isA<FormatException>().having((e) => e.message, 'message',
            contains('edition'))));
    client.close();
  });

  test('a missing TOC section is explicit instead of silently skipped', () async {
    final client = discovery({'Book': article('Book', '<ul>'
        '<li>${link('Book/Chapter I', 'I')}</li>'
        '<li>${link('Book/Chapter II', 'II', extra: 'class="new"')}</li></ul>')});
    await expectLater(client.discover(wiki('Book')),
        throwsA(isA<FormatException>().having((e) => e.message, 'message',
            contains('unavailable section'))));
    client.close();
  });

  test('actual API property maps and underscore edition categories are rejected', () async {
    for (final metadata in [
      {'properties': {'disambiguation': ''}},
      {'categories': [{'category': 'Списки_редакций'}]},
    ]) {
      final body = article('Book', '<ul>'
          '<li>${link('Book/1880', 'First edition')}</li>'
          '<li>${link('Book/1900', 'Second edition')}</li></ul>');
      (body['parse'] as Map).addAll(metadata);
      final client = discovery({'Book': body});
      await expectLater(client.discover(wiki('Book')), throwsFormatException);
      client.close();
    }
  });

  test('over 500 source sections throws and never returns first 500', () async {
    final html = '<ol>${List.generate(501, (i) =>
        '<li>${link('Book/section-$i', 'Section $i')}</li>').join()}</ol>';
    final client = discovery({'Book': article('Book', html)});
    await expectLater(client.discover(wiki('Book')),
        throwsA(isA<FormatException>().having((e) => e.message, 'message',
            contains('500'))));
    client.close();
  });

  test('link-only index cannot pass as a full-text book', () async {
    final html = '<ul>${List.generate(8, (i) =>
        '<li>${link('Unrelated book $i', 'A long different work title number $i')}</li>')
        .join()}</ul>';
    final client = discovery({'Index': article('Index', html)});
    await expectLater(client.discover(wiki('Index')), throwsFormatException);
    client.close();
  });

  test('rate limit and invalid API responses remain errors', () async {
    for (final response in [http.Response('slow down', 429),
      http.Response('<html>Challenge</html>', 200)]) {
      final client = BookDiscovery(client: MockClient((_) async => response));
      await expectLater(client.discover(wiki('Book')), throwsFormatException);
      client.close();
    }
  });

  test('explicitly incomplete edition is not advertised as a whole book', () async {
    final body = article('Book', '<p>$prose</p>');
    (body['parse'] as Map)['categories'] = [
      {'category': 'Incomplete texts'},
    ];
    final client = discovery({'Book': body});
    await expectLater(client.discover(wiki('Book')),
        throwsA(isA<FormatException>().having((e) => e.message, 'message',
            contains('incomplete'))));
    client.close();
  });
}
