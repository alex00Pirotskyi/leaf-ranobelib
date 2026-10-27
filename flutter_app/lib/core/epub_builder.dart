import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import 'ranobe_client.dart';

class BookChapter {
  const BookChapter(this.title, this.html);
  final String title;
  final String html;
}

/// A self-contained EPUB 3 generator. Runs entirely in Dart on Flutter Web.
class EpubBuilder {
  static Uint8List build({
    required String title,
    required String author,
    required List<BookChapter> chapters,
    String language = 'en',
    DateTime? modifiedAt,
  }) {
    if (chapters.isEmpty) {
      throw const FormatException('Add at least one chapter to create an EPUB.');
    }
    if (!RegExp(r'^[A-Za-z]{2,8}(?:-[A-Za-z0-9]{1,8})*$')
        .hasMatch(language)) {
      throw const FormatException('Use a valid book language, such as en or ru.');
    }
    final lang = escapeXml(language);
    final identifier = _uniqueIdentifier();
    final modified = (modifiedAt ?? DateTime.now()).toUtc()
        .toIso8601String().replaceFirst(RegExp(r'\.\d+Z$'), 'Z');
    final contentsLabel = language.toLowerCase().startsWith('ru')
        ? 'Содержание' : 'Contents';
    final archive = Archive();
    const mime = 'application/epub+zip';
    archive.addFile(ArchiveFile.noCompress('mimetype', mime.length, utf8.encode(mime)));
    archive.addFile(ArchiveFile.string('META-INF/container.xml', '''
<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>'''));

    final manifest = StringBuffer('''
<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
<item id="style" href="style.css" media-type="text/css"/>
''');
    final spine = StringBuffer();
    final nav = StringBuffer();
    final ncx = StringBuffer();

    for (var index = 0; index < chapters.length; index++) {
      final chapter = chapters[index];
      final id = 'c' + (index + 1).toString();
      final filename = id + '.xhtml';
      final heading = _xmlText(chapter.title);
      final body = sanitizeHtml(chapter.html);

      archive.addFile(ArchiveFile.string('OEBPS/' + filename, '''
<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="$lang" lang="$lang">
<head><meta charset="utf-8"/><title>$heading</title><link rel="stylesheet" type="text/css" href="style.css"/></head>
<body><h1>$heading</h1>$body</body>
</html>'''));
      manifest.write('<item id="' + id + '" href="' + filename +
          '" media-type="application/xhtml+xml"/>\n');
      spine.write('<itemref idref="' + id + '"/>\n');
      nav.write('<li><a href="' + filename + '">' + heading + '</a></li>\n');
      ncx.write('<navPoint id="nav' + (index + 1).toString() +
          '" playOrder="' + (index + 1).toString() + '"><navLabel><text>' +
          heading + '</text></navLabel><content src="' + filename + '"/></navPoint>\n');
    }

    final t = _xmlText(title.trim().isEmpty ? 'Untitled' : title.trim());
    final a = _xmlText(author.trim().isEmpty ? 'Unknown author' : author.trim());
    archive.addFile(ArchiveFile.string('OEBPS/nav.xhtml', '''
<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="$lang" lang="$lang">
<head><title>$contentsLabel</title><link rel="stylesheet" type="text/css" href="style.css"/></head>
<body><nav epub:type="toc" id="toc"><h1>$contentsLabel</h1><ol>$nav</ol></nav></body>
</html>'''));
    archive.addFile(ArchiveFile.string('OEBPS/toc.ncx', '''
<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
<head><meta name="dtb:uid" content="$identifier"/></head>
<docTitle><text>$t</text></docTitle><navMap>$ncx</navMap>
</ncx>'''));
    archive.addFile(ArchiveFile.string('OEBPS/content.opf', '''
<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" unique-identifier="bookid" version="3.0" xml:lang="$lang">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="bookid">$identifier</dc:identifier>
    <dc:title>$t</dc:title>
    <dc:creator>$a</dc:creator>
    <dc:language>$lang</dc:language>
    <meta property="dcterms:modified">$modified</meta>
  </metadata>
  <manifest>$manifest</manifest>
  <spine toc="ncx">$spine</spine>
</package>'''));
    archive.addFile(ArchiveFile.string('OEBPS/style.css', '''
html { line-height: 1.5; }
body { margin: 5%; font-family: Georgia, serif; }
h1 { font-size: 1.5em; margin-bottom: 1.2em; }
h2 { font-size: 1.2em; }
p { margin: 0 0 0.75em; text-indent: 0.75em; }
blockquote { margin-left: 1.5em; }
pre { white-space: pre-wrap; }
table { border-collapse: collapse; max-width: 100%; }
td, th { padding: 0.25em; }
'''));

    return ZipEncoder().encodeBytes(archive, level: DeflateLevel.bestSpeed);
  }

