import 'dart:convert';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as parser;
import 'package:http/http.dart' as http;

import 'epub_builder.dart';

/// Fast path for Wikimedia's supported public cross-origin Action API.
///
/// The site explicitly enables CORS when origin=* is supplied. No proxy,
/// bookmarklet, account, cookies or browser automation is needed.
class OpenReader {
  OpenReader({http.Client? client}) : _client = client ?? http.Client();
  final http.Client _client;

  static bool supports(Uri page) => RegExp(
    r'^[a-z-]+\.(wikisource|wikibooks)\.org$',
  ).hasMatch(page.host) &&
      page.scheme == 'https' &&
      page.pathSegments.isNotEmpty &&
      page.pathSegments.first == 'wiki';

  static Uri apiUrl(Uri page) {
    if (!supports(page)) {
      throw const FormatException('This website has no direct Leaf reader.');
    }
    final title = page.pathSegments.skip(1).join('/').replaceAll('_', ' ');
    if (title.trim().isEmpty) throw const FormatException('Missing article title.');
    return Uri.https(page.host, '/w/api.php', {
      'action': 'parse',
      'page': title,
      'prop': 'text',
      'format': 'json',
      'formatversion': '2',
      'origin': '*',
    });
  }

  Future<BookChapter> read(Uri page) async {
    if (!supports(page)) throw const FormatException('Unsupported page');
    late final http.Response response;
    try {
      response = await _client.get(apiUrl(page), headers: const {
        'Accept': 'application/json',
      }).timeout(const Duration(seconds: 25));
    } catch (error) {
      throw FormatException(
        'Could not access the open reading API (network/CORS): ' + error.toString(),
      );
    }
    if (response.statusCode == 429) {
      throw const FormatException('The reading API rate limited requests. Stop and retry later.');
    }
    if (response.statusCode != 200) {
      throw FormatException('Reading API returned HTTP ' + response.statusCode.toString());
    }
    late final Map<String, dynamic> body;
    try {
      body = Map<String, dynamic>.from(jsonDecode(utf8.decode(response.bodyBytes)) as Map);
    } catch (_) {
      throw const FormatException('The reading API returned invalid JSON.');
    }
    if (body.containsKey('error')) {
      throw FormatException('Reading API: ' + body['error'].toString());
    }
    final parsed = body['parse'];
    if (parsed is! Map || parsed['text'] is! String) {
      throw FormatException('This page has no readable article content: ' + page.toString());
    }
    final html = extractWikiText(parsed['text'] as String);
    if (_readableLength(html) < 80) {
      throw FormatException('Not enough readable text at ' + page.toString());
    }
    final title = (parsed['title'] ?? page.pathSegments.last).toString();
    return BookChapter(title, html + '<p>Source: ' + escapeXml(page.toString()) + '</p>');
  }

  void close() => _client.close();
}

int _readableLength(String html) =>
    parser.parseFragment(html).text.replaceAll(RegExp(r'\s+'), ' ').trim().length;

/// Remove wiki navigation, edit links, templates and page metadata, leaving
/// the article body. The EPUB's shared sanitizer runs once more on output.
String extractWikiText(String source) {
  final fragment = parser.parseFragment(source);
  final base = fragment.querySelector('.mw-parser-output');
  final root = base ?? fragment;
  const hidden = [
    'script', 'style', 'noscript', 'nav', 'footer',
    '.mw-editsection', '.ws-header', '.ws-footer', '.wst-header',
    '.mw-cite-backlink', '.reference', '.noprint', '.printfooter',
    '.sistersitebox', '.metadata', '.portal', '.navbox',
    '.catlinks', '.shortdescription', '#toc', '.toc',
    '.mw-empty-elt', '.ws-noexport', '[data-mw-comment-start]',
  ];
  for (final selector in hidden) {
    for (final element in root.querySelectorAll(selector).toList()) {
      element.remove();
    }
  }
  return root.nodes.map((node) {
    if (node is dom.Text) return escapeXml(node.text);
    if (node is dom.Element) return node.outerHtml;
    return '';
  }).join();
}
