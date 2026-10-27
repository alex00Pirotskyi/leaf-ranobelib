import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:leaf_reader/core/import_parser.dart';

void main() {
  test('orders selected files naturally without integer precision loss', () {
    final book = ImportParser.parseFiles(const [
      ImportFile('chapter10.txt', 'Ten'),
      ImportFile('chapter2.txt', 'Two'),
      ImportFile('chapter1.txt', 'One'),
    ]);
    expect(book.chapters.map((c) => c.title).toList(),
        ['chapter1', 'chapter2', 'chapter10']);
    expect(
        ImportParser.naturalCompare(
            'c99999999999999999999.txt', 'c100000000000000000000.txt'),
        lessThan(0));
    expect(book.expectedChapters, 3);
  });

  test('accepts UTF-8 BOM and escapes text while preserving paragraph breaks',
      () {
    final book = ImportParser.parseFile(
        'Глава 1.txt', '\uFEFFПривет <мир>!\r\nСтрока.\r\n\r\nАбзац.');
    expect(book.chapters.single.html, contains('&lt;мир&gt;'));
    expect(book.chapters.single.html, contains('<br/>'));
    expect(book.chapters.single.html, contains('<p>Абзац.</p>'));
  });

  test('preserves metadata and partial status from captured JSON', () {
    final book = ImportParser.parseFile(
        'capture.json',
        jsonEncode({
          'title': 'Роман',
          'author': 'Автор',
          'language': 'ru',
          'complete': false,
          'capturedChapters': 1,
          'expectedChapters': 3,
          'chapters': [
            {'title': 'Начало', 'html': '<p>Текст первой главы.</p>'}
          ],
        }));
    expect(book.title, 'Роман');
    expect(book.author, 'Автор');
    expect(book.language, 'ru');
    expect(book.complete, isFalse);
    expect(book.expectedChapters, 3);
  });

  test('preserves outer partial metadata when unwrapping data', () {
    final book = ImportParser.parseFile(
        'capture.json',
        jsonEncode({
          'title': 'Book',
          'complete': false,
          'data': {
            'chapters': [
              {'text': 'Saved chapter text.'}
            ]
          },
        }));
    expect(book.title, 'Book');
    expect(book.complete, isFalse);
  });

  test('an expected-count shortfall stays partial even if complete was true',
      () {
    final book = ImportParser.parseFile(
        'capture.json',
        jsonEncode({
          'complete': true,
          'expectedChapters': 2,
          'chapters': [
            {'text': 'One chapter.'}
          ],
        }));
    expect(book.complete, isFalse);
    expect(book.expectedChapters, 2);
  });

  test('does not skip malformed chapters or manufacture missing content', () {
    for (final chapters in [
      [
        {'text': 'Valid text.'},
        12
      ],
      [
        {'title': 'Missing body'}
      ],
      [
        {'html': '   '}
      ],
      [
        {
          'content': {
            'type': 'doc',
            'content': [17]
          }
        }
      ],
      [
        {
          'content': {
            'type': 'doc',
            'content': [
              {'type': 'image'}
            ]
          }
        }
      ],
    ]) {
      expect(
          () => ImportParser.parseFile(
              'bad.json', jsonEncode({'chapters': chapters})),
          throwsFormatException);
    }
  });

  test(
      'rejects empty files, empty arrays, invalid schemas and inconsistent counts',
      () {
    expect(() => ImportParser.parseFile('empty.txt', ' \n '),
        throwsFormatException);
    expect(
        () => ImportParser.parseFile(
            'empty.html', '<script>alert(1)</script><p> </p>'),
        throwsFormatException);
    for (final source in [
      '[]',
      '{',
      '{"chapters":"invalid"}',
      '{"complete":"false","text":"Text"}',
      '{"capturedChapters":2,"chapters":[{"text":"Text"}]}',
      '{"expectedChapters":0,"chapters":[{"text":"Text"}]}',
    ]) {
      expect(() => ImportParser.parseFile('bad.json', source),
          throwsFormatException);
    }
  });

  test('rejects an oversized file and over-limit chapters without truncation',
      () {
    expect(
        () => ImportParser.parseFile(
            'large.txt', 'a'.padRight(ImportParser.maxFileBytes + 1, 'a')),
        throwsFormatException);
    final tooMany = jsonEncode({
      'chapters': List.generate(501, (_) => {'text': 'Text'})
    });
    expect(() => ImportParser.parseFile('many.json', tooMany),
        throwsFormatException);
  });

  test('sanitizes active HTML and validates structured document content', () {
    final htmlBook = ImportParser.parseFile(
        'chapter.html', '<p>Reading text.</p><script>alert(1)</script>');
    expect(htmlBook.chapters.single.html, isNot(contains('alert')));
    final docBook = ImportParser.parseFile(
        'chapter.json',
        jsonEncode({
          'content': {
            'type': 'doc',
            'content': [
              {
                'type': 'paragraph',
                'content': [
                  {'type': 'text', 'text': 'Document text.'}
                ]
              },
            ]
          },
        }));
    expect(docBook.chapters.single.html, contains('Document text.'));
  });

  test('combines partial status and only consistent metadata and known counts',
      () {
    final first = ImportParser.parseFile(
        'first.json',
        jsonEncode({
          'title': 'Book',
          'complete': false,
          'expectedChapters': 2,
          'chapters': [
            {'text': 'First.'}
          ],
        }));
    final second = ImportParser.parseFile(
        'second.json',
        jsonEncode({
          'title': 'Book',
          'expectedChapters': 1,
          'chapters': [
            {'text': 'Second.'}
          ],
        }));
    final merged = ImportParser.combine([first, second]);
    expect(merged.title, 'Book');
    expect(merged.complete, isFalse);
    expect(merged.expectedChapters, 3);
    final unknown =
        ImportParser.parseFile('unknown.json', '[{"text":"Another."}]');
    expect(ImportParser.combine([first, unknown]).expectedChapters, isNull);
    expect(ImportParser.combine([first, unknown]).title, isNull);
  });
}