  static String _uniqueIdentifier() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
    return 'urn:uuid:${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  static String safeFilename(String name) {
    final value = name.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '')
        .replaceAll(RegExp(r'\s+'), ' ').trim();
    final shortened = value.length > 80 ? value.substring(0, 80).trim() : value;
    return (shortened.isEmpty ? 'book' : shortened) + '.epub';
  }
}

/// Sanitizes imported HTML to an XHTML-safe text subset.
/// Never carries over scripts, links, remote images or active HTML.
String sanitizeHtml(String source) {
  final fragment = html_parser.parseFragment(source);
  final output = StringBuffer();
  for (final node in fragment.nodes) {
    output.write(_safeNode(node));
  }
  final clean = output.toString().trim();
  return clean.isEmpty ? '<p> </p>' : clean;
}

String _xmlText(String text) => escapeXml(String.fromCharCodes(
  text.runes.where((code) => code == 0x09 || code == 0x0a || code == 0x0d ||
      (code >= 0x20 && code <= 0xd7ff) ||
      (code >= 0xe000 && code <= 0xfffd) ||
      (code >= 0x10000 && code <= 0x10ffff)),
));

String _safeNode(dom.Node node) {
  if (node is dom.Text) {
    // XML 1.0 excludes these control characters even when HTML accepts them.
    return _xmlText(node.text);
  }
  if (node is! dom.Element) return '';
  final tag = node.localName?.toLowerCase() ?? '';
  if (const {'script', 'style', 'iframe', 'object', 'embed', 'svg', 'head',
      'meta', 'link', 'noscript', 'template', 'form', 'input', 'button',
      'textarea', 'select', 'canvas', 'video', 'audio'}
      .contains(tag)) return '';
  if (tag == 'br' || tag == 'hr') return '<' + tag + '/>';
  if (tag == 'img') return '<span>[Illustration omitted]</span>';
  final safeTag = switch (tag) {
    'p' => 'p',
    'div' || 'section' || 'article' => 'div',
    'strong' || 'b' => 'strong',
    'em' || 'i' => 'em',
    'blockquote' => 'blockquote',
    'ul' => 'ul',
    'ol' => 'ol',
    'li' => 'li',
    'h1' => 'h2',
    'h2' => 'h2',
    'h3' => 'h3',
    'h4' => 'h4',
    'pre' => 'pre',
    'code' => 'code',
    'u' => 'u',
    's' || 'del' => 's',
    'sup' => 'sup',
    'sub' => 'sub',
    'table' => 'table',
    'caption' => 'caption',
    'thead' => 'thead',
    'tbody' => 'tbody',
    'tfoot' => 'tfoot',
    'tr' => 'tr',
    'td' => 'td',
    'th' => 'th',
    _ => '',
  };
  final nested = node.nodes.map(_safeNode).join();
  if (safeTag.isEmpty) return nested;
  return '<' + safeTag + '>' + (nested.isEmpty ? ' ' : nested) + '</' + safeTag + '>';
}
