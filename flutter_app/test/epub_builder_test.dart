import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:leaf_reader/core/epub_builder.dart';
import 'package:leaf_reader/core/ranobe_client.dart';
import 'package:xml/xml.dart';

void main() {
  String entry(Archive archive, String path) =>
      utf8.decode(archive.files.firstWhere((file) => file.name == path).readBytes()!);

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

  test('all EPUB documents are strict XML with consistent unique metadata', () {
    final before = DateTime.now().toUtc().subtract(const Duration(seconds: 1));
    Archive makeBook(String language) => ZipDecoder().decodeBytes(EpubBuilder.build(
      title: 'A & B <book>\u0001', author: 'Автор & editor', language: language,
      chapters: const [BookChapter('Глава & 1',
        '<article><div><p>First <b>bold</b> paragraph.</p>'
        '<p>Second <i>italic</i> paragraph.<img src="https://example.org/x.png"></p>'
        '<ul><li>Item</li></ul></div></article>')],
    ));
    final english = makeBook('en');
    final russian = makeBook('ru');
    for (final archive in [english, russian]) {
      for (final file in archive.files.where((file) =>
          RegExp(r'\.(?:xml|xhtml|opf|ncx)$').hasMatch(file.name))) {
        expect(() => XmlDocument.parse(utf8.decode(file.readBytes()!)),
            returnsNormally, reason: 'Invalid XML in ${file.name}');
      }
    }
    final opf = XmlDocument.parse(entry(english, 'OEBPS/content.opf'));
    final identifier = opf.findAllElements('dc:identifier').single.innerText;
    expect(identifier, matches(RegExp(
      r'^urn:uuid:[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
    final otherIdentifier = XmlDocument.parse(entry(russian, 'OEBPS/content.opf'))
        .findAllElements('dc:identifier').single.innerText;
    expect(identifier, isNot(otherIdentifier));
    expect(opf.findAllElements('dc:title').single.innerText, 'A & B <book>');
    expect(opf.findAllElements('dc:language').single.innerText, 'en');
    expect(entry(russian, 'OEBPS/content.opf'), contains('<dc:language>ru</dc:language>'));
    final ncx = XmlDocument.parse(entry(english, 'OEBPS/toc.ncx'));
    expect(ncx.findAllElements('meta').single.getAttribute('content'), identifier);
    final modified = DateTime.parse(opf.findAllElements('meta')
        .singleWhere((node) => node.getAttribute('property') == 'dcterms:modified').innerText);
    expect(modified.isUtc, isTrue);
    expect(modified.isBefore(before), isFalse);
    expect(modified.isAfter(DateTime.now().toUtc()), isFalse);
    expect(entry(english, 'OEBPS/c1.xhtml'), contains('xml:lang="en"'));
    expect(entry(russian, 'OEBPS/nav.xhtml'), contains('Содержание'));
  });

  test('preserves block structure without nesting paragraph elements', () {
    final clean = sanitizeHtml('<article><div><p>A <b>strong</b> word.</p>'
      '<p>Image <img src="remote.jpg"> and text.</p>'
      '<ul><li>One</li><li>Two</li></ul></div></article>');
    final doc = XmlDocument.parse('<body>$clean</body>');
    expect(doc.findAllElements('p').length, 2);
    for (final paragraph in doc.findAllElements('p')) {
      expect(paragraph.descendants.whereType<XmlElement>().any((node) =>
          {'p', 'div', 'ul', 'ol', 'table'}.contains(node.name.local)), isFalse);
    }
    expect(doc.findAllElements('li').map((node) => node.innerText).toList(), ['One', 'Two']);
    expect(clean, contains('<strong>strong</strong>'));
    expect(clean, isNot(contains('remote.jpg')));
  });

  test('removes executable and form content including its children', () {
    final clean = sanitizeHtml('<div onclick="bad()"><p>Keep <sup>1</sup></p>'
      '<script>bad()</script><form>Login<input value="secret"></form>'
      '<iframe>remote</iframe><object>plugin</object><svg>vector</svg>'
      '<a href="javascript:bad()">Readable link label</a></div>');
    expect(clean, contains('<sup>1</sup>'));
    expect(clean, contains('Readable link label'));
    for (final forbidden in ['bad()', 'onclick', 'Login', 'secret', 'remote', 'plugin', 'vector']) {
      expect(clean, isNot(contains(forbidden)));
    }
    expect(() => XmlDocument.parse('<body>$clean</body>'), returnsNormally);
  });

  test('writes a supplied UTC modification time and rejects invalid language', () {
    final archive = ZipDecoder().decodeBytes(EpubBuilder.build(
      title: 'Book', author: 'Author', language: 'en-GB',
      modifiedAt: DateTime.parse('2026-10-28T12:30:45+07:00'),
      chapters: const [BookChapter('One', '<p>Text</p>')],
    ));
    expect(entry(archive, 'OEBPS/content.opf'), contains('2026-10-28T05:30:45Z'));
    expect(() => EpubBuilder.build(title: 'Book', author: '', language: 'en\"bad',
        chapters: const [BookChapter('One', '<p>Text</p>')]), throwsFormatException);
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
