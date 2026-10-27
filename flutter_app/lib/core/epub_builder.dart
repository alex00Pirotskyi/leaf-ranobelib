import 'dart:convert';
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
  }) {
    if (chapters.isEmpty) {
      throw const FormatException('Add at least one chapter to create an EPUB.');
    }
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
      final heading = escapeXml(chapter.title);
      final body = sanitizeHtml(chapter.html);

      archive.addFile(ArchiveFile.string('OEBPS/' + filename, '''
<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="ru">
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

    final t = escapeXml(title.trim().isEmpty ? 'Untitled' : title.trim());
    final a = escapeXml(author.trim().isEmpty ? 'Unknown author' : author.trim());
    archive.addFile(ArchiveFile.string('OEBPS/nav.xhtml', '''
<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="ru">
<head><title>Contents</title><link rel="stylesheet" type="text/css" href="style.css"/></head>
<body><nav epub:type="toc" id="toc"><h1>Contents</h1><ol>$nav</ol></nav></body>
</html>'''));
    archive.addFile(ArchiveFile.string('OEBPS/toc.ncx', '''
<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
<head><meta name="dtb:uid" content="leaf-offline"/></head>
<docTitle><text>$t</text></docTitle><navMap>$ncx</navMap>
</ncx>'''));
    archive.addFile(ArchiveFile.string('OEBPS/content.opf', '''
<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" unique-identifier="bookid" version="3.0" xml:lang="ru">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="bookid">leaf-offline</dc:identifier>
    <dc:title>$t</dc:title>
    <dc:creator>$a</dc:creator>
    <dc:language>ru</dc:language>
    <meta property="dcterms:modified">2026-10-27T00:00:00Z</meta>
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
'''));

    return ZipEncoder().encodeBytes(archive, level: DeflateLevel.bestSpeed);
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

String _safeNode(dom.Node node) {
  if (node is dom.Text) return escapeXml(node.text);
  if (node is! dom.Element) return '';
  final tag = node.localName?.toLowerCase() ?? '';
  if (const {'script', 'style', 'iframe', 'object', 'svg', 'head', 'meta', 'link'}
      .contains(tag)) return '';
  if (tag == 'br' || tag == 'hr') return '<' + tag + '/>';
  if (tag == 'img') return '<p>[Illustration omitted]</p>';
  final safeTag = switch (tag) {
    'p' || 'div' || 'section' || 'article' => 'p',
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
    _ => '',
  };
  final nested = node.nodes.map(_safeNode).join();
  if (safeTag.isEmpty) return nested;
  return '<' + safeTag + '>' + (nested.isEmpty ? ' ' : nested) + '</' + safeTag + '>';
}
