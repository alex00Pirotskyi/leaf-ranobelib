import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:leaf_reader/core/epub_builder.dart';
import 'package:leaf_reader/core/ranobe_client.dart';

void main() {
  test('creates a valid EPUB ZIP with uncompressed mimetype first', () {
    final data = EpubBuilder.build(
      title: 'Тестовая книга',
      author: 'Автор',
      chapters: const [
        BookChapter('Глава 1', '<p>Привет &amp; пока</p>'),
        BookChapter('Глава 2', '<p>Вторая глава</p>'),
      ],
    );
    expect(data.length, greaterThan(300));
    // ZIP local header: compression method (offset 8) must be STORED for mimetype.
    expect(data[8], 0);
    expect(data[9], 0);
    final archive = ZipDecoder().decodeBytes(data);
    expect(archive.files.first.name, 'mimetype');
    expect(utf8.decode(archive.files.first.readBytes()!), 'application/epub+zip');
    expect(archive.files.any((f) => f.name == 'META-INF/container.xml'), isTrue);
    expect(archive.files.any((f) => f.name == 'OEBPS/content.opf'), isTrue);
    expect(archive.files.any((f) => f.name == 'OEBPS/nav.xhtml'), isTrue);
    expect(archive.files.where((f) => f.name.endsWith('.xhtml')).length, 3);
    final chapter = archive.files.firstWhere((f) => f.name == 'OEBPS/c1.xhtml');
    expect(utf8.decode(chapter.readBytes()!), contains('Привет &amp; пока'));
  });

  test('sanitizes active HTML and preserves reading markup', () {
    final clean = sanitizeHtml('<script>bad()</script><p>Hello <b>world</b>!</p>');
    expect(clean, isNot(contains('bad()')));
    expect(clean, contains('<strong>world</strong>'));
  });

  test('converts structured chapter nodes into markup', () {
    final html = documentNodesToHtml([
      {'type': 'paragraph', 'content': [
        {'type': 'text', 'text': 'Привет & all', 'marks': [{'type': 'bold'}]}
      ]},
    ]);
    expect(html, '<p><strong>Привет &amp; all</strong></p>');
  });

  test('accepts only RanobeLIB book URLs', () {
    expect(RanobeClient.slugFromUrl(
        'https://ranobelib.me/ru/book/123--hello'), '123--hello');
    expect(
      () => RanobeClient.slugFromUrl('https://example.com/ru/book/123--hello'),
      throwsFormatException,
    );
  });
}
