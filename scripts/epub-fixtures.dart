// Build real EN/RU EPUBs with the production packager for EPUBCheck validation.
// Run from the repository root after flutter pub get:
// dart --packages=flutter_app/.dart_tool/package_config.json scripts/epub-fixtures.dart /tmp/leaf-epubs
import 'dart:io';

import '../flutter_app/lib/core/epub_builder.dart';

void main(List<String> args) {
  final destination = Directory(args.isEmpty ? 'smoke-artifacts/epubcheck' : args.single)
    ..createSync(recursive: true);
  for (final language in ['en', 'ru']) {
    final chapters = <BookChapter>[
      for (var number = 1; number <= 3; number++)
        BookChapter(language == 'ru' ? 'Глава $number' : 'Chapter $number',
          File.fromUri(Platform.script.resolve(
            '../flutter_app/web/fixtures/chapter-$number.html')).readAsStringSync()),
      const BookChapter('Formatting & XML',
        '<article><div><p>English &amp; русский. <em>Emphasis</em> '
        '<strong>strength</strong> and a footnote<sup>1</sup>.</p>'
        '<blockquote><p>A quotation.</p></blockquote>'
        '<ul><li>One</li><li>Two</li></ul>'
        '<table><tr><th>Heading</th></tr><tr><td>Value</td></tr></table>'
        '<p>Illustration: <img src="https://example.org/image.png"></p>'
        '<script>neverRun()</script></div></article>'),
    ];
    final file = File('${destination.path}/leaf-$language.epub');
    file.writeAsBytesSync(EpubBuilder.build(
      title: language == 'ru' ? 'Проверка Leaf' : 'Leaf validation',
      author: 'Leaf', language: language, chapters: chapters,
    ));
    stdout.writeln(file.path);
  }
}
